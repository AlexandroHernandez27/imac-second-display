# iMac por red

Prototipo nativo para usar una iMac como **pantalla adicional** de una MacBook.
El escritorio se extiende; las aplicaciones corren en la MacBook. La iMac debe
permanecer encendida y ejecutar el receptor.

**Estado experimental:** pantalla independiente, captura y reproducción cifrada
comprobadas con ambas apps ejecutándose en una M5. Compatibilidad y rendimiento
entre la MacBook y la iMac Late 2013 pendientes de pruebas en ambos equipos.
No necesita Apple ID, suscripciones, servicios externos ni abrir puertos del router.

## Descargar y probar

Descarga las apps en [Releases](https://github.com/AlexandroHernandez27/imac-second-display/releases).

1. En la **MacBook**, abre `iMac Sender.app`. Empieza con 1920 × 1080, 30 FPS y 12 Mbps.
2. Pulsa **Preparar conexión**. La app muestra una IP y una clave temporal.
3. En la **iMac**, abre `iMac Receiver.app`, introduce la IP y pega la clave completa.
4. Pulsa **Conectar** y acepta la solicitud en la MacBook.
5. Concede al emisor el permiso de grabación de pantalla si macOS lo pide. Puede
   requerir cerrar y reabrir la app; prepara entonces una nueva sesión.
6. En el receptor pulsa **Pantalla completa**. Mueve ventanas por el borde derecho
   de la MacBook. Cambia la posición en Ajustes del Sistema → Pantallas si lo necesitas.

Ambas Macs deben estar en la misma LAN. Se usa TCP 7777; Ethernet utiliza el mismo
protocolo. Autoriza las apps en los avisos de red local/firewall de tu red de confianza.

Las apps tienen firma local *ad hoc*, **sin notarización de Apple**. Si macOS bloquea
la descarga, verifica el origen y usa la excepción puntual en Ajustes del Sistema →
Privacidad y seguridad. No desactives Gatekeeper globalmente. La iMac no necesita Xcode.

## Requisitos y alcance

| Componente | Binario actual |
| --- | --- |
| Emisor | Apple Silicon, macOS 13 o posterior; probado inicialmente en M5 |
| Receptor | Intel o Apple Silicon, macOS 13 o posterior |
| Red | IPv4 privada, conexión manual, un receptor |
| Resolución | 1280 × 720, 1920 × 1080 o 2560 × 1440 |
| Límite de FPS | 15, 30 o 60; rendimiento real por medir entre equipos |
| Video | H.264; bitrate 6, 12 o 20 Mbps; sin audio |

La iMac de destino reporta Sequoia 15.8.1. No hace falta cambiar su sistema para
estas primeras pruebas. Compilar para Intel no equivale a probar en esa iMac.

Limitaciones:

- Crear la pantalla depende de **`CGVirtualDisplay`, una API privada de Apple**.
  No se garantiza compatibilidad futura ni distribución por App Store.
- TCP con un fotograma pendiente de confirmación evita acumular video atrasado,
  pero la latencia de red puede limitar los FPS.
- El contenido protegido o apps que impidan captura pueden aparecer negros.
  No se promete compatibilidad con todos los sistemas DRM.
- Teclado y mouse en la MacBook; sin control remoto desde la iMac.
- Reconexión manual con clave nueva. Reposo o pérdida de conexión cierran la sesión.
- Sin audio, acceso por Internet, Bonjour ni varios receptores.

## Desarrollar

En una Mac con Apple Silicon y Command Line Tools:

```bash
bash scripts/build.sh
```

Produce las dos apps en `dist/`. El receptor es universal Intel/ARM. No descarga
dependencias: usa AppKit, ScreenCaptureKit, VideoToolbox, AVFoundation, Network y Security.

Pruebas desde una sesión gráfica de la MacBook:

```bash
bash scripts/test-display.sh --run
bash scripts/test-protocol.sh --run
```

La primera crea una pantalla temporal, coloca una ventana y verifica la retirada
al salir. La segunda prueba H.264, TLS-PSK, integridad, límites y rechazo de claves
incorrectas con video sintético en loopback. No sustituyen la prueba entre equipos.

**[Continuar en la iMac](CONTINUAR_EN_IMAC.md)** · [Pruebas](docs/PRUEBAS.md) ·
[Arquitectura](docs/ARQUITECTURA.md) · [Avisos de terceros](THIRD_PARTY_NOTICES.md)
