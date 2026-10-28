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
