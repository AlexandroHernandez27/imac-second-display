# Arquitectura y decisiones

```text
MacBook M5                                         iMac Intel
DisplayHelper → pantalla virtual
  → ScreenCaptureKit → VideoToolbox H.264 (High, LLRC)
    → TLS 1.2 + TCP ─ cable USB (CDC-NCM) o Wi‑Fi/Ethernet ─→ VideoToolbox (decodifica)
                                                              → AVSampleBufferDisplayLayer → panel
                  ← ACK al mostrar la imagen decodificada · reporte de la iMac cada segundo ←
```

## Pantalla y compatibilidad

`CGVirtualDisplay` es una API privada, ausente de los encabezados públicos del SDK.
El puente Objective-C resuelve clases en ejecución y convierte fallos en errores.
Se revisaron Chromium (BSD-3-Clause) y DeskPad (MIT); las declaraciones adaptadas
de Chromium y su licencia están en `THIRD_PARTY_NOTICES.md`.

El helper mantiene la pantalla mientras stdin siga abierto. Si muere el emisor,
EOF termina el helper. Desconectar cierra el pipe; SIGTERM sirve como respaldo.
Se usa un número de serie aleatorio del prototipo, sin leer el del hardware.
La virtual se coloca a la derecha, se comprueba que no sea principal ni duplicada,
y se captura por ID exacto. Activar duplicación detiene la sesión.

La prueba de pantalla/ventana independiente pasó en la M5. Liberar el objeto dentro
del proceso no retiró el monitor; salir sí. No se promete estabilidad entre versiones
de macOS ni distribución por App Store.

Se eligió receptor nativo tras confirmar Sequoia 15.8.1 en el destino. Un navegador
requeriría validar WebRTC y códecs sin aportar una ventaja inmediata. Ambos binarios
tienen deployment target macOS 13.

## Enlaces y descubrimiento (v0.4.0)

Un cable USB‑A → USB‑C entre la iMac y la MacBook crea una red CDC‑NCM: la M5 actúa
como dispositivo USB y la iMac como host. Funcionamiento, mediciones y límites en
[Conexión por cable USB](CABLE_USB.md). Es comportamiento de macOS no documentado
para terceros; el código solo usa IOKit en lectura, sockets/Network.framework y `dns_sd`.

- `LinkInventory` lista interfaces activas con IPv4 privada o, en cables directos,
  IPv6 link‑local. Ordena por preferencia: cable USB, Thunderbolt, Ethernet, Wi‑Fi.
  El cable se reconoce por IOKit (`AppleUSBDeviceNCM*` en la MacBook; `AppleUSBNCM*`
  sobre un dispositivo Apple «Mac» en la iMac) y se excluyen las interfaces `anpi*`.
- El emisor revisa los enlaces cada 2 s. Sin elección manual, selecciona el mejor y
  aplica valores recomendados: con cable, 2560 × 1440 / 60 FPS / 40 Mbps; con
  Wi‑Fi, 1920 × 1080 / 30 FPS / 12 Mbps. Si el enlace de la sesión desaparece,
  cierra la sesión con un mensaje.
- Un listener por dirección del enlace elegido: IPv4 e IPv6 link‑local con ámbito.
  No escucha en otras interfaces.
- `BonjourAdvertiser` registra `_imacdisplay._tcp` con `DNSServiceRegister` en el
  índice de esa interfaz. `NWListener.service` anunciaría también en Wi‑Fi.
  TXT: `p=3` y el tipo de enlace. Se retira al aceptar al receptor.
- `SenderBrowser` (NWBrowser) lista emisores en el receptor. La conexión usa el
  endpoint del servicio y `requiredInterface` de la interfaz donde se encontró.
  La IP manual sigue disponible y limitada a IPv4 privada, link‑local o loopback.

## Video y protocolo

ScreenCaptureKit captura la virtual con cursor y sin audio, 420v, `queueDepth` 6.
VideoToolbox exige H.264 por hardware en el emisor, perfil **High** desde v0.4.0,
sin B-frames, con LLRC y RealTime. TCP no pierde datos, así que el IDR periódico de
2 s se reemplazó por uno de respaldo cada 60 s: evitaba picos y caídas de nitidez.
Las marcas de tiempo salen de un reloj monotónico propio; el receptor no las usa.

**Refinamiento de pantalla quieta.** ScreenCaptureKit no entrega imágenes si nada
cambia, de modo que el último cuadro conservaba la calidad con la que llegó: el
primer IDR de 1440p sale más blando. Tras tres intervalos sin cambios se reenvía la
última imagen para que el encoder la afine, como máximo 8 veces. Se detiene antes si
la salida del encoder baja de 2 KB, porque ya convergió. Solo se envía con el flujo
vacío, así que una imagen real espera como máximo un refinamiento. Medido con texto real a 1440p/40 Mbps: 37.4 → 40.4 dB tras
el primer cuadro; 40.0 → 40.4 dB tras cambiar de página. Ver [Pruebas](PRUEBAS.md).

TCP lleva longitud de 32 bits big-endian, tipo y payload, con límite de 8 MiB.
Cada paquete H.264 incluye secuencia, SPS, PPS y muestra AVCC. Se validan longitudes,
unidades NAL y resolución. `TCP_NODELAY` activado y clase de servicio de video
interactivo (en Wi‑Fi, cola de video WMM).

Hasta tres fotogramas reservados desde la entrada al encoder hasta el ACK. Si se
agotan los créditos, se conserva solo la imagen cruda más reciente y se envía al
liberarse espacio, aunque ScreenCaptureKit ya no produzca cambios. No se descartan
muestras H.264 codificadas, porque otras dependen de ellas.

**Saludo v3 (v0.4.0).** El receptor decodifica con `VTDecompressionSession` (hardware
si existe, sin exigirlo), muestra la imagen ya decodificada con `DisplayImmediately`
y recién entonces envía el ACK. Así la ventana de tres acota la latencia hasta el
panel y la iMac marca el ritmo si decodifica más lento. Si la capa aún tiene una
imagen pendiente, se reemplaza en vez de acumular retraso. Si no se puede crear la
sesión de VideoToolbox, se usa el camino anterior (H.264 comprimido hacia
AVSampleBufferDisplayLayer, ACK al encolar). Cada segundo el receptor envía un
reporte (tipo 7): FPS mostrados, ms de decodificación, hardware/software y si usa el
camino de respaldo. El emisor lo muestra junto a sus métricas.

Compatibilidad: el emisor v0.4 acepta saludos v1 (ventana de uno), v2 y v3. Un
emisor anterior rechaza el saludo v3, por lo que el receptor v0.4 necesita emisor
v0.4; el receptor lo indica si el emisor cierra justo tras el saludo.

Las métricas usan reloj monotónico y ventana móvil de dos segundos. Captura cuenta
imágenes completas de ScreenCaptureKit; los refinamientos se cuentan aparte. Entrega
cuenta ACKs. Preparación mide desde el callback de captura hasta serializar el video,
incluida espera de crédito. ACK mide desde esa serialización hasta la confirmación;
con v3 incluye red, decodificación y presentación. No es latencia de movimiento a fotón.

Heartbeat cada 2 segundos; ausencia de respuesta durante 10 segundos o de ACK por
más de 5 segundos cierra la sesión. Reconexión manual con clave nueva. No hay
servicios externos ni señalización en Internet.

## Actividad y reposo

`StreamActivity` solicita actividad `.userInitiated` y `.latencyCritical` durante
la transmisión. Así declara que el trabajo en segundo plano responde al usuario.
El receptor agrega `.idleDisplaySleepDisabled` después de mostrar la primera imagen.
La actividad se libera en desconexión, fallo, reposo explícito o terminación.
No se cambian ajustes globales de energía. Medir consumo en sesiones largas en iMac.

## Emparejamiento

Clave de 256 bits generada con `SecRandomCopyBytes`, nueva por sesión y transferida
manualmente por un canal de confianza. TLS 1.2 usa `TLS_PSK_WITH_AES_128_GCM_SHA256`.
No se guarda la clave en archivos ni se imprime en logs. Esta suite PSK **no ofrece
forward secrecy**; conservar la clave privada y rotarla es parte del diseño del prototipo.

Un solo cliente y confirmación local del emisor antes de capturar. No se usa una
verificación que acepte cualquier certificado. La clave equivocada falló en la prueba.
No hay NAT traversal ni apertura de puertos. No exponer el puerto al exterior; una
IP privada no protege contra un router configurado para reenviarlo.

## Diagnóstico y actualizaciones

Desde v0.3.1, una cola serial de escritura guarda diagnósticos locales en tres
archivos de 1 MiB por app. Solo admite etiquetas literales, números y banderas;
las causas de error se reducen a dominios conocidos y códigos, sin descripciones
ni `userInfo`. v0.4.0 añade tipo de enlace, velocidad USB, resultado de Bonjour,
decodificación por hardware y reportes del receptor, sin IP ni nombres de interfaz.
Ver [diagnóstico](DIAGNOSTICO.md).

La actualización de aplicaciones usa un canal separado de la transmisión: feeds
y ZIPs en GitHub por HTTPS, con firmas Ed25519 verificadas por Sparkle. No transmite
video, claves de sesión ni contenido del escritorio a GitHub. La consulta automática
se puede desactivar. Detalles en [Actualizaciones](ACTUALIZACIONES.md).

## Referencias primarias

- [Apple: requisitos de Target Display Mode](https://support.apple.com/105126), que no cubren la M5.
- [Chromium: pantalla virtual](https://github.com/chromium/chromium/blob/main/ui/display/mac/test/virtual_display_util_mac.mm).
- [DeskPad](https://github.com/Stengo/DeskPad).
- [Apple: ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit).
- [Apple: WWDC23 ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2023/10136/), introducido en macOS 12.3; nuestro target es 13.
- [Apple: clave TLS precompartida](https://developer.apple.com/documentation/security/sec_protocol_options_add_pre_shared_key(_:_:_:)).
- [Apple: protocolo entre dispositivos](https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol).
- [Apple: AVSampleBufferDisplayLayer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer).
- [Apple: VTDecompressionSession](https://developer.apple.com/documentation/videotoolbox/vtdecompressionsession).
- [Apple: DNSServiceRegister](https://developer.apple.com/documentation/dnssd/1804733-dnsserviceregister).
- [Apple: actividades y App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheAppLevel.html).
- [Revisión de LanScreen, decisiones y licencia](COMPARACION_LANSCREEN.md).
