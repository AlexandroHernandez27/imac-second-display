# iMac por red

Prototipo nativo para usar una iMac como **pantalla adicional** de una MacBook.
El escritorio se extiende; las aplicaciones corren en la MacBook. La iMac debe
permanecer encendida y ejecutar el receptor.

**v0.3.0 experimental:** incorpora actualizaciones con confirmación y conserva las
mejoras de video de v0.2.0. Pantalla independiente, captura y reproducción cifrada
comprobadas con ambas apps ejecutándose en una M5. El usuario reporta imagen en la
iMac y retraso al mover ventanas/escribir con v0.1.0. Esta versión corrige el flujo
y permite medirlo mejor; la mejora en la iMac todavía requiere prueba.
La transmisión no necesita Apple ID, suscripciones, servicios externos ni abrir
puertos del router. La búsqueda opcional de actualizaciones consulta GitHub.

## Descargar y probar

Descarga las apps en [Releases](https://github.com/AlexandroHernandez27/imac-second-display/releases).
Actualiza **ambas aplicaciones**, cerrando primero las copias anteriores.

1. En la **MacBook**, abre `iMac Sender.app`. Empieza con 1920 × 1080, 30 FPS y 12 Mbps.
2. Pulsa **Preparar conexión**. La app muestra una IP y una clave temporal.
3. En la **iMac**, abre `iMac Receiver.app`, introduce la IP y pega la clave completa.
4. Pulsa **Conectar** y acepta la solicitud en la MacBook.
5. Concede al emisor el permiso de grabación de pantalla si macOS lo pide. Puede
   requerir cerrar y reabrir la app; prepara entonces una nueva sesión.
6. Pulsa **Prueba de movimiento** en el emisor para medir con una imagen cambiante.
   Espera cinco segundos y observa captura/entrega; un escritorio quieto puede dar 0 FPS.
7. En el receptor pulsa **Pantalla completa**. Mueve ventanas por el borde derecho
   de la MacBook. Cambia la posición en Ajustes del Sistema → Pantallas si lo necesitas.

Ambas Macs deben estar en la misma LAN. Se usa TCP 7777; Ethernet utiliza el mismo
protocolo. Autoriza las apps en los avisos de red local/firewall de tu red de confianza.

Las apps tienen firma local *ad hoc*, **sin notarización de Apple**. Si macOS bloquea
la descarga, verifica el origen y usa la excepción puntual en Ajustes del Sistema →
Privacidad y seguridad. No desactives Gatekeeper globalmente. La iMac no necesita Xcode.

## Actualizaciones desde la app

Instala v0.3.0 manualmente en ambas Macs una vez. Las versiones anteriores no
incluyen actualizador. Después:

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
- TCP con hasta tres fotogramas pendientes y una sola imagen cruda reciente.
  Las pérdidas de red todavía pueden añadir esperas por retransmisión.
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

Produce las dos apps en `dist/`. El receptor es universal Intel/ARM. La primera
compilación descarga Sparkle 2.10.1 y verifica su SHA-256; las siguientes reutilizan
la copia local. El resto usa frameworks del sistema. Versión, build y clave pública
de actualización están centralizados en `Config/release.json`.

Pruebas desde una sesión gráfica de la MacBook:

```bash
bash scripts/test-display.sh --run
bash scripts/test-protocol.sh --run
bash scripts/test-video-performance.sh --run
```

La primera comprueba la pantalla independiente. La segunda prueba H.264, TLS-PSK,
colas, métricas y rechazo de claves incorrectas. La tercera compara ventanas de
uno/tres fotogramas con codificación y decodificación reales y ACK artificial.
No sustituyen la prueba entre equipos ni miden el panel.

## Cambios de v0.2.0

- Conserva y envía el último cambio aunque la captura quede inactiva mientras espera un ACK.
- Admite tres fotogramas pendientes sin romper las dependencias de H.264.
- Muestra FPS de captura y entrega de los últimos dos segundos, preparación y ACK.
- Declara la transmisión como actividad de usuario para evitar App Nap durante la sesión;
  el receptor solicita mantener encendida su pantalla mientras está conectado y recibiendo.
- Añade un patrón animado y pruebas reproducibles de rendimiento.

La revisión de [LanScreen](docs/COMPARACION_LANSCREEN.md) documenta otras ideas y
qué diferencias necesitan medición antes de adoptarlas.

**[Continuar en la iMac](CONTINUAR_EN_IMAC.md)** · [Pruebas](docs/PRUEBAS.md) ·
[Arquitectura](docs/ARQUITECTURA.md) · [Avisos de terceros](THIRD_PARTY_NOTICES.md)
