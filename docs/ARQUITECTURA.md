# Arquitectura y decisiones

```text
MacBook M5                                    iMac Intel
DisplayHelper → pantalla virtual
  → ScreenCaptureKit → VideoToolbox H.264
    → TLS 1.2 + TCP en LAN → AVSampleBufferDisplayLayer → panel
                  ← ACK al encolar el fotograma ←
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
tienen deployment target macOS 13. El uso de aceleración en la iMac debe medirse.

## Video y protocolo

ScreenCaptureKit captura la virtual con cursor y sin audio. VideoToolbox requiere
H.264 por hardware en el emisor, perfil Main, sin B-frames y con keyframes periódicos.
El receptor decodifica/presenta con AVSampleBufferDisplayLayer.

TCP lleva longitud de 32 bits big-endian, tipo y payload, con límite de 8 MiB.
Cada paquete H.264 incluye secuencia, SPS, PPS y muestra AVCC. Se validan longitudes,
unidades NAL y resolución. El receptor confirma al encolar, no al presentar.

En v0.2.0 hay hasta tres fotogramas reservados desde entrada al encoder hasta ACK.
Si se agotan los créditos, se conserva únicamente la imagen cruda más reciente;
al llegar un ACK se envía aunque ScreenCaptureKit ya no produzca cambios. No se
descartan muestras H.264 codificadas, porque otras pueden depender de ellas.
La cola propia del receptor admite tres muestras y conserva el orden al entregarlas
a AVSampleBufferDisplayLayer. La cola interna de AVFoundation no se mide aquí;
se respeta `isReadyForMoreMediaData`. Por tanto, esto no garantiza un máximo de
tres imágenes hasta el panel físico.

El hello v2 negocia la ventana de tres. El emisor v0.2.0 acepta también hello v1
con ventana de uno. Un receptor v0.2.0 necesita emisor v0.2.0: actualizar ambos.
El formato de muestras y ACK se conserva. `TCP_NODELAY` está activado.

Las métricas usan reloj monotónico y ventana móvil de dos segundos. Captura cuenta
las imágenes completas de ScreenCaptureKit; entrega cuenta ACKs. Preparación mide
desde el callback de captura hasta serializar el video, incluida espera de crédito;
ACK mide desde esa serialización hasta recibir la confirmación. No es RTT puro ni
latencia de movimiento a fotón. Bitrate muestra bytes de video, sin sobrecarga TLS/TCP.
Un escritorio estático puede bajar a cero FPS sin avería.

Heartbeat cada 2 segundos; ausencia de respuesta durante 10 segundos o de ACK por
más de 5 segundos cierra la sesión. Reconexión manual con clave nueva. Ethernet
reutiliza el mismo protocolo; no hay servicios externos ni señalización en Internet.

## Actividad y reposo

`StreamActivity` solicita actividad `.userInitiated` y `.latencyCritical` durante
la transmisión. Así declara que el trabajo en segundo plano responde al usuario.
El receptor agrega `.idleDisplaySleepDisabled` después de encolar la primera imagen.
La actividad se libera en desconexión, fallo, reposo explícito o terminación. El
heartbeat mantiene viva una pantalla estática, pero una conexión perdida termina
la sesión y libera la actividad. No se cambian ajustes globales de energía.
Se espera mayor consumo que con una app suspendida; medir sesiones largas en iMac.

## Emparejamiento

Clave de 256 bits generada con `SecRandomCopyBytes`, nueva por sesión y transferida
manualmente por un canal de confianza. TLS 1.2 usa `TLS_PSK_WITH_AES_128_GCM_SHA256`.
No se guarda la clave en archivos ni se imprime en logs. Esta suite PSK **no ofrece
forward secrecy**; conservar la clave privada y rotarla es parte del diseño del prototipo.

Un solo cliente y confirmación local del emisor antes de capturar. No se usa una
verificación que acepte cualquier certificado. La clave equivocada falló en la prueba.
El listener enlaza la IPv4 privada elegida; el receptor limita destinos a IPv4 privada,
link-local o loopback. No hay NAT traversal ni apertura de puertos. No exponer el puerto
al exterior; una IP privada no protege contra un router configurado para reenviarlo.

## Referencias primarias

La actualización de aplicaciones usa un canal separado de la transmisión: feeds
y ZIPs en GitHub por HTTPS, con firmas Ed25519 verificadas por Sparkle. No transmite
video, claves de sesión ni contenido del escritorio a GitHub. La consulta automática
se puede desactivar. Detalles en [Actualizaciones](ACTUALIZACIONES.md).

- [Apple: requisitos de Target Display Mode](https://support.apple.com/105126), que no cubren la M5.
- [Chromium: pantalla virtual](https://github.com/chromium/chromium/blob/main/ui/display/mac/test/virtual_display_util_mac.mm).
- [DeskPad](https://github.com/Stengo/DeskPad).
- [Apple: ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit).
- [Apple: WWDC23 ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2023/10136/), introducido en macOS 12.3; nuestro target es 13.
- [Apple: clave TLS precompartida](https://developer.apple.com/documentation/security/sec_protocol_options_add_pre_shared_key(_:_:_:)).
- [Apple: protocolo entre dispositivos](https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol).
- [Apple: AVSampleBufferDisplayLayer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer).
- [Apple: actividades y App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheAppLevel.html).
- [Revisión de LanScreen, decisiones y licencia](COMPARACION_LANSCREEN.md).
