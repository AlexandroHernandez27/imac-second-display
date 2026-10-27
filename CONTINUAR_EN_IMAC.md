# Continuar el desarrollo y las pruebas en la iMac

## Objetivo y equipos

Usar una iMac 27 pulgadas Late 2013 como pantalla extendida de una MacBook Pro M5
por Wi‑Fi. Las aplicaciones corren en la MacBook; la iMac solo reproduce video.

- MacBook inspeccionada: M5, 16 GB; `sw_vers` reporta macOS 27.2 / build 26B123.
- Herramientas de la MacBook: Command Line Tools y Swift 6.2.1, sin Xcode completo.
- iMac: modelo y Sequoia 15.8.1 reportados por el usuario. RAM, GPU, red y rendimiento
  todavía no inspeccionados en ese equipo. No inferirlos desde la MacBook.
- Acceso a ambas Macs confirmado; uso deseado: ventanas de cualquier aplicación.
- No cambiar macOS ni instalar parches para esta prueba. No se necesita Apple ID.

## Implementación disponible

`iMac Sender.app` crea la pantalla, captura solo ese ID, codifica H.264 por hardware
y transmite por TLS. `iMac Receiver.app`, universal Intel/ARM, reproduce con
AVFoundation y ofrece pantalla completa. Hay IP manual, clave temporal, aceptación
explícita, resolución/FPS/bitrate configurables, patrón de texto y cierre de sesión.

La pantalla vive en un proceso auxiliar: liberar `CGVirtualDisplay` dentro del
proceso no la retiraba inmediatamente en esta versión. Salir del proceso sí la
retiró y restauró la lista de pantallas. Un pipe vigila que el emisor siga vivo.

## Evidencia y límites de validación

Comprobado en la MacBook:

- Compilación de emisor ARM64 y receptor universal ARM64/x86_64; firmas locales verificadas.
- De una a dos pantallas: nuevo ID 1920 × 1080, sin duplicación ni superposición,
  con una ventana propia en la virtual. Al salir vuelve la lista original.
- Patrón sintético → H.264 por hardware → paquete → decodificación: tamaño y color correctos.
- TLS-PSK en loopback: paquete íntegro y ACK. Clave incorrecta rechazada sin video.
- Rechazo de mensajes truncados y tamaños inválidos.

Consultar [docs/PRUEBAS.md](docs/PRUEBAS.md) para el resultado actualizado de la captura
real con ambas interfaces en la MacBook. **Nada de esto certifica todavía la iMac**,
la decodificación por hardware en Intel, la latencia entre equipos ni sesiones largas.

## Primera prueba en la iMac

1. Descarga `iMac-Receiver-universal.zip` desde la release. Descomprime y coloca la
   app en una carpeta local, por ejemplo Aplicaciones del usuario. No necesitas Xcode.
2. Abre el emisor en la MacBook. Conecta ambas al mismo Wi‑Fi, sin aislamiento de
   dispositivos de una red de invitados. No abras puertos del router.
3. Usa **1920 × 1080 / 30 FPS / 12 Mbps**, pulsa Preparar conexión e introduce en
   la iMac la IP y clave completas. La clave es sensible: no publicarla en issues,
   capturas, chats públicos ni commits.
4. Conecta desde el receptor y acepta en la MacBook. El permiso de grabación de
   pantalla se concede al emisor en la MacBook; reinicia esa app si macOS lo pide.
   Autoriza las apps en avisos de red local/firewall de tu LAN.
5. Activa Pantalla completa en la iMac y pulsa Mostrar patrón de prueba en la MacBook.
6. Comprueba que el patrón está en la pantalla adicional, que la principal conserva
   su contenido y que puedes mover una ventana entre ambas.
7. Prueba escribir, seleccionar texto, desplazarte y mover ventanas. Después prueba
   video sin audio. Un contenido protegido puede aparecer negro.
8. Repite a **2560 × 1440 / 30 FPS / 20 Mbps** para evaluar legibilidad en el panel
   de 27 pulgadas. Prueba 60 FPS después de conseguir una sesión estable.

Controla las ventanas con teclado y mouse de la MacBook. El mouse de la iMac solo
controla la interfaz del receptor. Esc permite salir del modo de pantalla completa.

## Registrar resultados

Completa `docs/PRUEBAS.md` con datos reales, sin IP, claves, seriales, nombres de
usuario ni capturas de contenido personal:

| Prueba | Dato pendiente |
| --- | --- |
| Abrir receptor Intel en Sequoia 15.8.1 | Resultado/error exacto |
| Emparejamiento y pantalla extendida | Ventanas independientes y texto legible |
| 1080p/30, 1440p/30 y 1440p/60 | FPS entregados y fluidez observada |
| CPU y memoria | Monitor de Actividad en ambas Macs tras 10 minutos |
| Latencia de interacción | Método y medición documentados |
| Desconexión normal | Monitor virtual desaparece; ventanas recuperables |
| Cortar Wi‑Fi y recuperar | Error visible; reconexión con clave nueva |
| Reposo/despertar de cada Mac | Reconexión sin reiniciar equipo |
| Clave incorrecta/segundo receptor | No recibe escritorio |
| Sesión de 30 minutos | Estabilidad, consumo y temperatura |

**ACK ms no es latencia de movimiento a fotón**: mide hasta recepción/encolado,
no presentación en el panel. Los FPS indican fotogramas entregados; un escritorio
estático puede generar pocos fotogramas.

## Diagnóstico

- **macOS bloquea la app:** firma ad hoc, sin notarización. Verifica el origen y usa
  la excepción puntual de Privacidad y seguridad; no desactives Gatekeeper globalmente.
- **No conecta:** revisa LAN, IP actual, TCP 7777, clave y permisos. Una VPN o una
  red de invitados puede bloquear tráfico local. Prepara una sesión con nueva clave.
- **Falla captura:** permiso al emisor en la MacBook, seguido de cerrar y reabrir.
  Recompilar con firma ad hoc puede hacer que macOS solicite reconocer la app otra vez.
  Si el interruptor aparece activado pero la app sigue sin permiso después de una
  recompilación: cierra el emisor, elimina **solo iMac Sender** de la lista de
  Grabación de pantalla, vuelve a añadir el paquete actual con el botón `+`,
  autoriza con Touch ID si se solicita y reabre el emisor. No borrar permisos de
  otras aplicaciones. Para desarrollo continuo, evaluar una identidad de firma estable.
- **Ventanas fuera del área visible:** desconecta o sal del emisor. El helper debe
  terminar y macOS retirar el monitor virtual.
- **Imagen negra:** prueba primero el patrón y una ventana normal para distinguir
  un problema general de uno específico de contenido protegido.
- **Lentitud:** compara 720p/30 y 1080p/15; reduce bitrate. Prueba Ethernet si ya
  hay adaptadores. No comprar accesorios antes de medir.

## Continuar el código

El único puente privado está en `Sources/VirtualDisplay/` y se incluye solo en el
helper del emisor. El receptor usa APIs públicas y no crea pantallas virtuales.

Para editar en la iMac, verifica primero `xcode-select -p`, `xcrun swift --version`
y el SDK disponible. Usa Swift 5.9 o posterior y un SDK con macOS 13 o posterior.
Para construir solamente el receptor con la arquitectura de esa Mac:

```bash
git clone https://github.com/AlexandroHernandez27/imac-second-display.git
cd imac-second-display
bash scripts/build-receiver.sh
```

Ese script está preparado para Intel/ARM, pero su ejecución en la iMac sigue
pendiente de prueba. `scripts/build.sh` construye el conjunto completo en Apple
Silicon y un receptor universal. También puedes editar en la iMac y compilar
releases en la MacBook. Probar la descarga no necesita herramientas de desarrollo.

Siguientes prioridades:

1. Corregir fallos observados en la iMac con evidencia reproducible.
2. Medir aceleración de decodificación, latencia, memoria y consumo.
3. Si el ACK por fotograma limita los FPS, evaluar una ventana acotada de varios
   fotogramas o UDP/WebRTC, conservando cifrado, autorización y recuperación de H.264.
4. Mejorar cambios de red/reposo, descubrimiento Bonjour e interfaz.
5. Audio, entrada desde receptor, Internet y varios receptores siguen fuera del alcance.

Proyecto independiente de cualquier otro repositorio: no incorporar datos,
credenciales ni configuración ajenos. Mantener documentación en español.
