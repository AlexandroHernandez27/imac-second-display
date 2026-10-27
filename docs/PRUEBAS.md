# Registro de pruebas

## 2026-10-27 · MacBook M5

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

Pendientes: ejecución en iMac, 1440p/60 FPS, latencia de extremo a extremo,
CPU/memoria, reconexión prolongada, cortes reales de Wi‑Fi y reposo de ambos equipos.
