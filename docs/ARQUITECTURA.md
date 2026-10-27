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
unidades NAL y resolución. Solo hay un fotograma pendiente de ACK; el receptor confirma
al encolar, no al presentar. Esto acota la cola pero limita FPS según RTT.

Heartbeat cada 2 segundos; ausencia de respuesta durante 10 segundos o de ACK por
más de 5 segundos cierra la sesión. Reconexión manual con clave nueva. Ethernet
reutiliza el mismo protocolo; no hay servicios externos ni señalización en Internet.

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

- [Apple: requisitos de Target Display Mode](https://support.apple.com/105126), que no cubren la M5.
- [Chromium: pantalla virtual](https://github.com/chromium/chromium/blob/main/ui/display/mac/test/virtual_display_util_mac.mm).
- [DeskPad](https://github.com/Stengo/DeskPad).
- [Apple: ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit).
- [Apple: WWDC23 ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2023/10136/), introducido en macOS 12.3; nuestro target es 13.
- [Apple: clave TLS precompartida](https://developer.apple.com/documentation/security/sec_protocol_options_add_pre_shared_key(_:_:_:)).
- [Apple: protocolo entre dispositivos](https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol).
- [Apple: AVSampleBufferDisplayLayer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer).
