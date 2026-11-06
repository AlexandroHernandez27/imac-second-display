# Registro de pruebas

## 2026-10-27 · v0.1.0 · MacBook M5

- Compilación: PASS. Emisor arm64 y receptor universal x86_64/arm64.
- `codesign --verify --strict`: PASS para ambas apps; firma local, sin notarización.
- `test-display.sh --run`: PASS. Pantalla nueva 1920 × 1080, sin duplicación,
  ventana en el monitor virtual; lista inicial restaurada al salir del proceso.
- `test-protocol.sh --run`: PASS. H.264 por hardware, decodificación de tamaño/color,
  TLS-PSK, integridad, ACK, rechazo de clave incorrecta y de mensajes incompletos.
- Ambas apps abren. El receptor local completa TLS y el emisor solicita aceptación
  explícita antes de capturar.
- Al faltar permiso de captura, el emisor mostró el error y cerró la sesión.
- Se corrigió un bloqueo por consultar una propiedad opcional de aceleración
  que devolvía -12900. La creación del encoder sigue exigiendo hardware, sin fallback.
- El test también comprueba que el encoder produce el primer fotograma sin flush.
- Se observó un permiso obsoleto tras recompilar con firma ad hoc: el interruptor
  estaba activado pero el proceso recibía una denegación. Se renovó el registro
  de la app actual; el procedimiento está en el documento de continuidad.
- Captura real con ambas apps en la MacBook: PASS a 1920 × 1080, configuración de
  30 FPS / 12 Mbps. Se verificó visualmente en el receptor el patrón de texto que
  reside en la pantalla virtual. El escritorio principal mantiene su interfaz.
  Se usó la IP LAN del propio equipo; no mide el enlace Wi‑Fi entre dos Macs.
- Con escritorio mayormente estático se observaron 3,8–4,8 FPS entregados y ACK
  0–1 ms. No son un benchmark de FPS máximos ni latencia de extremo a extremo.
- Entrada al modo de pantalla completa: comprobada. La herramienta de inspección
  de ventanas perdió su captura al alternar ese modo (errores -3811/-3812 de la
  herramienta, no un error mostrado por el receptor). Verificar manualmente Esc
  y salida de pantalla completa en la iMac; no se da por validada esa salida.
- Terminación del proceso del emisor: el receptor mostró «El otro equipo se
  desconectó» y habilitó los controles de conexión. La consulta de pantallas
  posterior confirmó que solo quedaba la pantalla original.

## Reporte del usuario · v0.1.0 en iMac

El usuario reportó imagen con «H.264 por hardware · 2.9 FPS entregados · 0.6 Mbps ·
ACK 7 ms» y retraso al mover ventanas o escribir. Resolución, límite de FPS y tiempo
de sesión no registrados. El texto de hardware se refiere al **encoder de la MacBook**,
no confirma aceleración de decodificación Intel. El contador de FPS acumulaba toda
la sesión, incluyendo periodos quietos. No se atribuye el retraso solo a Wi‑Fi.

## 2026-10-27 · v0.2.0 · MacBook M5

- Compilación completa: PASS. Sender arm64, Receiver universal arm64/x86_64.
- Protocolo: PASS. H.264 real con dimensiones/color correctos; parser rechaza
  truncamientos/tamaños inválidos; TLS-PSK entrega tres muestras en tránsito y sus
  ACKs en orden; clave equivocada rechazada sin video.
- Flujo: PASS. Máximo tres pendientes, reemplazo de imagen cruda, último cambio
  enviado tras ACK sin otra captura, rechazo de ACK duplicado/desordenado y ventana
  de uno compatible con el receptor anterior.
- Métricas: PASS. Tras un minuto inactivo, dos segundos a 60 FPS se reflejan como
  aproximadamente 60, no como promedio de toda la sesión. Los datos caducan al
  detenerse la fuente y no conservan un ACK antiguo como si fuera actual.
- Receptor: PASS. Cola lenta de tres, rechazo de exceso, ACK ordenado y descarte
  de callbacks de la sesión anterior tras reset.
- Actividad: una prueba local con `StreamActivity` y `pmset -g assertions` confirmó
  `PreventUserIdleDisplaySleep` y `PreventUserIdleSystemSleep` durante la sesión y
  su retirada al detenerla. No se modificaron preferencias globales de energía.
  Falta medir impacto real de App Nap y consumo en la iMac.

### Benchmark del flujo final

Ejecutado con `bash scripts/test-video-performance.sh --run`: fuente sintética
1920 × 1080 / 60 FPS / 12 Mbps, 180 imágenes por caso, encoder por hardware de
producción, parser y FrameReceiver reales, decoder VideoToolbox. El ACK se demora
artificialmente **después** de decodificar. No usa sockets, ScreenCaptureKit ni panel.
FPS de la ventana de dos segundos al final del movimiento; pueden exceder levemente
el objetivo por límites de ventana y temporización.

| Ventana | Demora artificial de ACK | FPS captura / entrega | Preparación | ACK medido | Último marcador |
| --- | --- | --- | --- | --- | --- |
| 1 | 7 ms | 60.0 / 60.0 | 4.6 ms | 9.7 ms | 180/180 |
| 3 | 7 ms | 60.0 / 60.0 | 4.6 ms | 9.5 ms | 180/180 |
| 1 | 40 ms | 60.5 / 20.0 | 17.4 ms | 45.4 ms | 180/180 |
| 3 | 40 ms | 60.0 / 60.0 | 4.5 ms | 43.6 ms | 180/180 |

PASS: todos conservan la última actualización al detener la fuente y vacían sus
colas. La ventana de tres sostiene el flujo con ACK demorado. La ventana de uno
usa el **código nuevo configurado a uno**, no es una ejecución del binario v0.1.0.
Un ensayo previo dio 19.5 frente a 58 FPS con demora de 40 ms; la variación entre
ejecuciones impide prometer un valor exacto. A 7 ms ambas ventanas alcanzan 60 FPS
en este entorno: ese ACK no explica por sí solo el reporte de 2.9 FPS.

### Referencia externa

Se revisó LanScreen y se compararon tres configuraciones del encoder en dos rondas.
PASS en entrega y último marcador; la ventaja observada de desactivar LLRC/RealTime
fue pequeña. Se conservan ambos activados en producción.
Ver [comparación, resultados y fuentes](COMPARACION_LANSCREEN.md).

Pendientes en v0.2.0: captura real con la nueva versión y ambos equipos, aceleración
Intel, salida de pantalla completa, 1440p/60 FPS, latencia física, CPU/memoria,
sesión de 30 minutos, reconexión, cortes Wi‑Fi y reposo. Las pruebas de v0.1.0 no
se presentan como si se hubieran repetido con v0.2.0.

## 2026-10-27 · v0.3.0 · Actualizador

- Compilación: PASS. Sender arm64 y Receiver universal con Sparkle 2.10.1. El
  archivo oficial coincidió con el SHA-256 fijado y pasó verificación de firma.
- Fixture independiente: app con bundle ID único, clave de prueba independiente,
  feed firmado y ZIP servido solo en loopback. No se capturó ni transmitió escritorio.
- Firma Ed25519: PASS con CryptoKit. Se rechazaron el ZIP modificado en un byte y
  la verificación con una clave ajena.
- Bloqueo durante sesión simulada: PASS. Al pulsar Buscar actualizaciones mostró
  «Desconecta la pantalla antes de buscar actualizaciones», sin consultar el feed.
- Instalación real: PASS. Sparkle verificó el feed y archivo, sustituyó la app de
  prueba y relanzó de 0.0.1 a 0.0.2; luego se observaron 0.0.3 y 0.0.4. El usuario
  confirmó que pulsó instalar/reiniciar durante el ensayo. Hubo también una
  confirmación de instalación realizada desde la herramienta en la primera prueba.
  La versión instalada se verificó en la interfaz y el Info.plist del bundle.
- La herramienta visual sufrió esperas prolongadas; no se usaron capturas en blanco
  como evidencia. El comportamiento de posponer/omitir queda por ensayar manualmente:
  en las rondas realizadas se aceptó instalar. La política de no descargar/instalar
  silenciosamente está fijada en ambos Info.plist y es verificada al empaquetar.
- Se cerraron la app de prueba y el servidor loopback al terminar.

Pendiente: actualización real en Intel/Sequoia, conservación o renovación de permisos
en una instalación de usuario, carpeta protegida que solicite autorización, caída de
red durante descarga y posponer/omitir en UI. La prueba de sustitución local no
certifica esas situaciones. El flujo de video no cambió en esta versión.

## 2026-10-27 · v0.3.1 · Diagnóstico y protocolo incompatible

Reporte: Receiver indicaba «El otro equipo se desconectó» y Sender «El receptor
usa un protocolo incompatible» después de descargar v0.3.0. Se inspeccionó el bundle
del proceso activo: todavía era **Sender v0.1.0/build 1** y su ejecutable contenía
exactamente ese texto. Esa versión rechaza el saludo v2. Una comprobación posterior
ya encontró Sender v0.3.0/build 3 abierto. No se registra todavía un resultado de
conexión entre los dos equipos con las copias correctas.

- Compilación Sender arm64 y Receiver arm64/x86_64: PASS.
- Diagnósticos: PASS en escritura concurrente, tres archivos acotados, permisos
  0700/0600, historial tras reinicio, metadatos en exportación después de rotar,
  códigos TLS y errores subyacentes, omisión de datos sensibles sintéticos y
  comunicación del fallo de almacenamiento. `bash scripts/test-diagnostics.sh --run`.
- Protocolo: PASS en H.264 y color/dimensiones, saludos v1/v2 y rechazo de desconocidos,
  TLS real con tres muestras/ACKs, cierre remoto registrado y clave incorrecta
  rechazada con código TLS. No se registró la dirección de loopback.
  El primer intento dentro del sandbox falló al crear el encoder con -12902;
  al ejecutar con acceso al hardware las pruebas pasaron.
- Pipeline: PASS en cuatro casos sintéticos de ventana uno/tres y ACK artificial
  de 7/40 ms; todos entregaron el marcador final 180/180. No es una prueba Wi‑Fi,
  de ScreenCaptureKit ni del panel; no se atribuye una mejora de rendimiento a esta versión.
- App real: Receiver v0.3.1 inició y guardó `app_launch` con build 4 y protocolo 2.
  La herramienta de interfaz falló con ScreenCaptureKit -3811; no se da por verificada
  visualmente la hoja de guardar. La generación del archivo y la persistencia sí
  se probaron mediante el código de producción.

Pendiente: usar el botón de exportación en ambos equipos, reconectar con Sender y
Receiver actuales, medir en Intel y confirmar la conservación/renovación de permisos
después de actualizar. Esta versión no cambia el formato v2 del transporte.

## 2026-11-06 · v0.4.0 · Cable USB‑A → USB‑C y fluidez

### Enlace físico con la iMac (sin la app de video)

El usuario conectó un cable USB‑A (iMac) → USB‑C (MacBook) con ambas encendidas.
Observado desde la MacBook con `ioreg`, `ifconfig`, `log stream`, `ping6` y `netstat`:

- La iMac enumeró la MacBook como dispositivo USB y la configuró (configuración 1).
  Driver host de la iMac: `AppleUSBNCM` 24.6.0, coherente con Sequoia.
- Velocidad: **High Speed, 480 Mbps**. El controlador de la M5 intentó USB 3 y
  terminó en USB 2.0: el cable probado parece USB 2.0.
- La interfaz pública NCM de la MacBook pasó a activa con IPv6 link‑local inmediata
  e IPv4 169.254.x.x a los ~21 s. La iMac también obtuvo ambas (vecino NDP y ARP).
- Latencia ICMPv6: 0.6–0.9 ms. Capacidad MacBook → iMac: **≈340 Mbps** durante 3 s
  (UDP descartado por la iMac, medido con el contador de bytes de salida).
- Bonjour visible en el enlace. Alimentación de la iMac: 5 V / 500 mA.
- `remoted` de Apple usa en paralelo la interfaz privada `anpi*`; la app no la toca.

Detalles y límites: [Conexión por cable USB](CABLE_USB.md).

### Calidad del encoder con texto real (M5, 2560 × 1440, 60 FPS)

Experimentos con páginas de texto CoreText, encoder por hardware de producción y
PSNR sobre la imagen decodificada. El techo de ~40.5 dB se debe a la conversión de
color de la prueba; visualmente el texto decodificado coincidía con el original.

- Desplazamiento de texto: 2–8 KB por cuadro gracias a la compensación de movimiento.
  Recodificar el mismo cuadro ya estable no mejora nada: el encoder emite cuadros vacíos.
- El **primer IDR** sale más blando (~37 dB a 40 Mbps) y solo mejora si se envían más
  cuadros. ScreenCaptureKit no los envía con la pantalla quieta → se implementó el
  refinamiento adaptativo.
- 80 Mbps no mejora la nitidez estática frente a 40 Mbps con LLRC. `MaxAllowedFrameQP`
  bajo con LLRC descartó cuadros y `Quality` no está soportado (-12900): no se usan.

### Compilación y pruebas automáticas

- `bash scripts/build.sh`: PASS. Sender arm64, Receiver universal x86_64/arm64,
  `codesign --verify --deep --strict` PASS. Los overlays Swift débiles del receptor
  solo importan marcadores de carga, sin símbolos funcionales.
- `test-protocol.sh --run`: PASS (H.264, TLS-PSK, tres muestras y ACKs, cierre remoto,
  clave incorrecta). `test-diagnostics.sh --run`: PASS.
- `test-link.sh --run --require-usb`: PASS con el cable conectado. Detectó «Cable USB ·
  USB 2.0 · 480 Mbps» y Wi‑Fi. Bonjour quedó solo en la interfaz del cable, con su
  tipo en TXT. TLS-PSK por el endpoint Bonjour, IPv4 e IPv6 link‑local → saludo v3 →
  decodificación de producción → ACKs → reporte. El registro no contiene IP ni interfaz.
  Ambos extremos estaban en la MacBook: el tráfico no cruzó el cable.
- `test-video-performance.sh --run`: PASS.

| Caso | Resultado |
| --- | --- |
| Ventana 3, ACK artificial 40 ms, 1080p | 60 FPS entregados (ventana 1: ~20) |
| Receptor de producción, 2560 × 1440, 60 FPS, 40 Mbps | 60.0 FPS mostrados, decodificación por hardware 1.5–1.7 ms, ACK 1.5–1.8 ms |
| Texto quieto tras el primer cuadro | 37.43 dB → **40.40 dB** refinado (8 cuadros extra) |
| Texto quieto tras cambiar de página | 40.01 dB → 40.40 dB (5 cuadros extra) |

El receptor de producción en la M5 decodifica por hardware de Apple Silicon: no
predice el decoder de la iMac Intel.

- Arranque: Sender v0.4.0 abrió y registró la detección del cable. Receiver v0.4.0
  x86_64 bajo Rosetta abrió e inició la búsqueda Bonjour. Sin sesión de video.

Pendiente: escritorio real por el cable hasta la iMac, FPS mostrados y decodificación
hardware/software en la iMac, latencia percibida al escribir y mover ventanas, CPU,
sesión de 30 minutos, desconectar el cable durante la sesión, reposo y otro puerto.
No se afirma todavía que la pantalla sea fluida en la iMac.

## 2026-11-06 · v0.4.0 en la iMac por cable · primer intento real

Registro de Sender en la MacBook (Receiver no exportado):

- Primer intento por cable: TLS-PSK listo, saludo v3, aceptación del usuario, pantalla
  virtual 2560 × 1440 independiente. Falló en `capture_permission_result granted: false`:
  la build v0.4.0 (firma ad hoc nueva) no tenía permiso de grabación de pantalla.
- Tres intentos siguientes: `transport_failed` TLS **-9846 (bad MAC)** en el emisor y
  «bad MAC» en la iMac. La iMac usaba la clave de una sesión anterior; cada intento
  cerraba la espera del emisor y el siguiente «Preparar conexión» generaba otra clave.
- El enlace USB se desconectó y volvió a conectar una vez durante la prueba.

No se llegó a ver escritorio en la iMac. Primer dato real: el transporte por cable,
TLS y el saludo v3 funcionan entre ambos equipos.

## 2026-11-06 · v0.4.1 · Cable sin clave

Decisión del usuario: por cable USB no compartir clave. Ver [CABLE_USB](CABLE_USB.md).

- Experimento en la M5 con clave equivocada: el servidor falla con -9846 al instante;
  el cliente queda en `waiting(-9820)` por IP, y en `preparing` indefinido contra el
  servicio Bonjour. Corregido: ambos códigos cierran con «La clave no coincide» y el
  receptor resuelve el servicio por UDP antes de conectar (resolución en ~10 ms).
- `test-link.sh --run --require-usb`: PASS. Añade clave fija válida, huella, detección
  de clave distinta, clave equivocada → mensaje claro → conexión correcta después, y
  modo sin clave: anuncio `auth=usb` con identificador de espera → TLS con clave fija →
  video, ACKs y reporte. Ambos extremos en la MacBook.
- Protocolo, diagnóstico y video: PASS (1440p/60 decodificado a 60 FPS en la M5;
  texto quieto 37.43 → 40.40 dB).
- Receiver v0.4.1 x86_64 bajo Rosetta: abre e inicia la búsqueda.

Sin probar en la iMac: conexión automática por cable, rechazo de procesos locales y
escritorio real. La detección del cable en el lado iMac (`IOUSBHostDevice` Apple «Mac»)
se corrigió sin poder verificarla en ese equipo.
