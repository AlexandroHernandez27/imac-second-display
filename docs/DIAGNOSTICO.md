# Revisar una desconexión

Desde v0.3.1 ambas apps guardan un registro local automáticamente. No hace falta
Terminal ni activar una opción antes del fallo. El botón **Exportar diagnóstico…**
y el menú **Diagnóstico** permiten guardarlo como texto; nada se envía automáticamente.

## Primero: comprobar qué aplicación está abierta

Descargar un ZIP no cierra ni sustituye el proceso que ya estaba abierto. En el
incidente inicial, el receptor mostraba «El otro equipo se desconectó» y el emisor
«El receptor usa un protocolo incompatible». La inspección del proceso del emisor
confirmó **v0.1.0, build 1**. Ese texto pertenece a v0.1.0; su protocolo v1 rechaza
el saludo v2 del receptor actual. No se detectó una regresión de protocolo en v0.3.0.

1. Sal de Sender y Receiver con **⌘Q**; cerrar o reemplazar un ZIP no es suficiente.
2. Coloca las aplicaciones actuales en una carpeta local, como `~/Applications`.
   Abre esas copias desde Finder. Un acceso antiguo del Dock puede abrir otra copia.
3. Desde v0.3.1 el título debe indicar **v0.3.1 (4)** en ambas ventanas.
   También se incluye versión, build y protocolo en el archivo de diagnóstico.
4. Prepara una sesión nueva, pega la nueva clave y conecta. Confirma en la MacBook.

v0.3.0 puede obtener v0.3.1 mediante **Buscar actualizaciones…**. v0.1.0 y v0.2.0
necesitan descargarla manualmente. El formato de red de v0.3.1 sigue siendo v2,
compatible con v0.2.0/v0.3.0; el emisor admite además un receptor v1 con ventana de uno.

## Exportar un fallo

1. Reproduce el fallo una vez y anota el mensaje que aparece en cada equipo.
2. Sin iniciar muchos intentos adicionales, pulsa **Exportar diagnóstico…** en
   **ambas** apps. Si las cerraste, puedes abrirlas y exportar: el historial persiste.
3. Guarda `iMac-Sender-diagnostico.txt` y `iMac-Receiver-diagnostico.txt`.
4. Comparte los dos archivos para revisar el mismo intento. No adjuntes claves ni
   capturas del escritorio. Estos registros no reconstruyen intentos de versiones
   anteriores a v0.3.1 y no contienen informes de crash completos del sistema.

## Qué se registra

- Fecha UTC, tiempo desde el arranque, rol, versión/build, macOS, arquitectura y RAM
  total en GiB. Un UUID nuevo identifica cada intento, no al dispositivo.
- Listener, negociación TLS, tipo de interfaz (Wi-Fi/Ethernet/loopback), disponibilidad
  de ruta y errores de red con dominio conocido y código numérico.
- Saludo/protocolo, petición de consentimiento y resultado, permiso de captura,
  creación de pantalla, inicio de captura/encoder y primera imagen enviada/encolada.
- Métricas cada cinco segundos, errores de renderer, cierres, timeouts y reposo.

No se registran claves, IP, nombres de equipo/usuario, seriales, rutas, nombres de
ventanas, imágenes, payloads ni descripciones arbitrarias de errores. Se permiten
solo etiquetas literales y números/banderas; los errores conservan códigos y hasta
dos causas subyacentes. No se adjuntan `userInfo` ni mensajes libres de macOS.

Los archivos están en `~/Library/Logs/iMac Second Display/Sender/` y `Receiver/`.
Cada app rota tres archivos de hasta 1 MiB, con permisos de propietario 0600 y
directorio 0700. El archivo exportado incluye ese historial y contexto de la versión
actual. No hay envío automático, servicio de telemetría ni registro por fotograma.
Una rotación puede eliminar intentos antiguos; exporta pronto después del fallo.

## Interpretar la secuencia

| Último evento o error | Qué investigar |
| --- | --- |
| `listener_failed` | IP seleccionada, puerto ocupado, permisos de red local |
| `transport_waiting` / `transport_failed` / error TLS | LAN, firewall, IP y clave; conservar código numérico |
| `hello_incompatible` | Versiones abiertas; comprobar título y `report_context` |
| `consent_requested` sin aceptación | Solicitud pendiente en la MacBook |
| `capture_permission_result` con `granted: false` | Permiso del Sender actual y reinicio de esa app |
| `display_helper_*` / `display_configuration_failed` | Creación de la pantalla virtual |
| `stream_start_failed` después de `capture_discovery_started` | ScreenCaptureKit; revisar dominio/código y permiso vigente |
| `encoder_*_failed` | VideoToolbox y OSStatus |
| `renderer_failed` / `renderer_timeout` | Decodificación/presentación en el receptor |
| `transport_header_incomplete` con EOF | El otro equipo cerró; buscar la causa en su registro |
| `video_ack_timeout` | La imagen dejó de avanzar; comparar métricas de ambos |

La aceptación/ACK de una muestra indica encolado, no que el panel la haya mostrado.
El registro no mide latencia física ni demuestra aceleración de decodificación Intel.
Los UUID son locales a cada app: correlacionar por hora UTC, rol y secuencia de eventos.

## Pruebas reproducibles

```bash
bash scripts/test-diagnostics.sh --run
bash scripts/test-protocol.sh --run
```

La primera comprueba concurrencia, rotación, límites, permisos, reinicio, códigos de
error sin datos privados y fallo de almacenamiento. La segunda utiliza TLS real en
loopback, H.264 y ACKs, verifica compatibilidad de saludos, cierre remoto y rechazo de
clave incorrecta con registros. No se captura el escritorio en estas pruebas.
