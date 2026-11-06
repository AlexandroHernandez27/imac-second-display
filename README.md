# iMac por red

Prototipo nativo para usar una iMac como **pantalla adicional** de una MacBook.
El escritorio se extiende; las aplicaciones corren en la MacBook. La iMac debe
permanecer encendida y ejecutar el receptor.

**v0.4.0 experimental: conexión por cable USB‑A → USB‑C.** Un cable entre un puerto
USB‑A de la iMac y un puerto USB‑C de la MacBook crea una red privada entre ambas,
sin adaptadores ni configuración: la MacBook aparece en la iMac como un adaptador de
red USB. Medido: USB 2.0 a 480 Mbps, ≈340 Mbps útiles y 0.6–0.9 ms de latencia de red,
de sobra para 2560 × 1440 a 60 FPS. Las apps detectan el cable, lo prefieren, se
encuentran solas por Bonjour y aplican 1440p / 60 FPS / 40 Mbps. Ver
[Conexión por cable USB](docs/CABLE_USB.md).

También en v0.4.0: la iMac decodifica con VideoToolbox y confirma cada imagen al
mostrarla, así la latencia queda acotada; la MacBook muestra los FPS y el tipo de
decodificación de la iMac; H.264 High; la pantalla quieta se refina hasta quedar
nítida; y el receptor entra solo en pantalla completa.

El enlace físico se verificó con ambas Macs. La transmisión de escritorio por el
cable hasta la iMac **todavía debe probarse**: no se afirma fluidez en la iMac hasta
medirla. Wi‑Fi sigue disponible. No necesita Apple ID, suscripciones, servicios
externos ni abrir puertos del router. La búsqueda opcional de actualizaciones consulta GitHub.

## Descargar y probar

Descarga las apps en [Releases](https://github.com/AlexandroHernandez27/imac-second-display/releases).
Actualiza **ambas aplicaciones**, cerrando primero las copias anteriores: el receptor
v0.4.0 necesita el emisor v0.4.0.

1. Conecta un cable USB‑A (parte trasera de la iMac) → USB‑C (MacBook). Debe ser de datos.
2. En la **MacBook**, abre `iMac Sender.app`. El selector muestra «Cable USB» y aplica
   2560 × 1440, 60 FPS y 40 Mbps. Sin cable puedes elegir Wi‑Fi.
3. Pulsa **Preparar conexión** y copia la clave temporal.
4. En la **iMac**, abre `iMac Receiver.app`: aparece «MacBook · Cable USB». Pega la clave
   completa y pulsa **Conectar**. Si no aparece, usa la IP que muestra el emisor.
5. Acepta la solicitud en la MacBook. Concede el permiso de grabación de pantalla y,
   si macOS lo pide en cualquiera de las dos Macs, el de red local.
6. La iMac entra en pantalla completa. Pulsa **Prueba de movimiento** en el emisor y
   lee las métricas: incluyen los FPS que muestra la iMac y si decodifica por hardware.
7. Mueve ventanas por el borde derecho de la MacBook. Cambia la posición en Ajustes del
   Sistema → Pantallas si lo necesitas.

Se usa TCP 7777 solo en el enlace elegido. Autoriza las apps en los avisos de red local.

Las apps tienen firma local *ad hoc*, **sin notarización de Apple**. Si macOS bloquea
la descarga, verifica el origen y usa la excepción puntual en Ajustes del Sistema →
Privacidad y seguridad. No desactives Gatekeeper globalmente. La iMac no necesita Xcode.

## Actualizaciones desde la app

Si tienes v0.1.0 o v0.2.0, instala la versión actual manualmente en ambas Macs una
vez. Desde v0.3.0 se incluye actualizador:

- **Buscar versiones automáticamente:** consulta aproximadamente una vez al día
  mientras la app esté abierta. La casilla permite desactivarlo en cada equipo.
- **Buscar actualizaciones…:** botón y opción de menú para consultar en cualquier momento.
- Una versión nueva muestra sus cambios y solicita confirmación para descargar e
  instalar. Puedes posponer u omitir esa versión. La instalación reinicia la app.
- Desconecta primero la pantalla. La app evita iniciar actualizaciones durante una
  sesión y conexiones nuevas durante una actualización en curso.

Usa una carpeta local escribible, por ejemplo `~/Applications`. Si instalaste en
una ubicación protegida, macOS puede solicitar autorización para reemplazar la app.
La firma local puede requerir renovar el permiso de captura; las actualizaciones
no otorgan permisos de macOS ni notarizan las apps. Cada Mac se actualiza por separado.
Ver [funcionamiento y publicación de actualizaciones](docs/ACTUALIZACIONES.md).

## Diagnóstico de conexión

Si Sender dice «Protocolo incompatible» o Receiver indica que la MacBook cerró al
recibir el saludo, alguna app sigue en una versión anterior. Cierra ambas con ⌘Q y
abre las actuales desde Finder; el título debe mostrar **v0.4.0 (5)** en las dos.
Descargar el ZIP no sustituye un proceso abierto.

Desde v0.3.1, **Exportar diagnóstico…** guarda el registro local de la app.
Reproduce el fallo y exporta en **ambos equipos**. No incluye claves, IP ni imágenes,
ni envía datos automáticamente. [Guía de diagnóstico](docs/DIAGNOSTICO.md).

## Requisitos y alcance

| Componente | Binario actual |
| --- | --- |
| Emisor | Apple Silicon, macOS 13 o posterior; probado en M5 con macOS 27.2 |
| Receptor | Intel o Apple Silicon, macOS 13 o posterior |
| Conexión | Cable USB‑A → USB‑C (recomendado), Thunderbolt, Ethernet o Wi‑Fi; un receptor |
| Descubrimiento | Bonjour en el enlace elegido; IP manual como respaldo |
| Resolución | 2560 × 1440 (nativa de la iMac 27"), 1920 × 1080 o 1280 × 720 |
| Límite de FPS | 60, 30 o 15; rendimiento real en la iMac por medir |
| Video | H.264 High; 6, 12, 20, 40 u 80 Mbps; sin audio |

La iMac de destino reporta Sequoia 15.8.1. No hace falta cambiar su sistema.
Compilar para Intel no equivale a probar en esa iMac.

Limitaciones:

- Crear la pantalla depende de **`CGVirtualDisplay`, una API privada de Apple**.
  No se garantiza compatibilidad futura ni distribución por App Store.
- La red por cable USB depende de un comportamiento de macOS **no documentado** para
  terceros (modo dispositivo CDC‑NCM de Apple Silicon). Verificado en M5 / macOS 27.2
  con la iMac en Sequoia 15.8.1; puede cambiar en otras versiones.
- El cable conecta las dos Macs como una LAN: los servicios activados en cada Mac para
  todas las interfaces quedan alcanzables desde la otra.
- La iMac no carga la MacBook de forma útil por ese cable (5 V / 500 mA).
- TCP con hasta tres fotogramas pendientes. En Wi‑Fi las pérdidas aún pueden añadir
  esperas por retransmisión; el cable evita la radio.
- El contenido protegido o apps que impidan captura pueden aparecer negros.
- Teclado y mouse en la MacBook; sin control remoto desde la iMac.
- Reconexión manual con clave nueva. Reposo, cable desconectado o pérdida de red
  cierran la sesión.
- Sin audio, acceso por Internet ni varios receptores.

## Desarrollar

En una Mac con Apple Silicon y Command Line Tools:

```bash
bash scripts/build.sh
```

Produce las dos apps en `dist/`. El receptor es universal Intel/ARM. La primera
compilación descarga Sparkle 2.10.1 y verifica su SHA-256; las siguientes reutilizan
la copia local. El resto usa frameworks del sistema. Versión, build y clave pública
de actualización están centralizados en `Config/release.json`.

Pruebas desde una sesión gráfica de la MacBook:

```bash
bash scripts/test-display.sh --run
bash scripts/test-protocol.sh --run
bash scripts/test-video-performance.sh --run
bash scripts/test-diagnostics.sh --run
bash scripts/test-link.sh --run --require-usb   # con el cable conectado a la iMac
```

La primera comprueba la pantalla independiente. La segunda prueba H.264, TLS-PSK,
colas, métricas y rechazo de claves incorrectas. La tercera compara ventanas de
uno/tres fotogramas, mide el decoder de producción a 1440p/60 y la nitidez del texto
quieto con y sin refinamiento. La cuarta usa la interfaz real del cable: Bonjour
limitado a esa interfaz, TLS por Bonjour/IPv4/IPv6, saludo v3, ACK y reporte.
No sustituyen la prueba entre equipos ni miden el panel.

## Cambios de v0.4.0

- Conexión por cable USB‑A → USB‑C sin adaptador, detectada automáticamente.
- Bonjour limitado al enlace elegido; IPv6 link‑local disponible al conectar el cable.
- Decodificación explícita con VideoToolbox, ACK al mostrar y reporte de la iMac.
- H.264 High, sin IDR periódico y refinamiento de la pantalla quieta.
- Valores recomendados por enlace, aviso al desconectar el cable y pantalla completa automática.

## Cambios de v0.2.0

- Conserva y envía el último cambio aunque la captura quede inactiva mientras espera un ACK.
- Admite tres fotogramas pendientes sin romper las dependencias de H.264.
- Muestra FPS de captura y entrega de los últimos dos segundos, preparación y ACK.
- Declara la transmisión como actividad de usuario para evitar App Nap durante la sesión;
  el receptor solicita mantener encendida su pantalla mientras está conectado y recibiendo.
- Añade un patrón animado y pruebas reproducibles de rendimiento.

La revisión de [LanScreen](docs/COMPARACION_LANSCREEN.md) documenta otras ideas y
qué diferencias necesitan medición antes de adoptarlas.

**[Continuar en la iMac](CONTINUAR_EN_IMAC.md)** · [Cable USB](docs/CABLE_USB.md) ·
[Pruebas](docs/PRUEBAS.md) · [Arquitectura](docs/ARQUITECTURA.md) · [Avisos de terceros](THIRD_PARTY_NOTICES.md)
