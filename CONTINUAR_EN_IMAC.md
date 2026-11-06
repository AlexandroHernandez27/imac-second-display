# Continuar el desarrollo y las pruebas en la iMac

## Objetivo y equipos

Usar una iMac 27 pulgadas Late 2013 como pantalla extendida de una MacBook Pro M5,
preferentemente por **cable USB‑A → USB‑C** desde v0.4.0, o por Wi‑Fi. Las
aplicaciones corren en la MacBook; la iMac solo reproduce video.

- MacBook inspeccionada: M5, 16 GB; `sw_vers` reporta macOS 27.2 / build 26B123.
- Herramientas de la MacBook: Command Line Tools y Swift 6.2.1, sin Xcode completo.
- iMac: modelo y Sequoia 15.8.1 reportados por el usuario. Al conectar el cable, su
  driver `AppleUSBNCM` informó la versión 24.6.0. RAM, GPU y decodificación por
  hardware todavía no inspeccionadas en ese equipo. No inferirlas desde la MacBook.
- Acceso a ambas Macs confirmado; uso deseado: ventanas de cualquier aplicación.
- No cambiar macOS ni instalar parches para esta prueba. No se necesita Apple ID.

## Implementación disponible

`iMac Sender.app` crea la pantalla, captura solo ese ID, codifica H.264 High por
hardware y transmite por TLS. `iMac Receiver.app`, universal Intel/ARM, decodifica
con VideoToolbox y muestra con AVFoundation a pantalla completa. Hay búsqueda
automática por Bonjour, IP manual de respaldo, clave temporal, aceptación explícita,
resolución/FPS/bitrate configurables, patrón animado y cierre de sesión.

v0.4.0 añade:

- **Cable USB‑A → USB‑C:** la MacBook aparece en la iMac como adaptador de red USB
  (CDC‑NCM). Las apps lo detectan, lo prefieren y aplican 2560 × 1440 / 60 / 40 Mbps.
  Funcionamiento, mediciones y límites: [docs/CABLE_USB.md](docs/CABLE_USB.md).
- Bonjour solo en el enlace elegido; IPv6 link‑local disponible al conectar el cable.
- Decodificación explícita con VideoToolbox y **ACK al mostrar la imagen**: la ventana
  de tres fotogramas acota la latencia hasta el panel. Respaldo: el camino anterior.
- Reporte de la iMac a la MacBook cada segundo: FPS mostrados, ms de decodificación y
  si usa hardware o software. Se ven en las métricas del emisor.
- Refinamiento de la pantalla quieta, H.264 High y sin IDR periódico.
- Aviso y cierre al desconectar el cable; pantalla completa automática en la iMac.

La pantalla virtual vive en un proceso auxiliar: liberar `CGVirtualDisplay` dentro
del proceso no la retiraba inmediatamente. Salir del proceso sí la retira.

## Evidencia y límites de validación

Comprobado el 2026-11-06 con el cable conectado a la iMac (desde la MacBook): la
iMac enumeró la MacBook, USB 2.0 a 480 Mbps, ≈340 Mbps de capacidad, 0.6–0.9 ms de
latencia de red, direcciones link‑local en ambos extremos y Bonjour sobre el enlace.

Comprobado en la MacBook: compilación arm64/universal y firmas; protocolo y TLS;
diagnóstico; pruebas de enlace sobre la interfaz real del cable con ambos extremos en
la MacBook; decoder de producción a 1440p/60 (60 FPS, hardware de la M5); refinamiento
de texto quieto 37.4 → 40.4 dB; arranque del receptor x86_64 bajo Rosetta.

**Sin verificar todavía:** el escritorio real cruzando el cable hasta la iMac, los
FPS que muestra la iMac, si decodifica por hardware, latencia percibida, CPU, sesiones
largas, reposo y desconexión del cable. Ver [docs/PRUEBAS.md](docs/PRUEBAS.md).

Historial: en v0.1.0 por Wi‑Fi el usuario reportó «2.9 FPS · 0.6 Mbps · ACK 7 ms»
con retraso al escribir y mover ventanas. Esa lectura promediaba toda la sesión.
v0.2.0–v0.3.1 corrigieron el flujo y añadieron métricas y diagnóstico.

## Instalar v0.4.1

Actualiza **las dos apps**: el modo sin clave por cable necesita v0.4.1 en ambas. Desde v0.3.0
puedes usar **Buscar actualizaciones…** en cada app, con la pantalla desconectada.
Con v0.1.0/v0.2.0, descarga manualmente desde la release. Coloca cada app en una
carpeta local escribible, como `~/Applications`, y cierra la copia anterior con ⌘Q.
El título debe mostrar **v0.4.1 (6)**.

macOS puede volver a pedir autorización de apertura, grabación de pantalla (Sender) y
red local (ambas) por la firma ad hoc. La instalación no conserva necesariamente esos
permisos. Proceso de publicación: [docs/ACTUALIZACIONES.md](docs/ACTUALIZACIONES.md).

## Prueba por cable

1. Conecta el cable: USB‑A en la parte trasera de la iMac y USB‑C en la MacBook.
2. Abre iMac Receiver v0.4.1 en la iMac y déjalo abierto.
3. En la MacBook, comprueba en Ajustes → Privacidad y seguridad → Grabación de
   pantalla que **iMac Sender** esté activado (cada versión nueva lo pierde). Abre Sender
   y verifica «Cable USB · … · USB 2.0 · 480 Mbps» y 2560 × 1440 / 60 FPS / 40 Mbps.
4. Pulsa **Preparar conexión**. La iMac se conecta sola, **sin clave**. Acepta en la MacBook.
   Si no se conecta, en la iMac elige la IP manual 169.254.x.x del emisor y deja la clave vacía.
5. La iMac entra sola en pantalla completa. Pulsa **Prueba de movimiento**. Espera
   5–10 s y anota las tres líneas de métricas del emisor, incluida la de la iMac
   (FPS mostrados, hardware/software, ms de decodificación).
6. Cierra el patrón. Mueve una ventana a la iMac, escribe, selecciona texto y desplázate.
   Comprueba que el texto queda nítido unos instantes después de dejar de moverlo.
7. Si la iMac no sostiene 60 FPS (decodificación por software o FPS mostrados bajos),
   prueba 1920 × 1080 / 60 y compara. Registra CPU de ambas Macs tras 10 minutos.
8. Desconecta el cable durante la sesión: el emisor debe avisar y cerrar en ~2 s y
   la pantalla virtual debe desaparecer.

Para medir latencia física se necesita una cámara que capture ambas pantallas a la vez;
el ACK no la mide. Ante un fallo, pulsa **Exportar diagnóstico…** en las dos apps.

## Registrar resultados

Completa `docs/PRUEBAS.md` con datos reales, sin IP, claves, seriales, nombres de
usuario ni capturas de contenido personal:

| Prueba | Dato pendiente |
| --- | --- |
| Receiver v0.4.0 en Sequoia 15.8.1 | Abre, encuentra la MacBook por cable |
| Decodificación en la iMac | Hardware o software, ms y FPS mostrados a 1440p/60 |
| 1440p/60/40 Mbps por cable | Captura, entrega, ACK y sensación al escribir/mover |
| 1080p/60 por cable | Comparación si 1440p no llega a 60 |
| Wi‑Fi con v0.4.0 | Mismas métricas para comparar |
| CPU y memoria | Monitor de Actividad en ambas Macs tras 10 minutos |
| Desconectar el cable / reposo | Aviso, retirada de la pantalla y reconexión |
| Sesión de 30 minutos | Estabilidad, consumo y temperatura |

## Diagnóstico

- **macOS bloquea la app:** firma ad hoc, sin notarización. Verifica el origen y usa
  la excepción puntual de Privacidad y seguridad; no desactives Gatekeeper globalmente.
- **El cable no aparece en Sender:** usa un cable de datos, prueba otro puerto de la
  MacBook y espera unos segundos. `ifconfig en4`, `en5` o `en6` debe decir «active».
  Ejecuta `bash scripts/test-link.sh --run --require-usb` en la MacBook.
- **La iMac no encuentra la MacBook:** acepta el permiso de red local en ambas Macs,
  pulsa Preparar conexión en el emisor o usa la IP manual 169.254.x.x que muestra,
  con la clave vacía si es por cable.
- **«La clave no coincide»:** solo por Wi‑Fi. Copia la clave actual; la huella de 4
  caracteres debe ser igual en ambas Macs. El emisor sigue esperando.
- **«La MacBook cerró la conexión al recibir el saludo»:** el emisor es anterior a
  v0.4.0. Actualízalo.
- **Falla captura:** permiso de grabación de pantalla al emisor actual y reinicio de
  esa app. Si el interruptor aparece activado pero no funciona tras actualizar,
  elimina **solo iMac Sender** de la lista, vuelve a añadirlo y reabre la app.
- **Lentitud:** lee la línea de la iMac en el emisor. Decodificación por software o
  FPS mostrados bajos indican el límite de la iMac: baja a 1080p. Entrega baja con
  iMac holgada indica red o emisor: exporta el diagnóstico de ambas apps.
- **Imagen negra:** prueba primero el patrón y una ventana normal para distinguir
  un problema general de uno específico de contenido protegido.

## Continuar el código

El único puente privado está en `Sources/VirtualDisplay/` y se incluye solo en el
helper del emisor. El enlace USB usa IOKit en lectura, Network.framework y `dns_sd`.

Para editar en la iMac, verifica primero `xcode-select -p`, `xcrun swift --version`
y el SDK disponible. Usa Swift 5.9 o posterior y un SDK con macOS 13 o posterior.
Para construir solamente el receptor con la arquitectura de esa Mac:

```bash
git clone https://github.com/AlexandroHernandez27/imac-second-display.git
cd imac-second-display
bash scripts/build-receiver.sh
```

`scripts/build.sh` construye el conjunto completo en Apple Silicon y un receptor
universal. Probar la descarga no necesita herramientas de desarrollo.

Siguientes prioridades:

1. Medir v0.4.0 por cable en la iMac y corregir fallos con evidencia reproducible.
2. Si la iMac decodifica por software y no llega a 60 FPS, evaluar 1080p por defecto
   o ajustes de bitrate con esa medición; no cambiar de códec sin medir.
3. Cursor por canal independiente para que el puntero responda antes que el video.
4. Reconexión automática al volver a conectar el cable, conservando autorización explícita.
5. Audio, entrada desde receptor, Internet y varios receptores siguen fuera del alcance.

Proyecto independiente de cualquier otro repositorio: no incorporar datos,
credenciales ni configuración ajenos. Mantener documentación en español.
LanScreen se revisó como referencia GPLv3 sin incorporar código
([comparación](docs/COMPARACION_LANSCREEN.md)).
