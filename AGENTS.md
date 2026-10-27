# Contexto del proyecto — iMac como segunda pantalla

## Objetivo

Desarrollar una solución propia para usar una iMac de 27 pulgadas Late 2013 como segunda pantalla de una MacBook Pro con chip M5.

- Prioridad: conexión por red local, preferiblemente Wi-Fi.
- Alternativa posterior: conexión por cable, empezando por Ethernet si resulta viable.
- El escritorio debe poder extenderse: mover ventanas de la MacBook a la iMac y trabajar con contenido diferente en cada pantalla.
- La motivación es reutilizar el equipo existente sin depender de una suscripción a Duet Display ni de un accesorio comercial como Luna Display.

## Equipos y restricciones conocidas

- Emisor inspeccionado: MacBook Pro M5, 16 GB; macOS 27.2 según `sw_vers`.
- Receptor: iMac 27 pulgadas Late 2013; usuario reporta Sequoia 15.8.1. Falta verificar memoria y estado general en ese equipo.
- El modo de pantalla de destino de Apple no permite esta combinación con la MacBook M5. Un adaptador de video no resuelve por sí solo esa limitación.
- No asumir que la iMac ejecuta un macOS reciente. Priorizar compatibilidad con el sistema que ya tenga instalado; no requerir parches ni reinstalaciones sin evaluar alternativas.
- La iMac debe estar encendida y ejecutar el receptor durante el uso.

## Arquitectura implementada

1. La MacBook crea una pantalla virtual que macOS reconoce como pantalla adicional.
2. El emisor captura únicamente esa pantalla, codifica los fotogramas y los transmite por la red local.
3. La iMac recibe y decodifica el video, y lo presenta a pantalla completa.
4. El teclado y el mouse conectados a la MacBook siguen controlando el escritorio extendido.

La pantalla independiente y el flujo completo se probaron localmente en M5.
El usuario reportó recepción en la iMac con retraso; falta medir allí v0.2.0.

## Principal incertidumbre técnica

El primer hito es demostrar una pantalla virtual independiente en la MacBook M5. Capturar o duplicar una pantalla existente no satisface el objetivo final.

- Investigar APIs disponibles, permisos y compatibilidad con el macOS del emisor.
- Revisar implementaciones abiertas antes de construir toda la infraestructura.
- Si se considera `CGVirtualDisplay` u otra API privada, documentar expresamente esa dependencia, su licencia cuando corresponda y su riesgo de compatibilidad.
- No prometer distribución por App Store ni funcionamiento entre versiones de macOS hasta verificar estas restricciones.

## Tecnologías candidatas

- Emisor nativo en Swift.
- Evaluar ScreenCaptureKit para captura y VideoToolbox/H.264 para codificación, comprobando requisitos de versión y hardware.
- Receptor: comparar una aplicación nativa para Intel con una página web local; elegir después de comprobar el macOS y navegador de la iMac.
- Transporte: evaluar WebRTC u otra opción de baja latencia en LAN. No dar por resuelta su compatibilidad con navegadores antiguos.
- Empezar con conexión por dirección IP; añadir descubrimiento automático con Bonjour después.
- Ethernet debe reutilizar el transporte de red. USB o Thunderbolt directo quedan para una investigación posterior.

## Datos necesarios para empezar

- Versión exacta de macOS de ambas Macs, desde Apple → Acerca de esta Mac.
- Confirmar qué equipo se utilizará para desarrollar y si dispone de Xcode o Command Line Tools.
- Confirmar acceso físico a la iMac para instalar y probar el receptor.
- Tipo de conexión disponible: Wi-Fi, Ethernet y adaptadores existentes.
- Uso principal: código, documentos, navegación u otro; resolución y fluidez esperadas.

Estos datos se deben obtener del usuario o del equipo correspondiente. No inferir las características de la iMac inspeccionando solamente la MacBook.

## Primeros pasos

1. Confirmar sistemas operativos y herramientas de desarrollo.
2. Investigar y probar la creación de la pantalla virtual en la MacBook.
3. Mostrar un patrón o una ventana en esa pantalla para comprobar que es independiente.
4. Construir el flujo mínimo de captura, transmisión y recepción dentro de la LAN.
5. Medir legibilidad, latencia, estabilidad, CPU y consumo de memoria; ajustar resolución y FPS con esos resultados.
6. Probar desconexión, reconexión, reposo y recuperación de errores.

Una prueba de duplicación puede servir para validar el transporte, pero no reemplaza la prueba de escritorio extendido.

## Alcance del primer prototipo

- Una MacBook y una iMac dentro de la misma red local.
- Una pantalla adicional, con resolución y FPS configurables.
- Conexión manual, receptor a pantalla completa y estados de conexión/error visibles.
- Emparejamiento explícito antes de transmitir el escritorio, con clave temporal y TLS-PSK.
- Sin audio, acceso por Internet, control remoto desde la iMac ni varios receptores en la primera versión.
- Sin abrir puertos del router ni transmitir el escritorio a servicios externos.

## Forma de trabajar

- Este repositorio es independiente de cualquier otro proyecto. No copiar código, datos, credenciales ni configuración ajenos.
- El usuario autorizó crear un repositorio público en GitHub y publicar aplicaciones descargables. No incluir logs locales, claves, IP privadas ni identificadores personales del hardware.
- No incluir secretos ni información personal en commits.
- Mantener documentación en español y registrar decisiones y limitaciones verificadas.
- No afirmar que funciona en la combinación de equipos hasta probarla en ambos.

## Estado actual

Existe un prototipo nativo de emisor y receptor. Se comprobó la pantalla independiente,
captura y reproducción cifrada con ambas apps en M5. El usuario reportó en v0.1.0
2.9 FPS, 0.6 Mbps y ACK de 7 ms, con retraso al mover ventanas y escribir.
v0.2.0 conserva el último cambio, usa ventana acotada de tres, métricas recientes
y actividad durante la sesión. Sus benchmarks son sintéticos locales; no afirmar
que resolvieron el retraso de la iMac hasta medirlo allí.
Leer `CONTINUAR_EN_IMAC.md`, `docs/PRUEBAS.md`, `docs/ARQUITECTURA.md` y
`docs/COMPARACION_LANSCREEN.md` antes de continuar. LanScreen se revisó como
referencia GPLv3; no se incorporó su código.
