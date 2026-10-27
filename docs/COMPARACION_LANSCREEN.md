# Revisión de LanScreen

Revisado el 2026-10-27 a petición del usuario:
[kendalpercimoney/imac-second-display](https://github.com/kendalpercimoney/imac-second-display),
commit [`e18e2459a88d82a47fdbce8631c825d7c1dee94b`](https://github.com/kendalpercimoney/imac-second-display/tree/e18e2459a88d82a47fdbce8631c825d7c1dee94b).
Se leyó código además del README; este último conserva apartados que no describen
todos los cambios recientes del encoder y otras funciones.

## Qué aporta a este proyecto

| Idea observada | Decisión |
| --- | --- |
| Pantalla virtual, ScreenCaptureKit y VideoToolbox | Confirma la misma arquitectura básica. Ya están implementados aquí. |
| Actividad explícita para evitar App Nap | Incorporada con implementación propia usando Foundation y documentación de Apple. Se libera al terminar la sesión. |
| Mantener encendido el panel receptor durante la sesión | Incorporado con `ProcessInfo`, sin modificar preferencias globales. |
| Cola pequeña y recuperación al perder H.264 | Nuestra ventana de tres y reserva del último cambio ya estaban en desarrollo antes de esta revisión. Conservamos la cadena de muestras codificadas. |
| RTP/UDP y solicitud de keyframes | Candidato posterior si medimos bloqueo por retransmisión TCP. Requiere autenticación, cifrado y recuperación ante pérdida para nuestra LAN Wi‑Fi. |
| Cursor por canal independiente | Próxima mejora posible de la respuesta del puntero. No corrige por sí sola el retraso al escribir o mover el contenido de una ventana. |
| VTDecompressionSession explícita y presentación con IOSurface/OpenGL | Interesa medir decodificación y confirmar hardware en Intel. No reemplazamos aún AVSampleBufferDisplayLayer; hace falta comparar en la iMac. |
| Probar configuraciones del encoder en vez de confiar en sus nombres | Comparación local realizada; resultados abajo. Conservamos los valores de producción. |

LanScreen está orientado a un enlace Ethernet directo y su README documenta una
pareja M1 Pro/iMac 2010. Nuestro destino es M5/iMac Late 2013 con Sequoia y prioridad
Wi‑Fi. Su transporte RTP no cifra el video; no se sustituye directamente nuestro
canal TLS. La iMac 2010 tampoco permite inferir el límite del decoder de la 2013.

Fuentes de la comparación:

- [Captura](https://github.com/kendalpercimoney/imac-second-display/blob/e18e2459a88d82a47fdbce8631c825d7c1dee94b/Host/Sources/CaptureEngine.swift), [encoder](https://github.com/kendalpercimoney/imac-second-display/blob/e18e2459a88d82a47fdbce8631c825d7c1dee94b/Host/Sources/VideoEncoder.swift) y [actividad de la sesión](https://github.com/kendalpercimoney/imac-second-display/blob/e18e2459a88d82a47fdbce8631c825d7c1dee94b/Host/Sources/StreamController.swift).
- [Cursor](https://github.com/kendalpercimoney/imac-second-display/blob/e18e2459a88d82a47fdbce8631c825d7c1dee94b/Host/Sources/CursorTracker.swift), [cola del decoder](https://github.com/kendalpercimoney/imac-second-display/blob/e18e2459a88d82a47fdbce8631c825d7c1dee94b/Client/src/LSDecodeQueue.m), [decoder](https://github.com/kendalpercimoney/imac-second-display/blob/e18e2459a88d82a47fdbce8631c825d7c1dee94b/Client/src/LSDecoder.m) y [renderer](https://github.com/kendalpercimoney/imac-second-display/blob/e18e2459a88d82a47fdbce8631c825d7c1dee94b/Client/src/LSGLView.m).
- [Apple: actividades que evitan App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheAppLevel.html).

## Comparación del encoder en la M5

El código de LanScreen propone desactivar `EnableLowLatencyRateControl` y `RealTime`
a partir de sus mediciones. Se comparó con **nuestro** pipeline: 1080p/60, 12 Mbps,
fuente BGRA sintética, ventana de tres, decoder real, ACK artificial de 7 ms.
Dos rondas en orden inverso; 180 imágenes por caso, excluyendo las primeras 30
de la estadística de latencia. Medición desde entrada al pipeline hasta callback
decodificado, sin capturar escritorio, sockets ni panel. La captura real usa 420v.

| LLRC / RealTime | Mediana ronda 1 / 2 | p95 ronda 1 / 2 |
| --- | --- | --- |
| Activado / activado, producción | 8.77 / 8.56 ms | 10.59 / 10.61 ms |
| Desactivado / activado | 8.84 / 8.97 ms | 10.04 / 9.89 ms |
| Desactivado / desactivado | 7.72 / 8.45 ms | 9.69 / 9.25 ms |

Todos entregaron aproximadamente 60 FPS y la última imagen después de detener
la fuente. Desactivar ambos ahorró entre 0.11 y 1.05 ms de mediana frente a la
configuración actual; esta prueba corta no justifica cambiar producción. Faltan
captura real 420v, contenido complejo, carga sostenida y el decoder Intel. No explica
por sí sola el retraso reportado ni demuestra una mejora de varios FPS en Wi‑Fi.

Reproducir en la MacBook:

```bash
bash scripts/test-video-performance.sh --run --compare-encoder
```

## Licencia y procedencia

LanScreen publica su código bajo [GPLv3](https://github.com/kendalpercimoney/imac-second-display/blob/e18e2459a88d82a47fdbce8631c825d7c1dee94b/LICENSE);
los encabezados permiten versión 3 o posterior. No se copiaron ni tradujeron sus
archivos, implementaciones ni recursos. Las nuevas llamadas a Foundation se
implementaron aquí siguiendo la API de Apple. Esta revisión no cambia la licencia
del proyecto. Si después se incorpora código de LanScreen, revisar antes las
obligaciones de distribución y atribución correspondientes.

## Orden de pruebas siguiente

1. Probar v0.2.0 en la iMac con patrón animado y registrar captura, entrega,
   preparación, ACK y CPU. Comparar 1080p/30 y 1080p/60.
2. Si captura es alta pero entrega baja, separar tiempo de red y decodificación.
   Confirmar aceleración Intel antes de cambiar renderer o transporte.
3. Si las retransmisiones Wi‑Fi dominan, comparar Ethernet con el mismo protocolo;
   luego evaluar transporte de datagramas cifrado con recuperación por keyframe.
4. Evaluar canal de cursor y nitidez de texto con mediciones propias.
