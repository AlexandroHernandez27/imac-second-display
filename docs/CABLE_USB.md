# Conexión por cable USB‑A → USB‑C

Un cable USB‑A (puerto de la iMac) → USB‑C (puerto de la MacBook) crea una red
privada entre las dos Macs, sin adaptadores, drivers, parches ni configuración.
Desde v0.4.0 las apps detectan ese enlace, lo prefieren a Wi‑Fi y lo usan con el
mismo protocolo cifrado (TLS‑PSK, clave temporal y aceptación en la MacBook).

## Cómo funciona

- Un puerto USB‑A siempre es host. El extremo USB‑C del cable indica a la MacBook
  que el otro lado es un host, así que su puerto USB‑C actúa como **dispositivo**.
- En la M5, cada puerto USB‑C tiene un controlador en modo dispositivo
  (`AppleT8142USBXDCI`) que macOS deja configurado con dos funciones de red
  **CDC‑NCM**: una pública (`AppleUSBDeviceNCM*` → interfaz `en4`, `en5` o `en6`
  según el puerto) y otra privada del sistema (`anpi*`, que usa `remoted` de Apple).
  El dispositivo USB se presenta como fabricante Apple, producto «Mac».
- La iMac reconoce ese dispositivo con su driver host estándar `AppleUSBNCM`
  (clase USB 2, subclase 13) y crea su propia interfaz Ethernet.
- `configd` intenta DHCP en ambos extremos; sin servidor, asigna IPv4 169.254.x.x.
  La IPv6 link‑local aparece de inmediato.

No hay API privada en este camino: solo lectura de IOKit, sockets/Network.framework
y `dns_sd`. Sin embargo, Apple **no documenta** este modo para apps de terceros.
Puede cambiar en otras versiones de macOS. La pantalla virtual sigue dependiendo de
`CGVirtualDisplay` (privada), como antes.

## Medido el 2026-11-06, sin la app de video

Equipos: MacBook Pro M5 con macOS 27.2 como dispositivo; iMac 27" Late 2013 con
Sequoia 15.8.1 (reportado por el usuario) como host. Observado desde la MacBook.

| Dato | Resultado |
| --- | --- |
| Enumeración | La iMac configuró la MacBook (configuración 1) con `AppleUSBNCM` 24.6.0 |
| Velocidad USB | High Speed, 480 Mbps (USB 2.0). El controlador de la M5 admite hasta 10 Gbps: el cable probado parece USB 2.0 |
| Capacidad MacBook → iMac | ≈340 Mbps durante 3 s (UDP, contador de bytes de salida de la interfaz) |
| Latencia de red | 0.6–0.9 ms ida y vuelta (ICMPv6) |
| Direcciones | IPv6 link‑local inmediata; IPv4 169.254.x.x a los ~20 s, en ambos extremos |
| Bonjour | Funciona sobre el enlace |
| Alimentación | La iMac entrega 5 V / 500 mA: no carga la MacBook de forma útil |

Necesidad de la app: 2560 × 1440 a 60 FPS con H.264 a 40 Mbps usa ~12 % de la
capacidad medida. Un fotograma clave de 1440p (~400 KB) tarda ~10 ms en cruzar el
enlace. El cable USB 2.0 no es el cuello de botella. Un cable USB 3 podría
conectar a 5 Gbps en la iMac; no se probó y no es necesario.

La transmisión real de escritorio por el cable hasta la iMac **sigue pendiente de
prueba**. Las pruebas automáticas usan la interfaz real del cable, pero con ambos
extremos dentro de la MacBook.

## Uso

1. Conecta el cable: USB‑A en la parte trasera de la iMac y USB‑C en cualquier
   puerto de la MacBook. Debe ser un cable de datos, no solo de carga.
2. Abre **iMac Sender v0.4.1** o posterior. El selector muestra «Cable USB · …» y
   aplica 2560 × 1440, 60 FPS y 40 Mbps. Puedes cambiarlos.
3. Abre **iMac Receiver v0.4.1** en la iMac y déjalo abierto.
4. Pulsa **Preparar conexión** en la MacBook. **Por cable no hay clave**: la iMac
   encuentra la MacBook y se conecta sola.
5. Acepta «¿Transmitir a esta iMac?» en la MacBook. La iMac entra en pantalla completa.

La primera vez, macOS puede pedir permiso de **red local** en cada Mac y, en la
MacBook, de **grabación de pantalla** para iMac Sender. Con la firma local, ese último
permiso se pierde en cada versión nueva: hay que volver a activarlo (y reabrir la app).
Si la iMac no se conecta sola, elige «Escribir la IP manualmente», escribe la IPv4
169.254.x.x que muestra el emisor y deja la clave vacía.

## Sin clave por cable: decisión y protecciones

A petición del usuario (2026-11-06), por cable USB no se comparte clave. Ambas apps
usan una clave TLS-PSK fija y pública solo en ese modo, que por tanto **no aporta
secreto**. La protección es otra:

- El cable es un enlace punto a punto entre las dos Macs; no hay terceros en el medio.
- El emisor escucha solo en las direcciones del cable y se anuncia solo en esa interfaz.
- Rechaza conexiones que vienen de la propia MacBook (procesos locales).
- Nada se transmite hasta que aceptas en la MacBook; el diálogo indica «por cable USB».
- El receptor solo usa la clave fija si el emisor la anuncia (`auth=usb`) y el anuncio
  no llegó por Wi‑Fi. En Wi‑Fi y Ethernet sigue la clave temporal de 256 bits.

Riesgo residual: un programa en la iMac, o un equipo conectado al puerto USB‑C de la
MacBook mientras espera, podría pedir la pantalla. Sin tu aceptación no recibe nada.

## Lo que hace la app

- `LinkInventory` identifica el cable por IOKit: `AppleUSBDeviceNCM*` en la MacBook,
  `AppleUSBNCM*` sobre un dispositivo Apple «Mac» en la iMac. También informa la
  velocidad USB. Excluye las interfaces privadas `anpi*`.
- El emisor escucha solo en las direcciones del enlace elegido: IPv6 link‑local
  (disponible al instante) e IPv4 cuando existe. No abre el puerto en Wi‑Fi.
- Se anuncia por Bonjour **solo en la interfaz del cable** y solo mientras espera.
  El registro TXT contiene versión de protocolo y tipo de enlace, nada más.
- El receptor encuentra el servicio, lo resuelve a una dirección concreta y conecta
  por esa interfaz. Así una clave distinta falla al instante con un mensaje claro.
- Por cable, la iMac se conecta sola una vez por cada «Preparar conexión».
- Si se desconecta el cable, el emisor cierra la sesión en unos 2 segundos con un
  mensaje claro. Volver a conectar requiere una clave nueva, como siempre.

## Seguridad

El cable forma una red entre las dos Macs. Cualquier servicio que cada Mac tenga
activado para todas las interfaces, como Compartir pantalla, Compartir archivos o
SSH, también queda alcanzable desde la otra Mac por el cable, igual que en una LAN.
Por cable la transmisión no usa clave secreta (ver arriba); conserva la aceptación.

## Comprobar el enlace sin la app

En la MacBook, con el cable conectado:

```bash
ifconfig en4; ifconfig en5; ifconfig en6   # una debe decir «status: active»
bash scripts/test-link.sh --run --require-usb
```

La prueba detecta el cable y su velocidad. Después verifica Bonjour limitado a esa
interfaz y TLS‑PSK por Bonjour, IPv6 e IPv4 con decodificación de producción.
Ambos extremos están en la MacBook, así que no mide la iMac.

## Pendiente

- Escritorio real por el cable: FPS mostrados, decodificación por hardware o
  software en la iMac, latencia percibida y CPU de ambos equipos.
- Sesiones largas, reposo, reconexión del cable y otro puerto de la MacBook.
- Cable USB 3 (5 Gbps) y su efecto, si se dispone de uno.
