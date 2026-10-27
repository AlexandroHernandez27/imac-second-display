# Actualizaciones con confirmación

## Comportamiento para el usuario

Desde v0.3.0, Sender y Receiver incluyen Sparkle 2.10.1. Cada app consulta su propio
feed firmado y ofrece solo el ZIP de su rol. La versión anterior requiere una
instalación manual para incorporar esta función.

- Búsqueda automática inicialmente activada, intervalo de 24 horas mientras la
  app esté abierta. La casilla de cada app guarda la preferencia local de Sparkle.
- Botón y menú **Buscar actualizaciones…** para comprobar manualmente.
- Las notas describen los cambios. El usuario decide descargar/instalar, posponer
  u omitir la versión. `SUAllowsAutomaticUpdates = false` impide descargas e
  instalaciones automáticas incluso si hubiera preferencias anteriores.
- El emisor considera ocupada la sesión desde Preparar conexión, incluido el
  emparejamiento. El receptor desde Conectar. El delegado impide búsquedas durante
  ese periodo y no permite nuevas conexiones mientras Sparkle está actualizando.
  Un relanzamiento pendiente espera a la desconexión si fuese necesario.
- Sparkle sustituye la app y la relanza. No reinstala la otra Mac ni conserva la
  sesión de video; se conecta de nuevo con una clave nueva.

Una carpeta local escribible, como `~/Applications`, evita normalmente la necesidad
de permisos de administrador para sustituir archivos. En una ubicación protegida,
Sparkle puede solicitar autorización del sistema. No ejecutar desde un ZIP o volumen
de solo lectura. Las apps siguen sin notarización de Apple: la firma de actualización
no sustituye Developer ID ni los permisos de grabación de pantalla.

## Integridad y privacidad

- Sparkle se descarga de su release oficial, versión fija y SHA-256 verificado
  antes de extraer. Se comprueba su firma y se conservan enlaces/permisos al empaquetar.
- `SUPublicEDKey` fija la clave pública. Los ZIPs se verifican antes de extraer
  (`SUVerifyUpdateBeforeExtraction = true`). Los feeds y sus notas embebidas también
  requieren firma (`SURequireSignedFeed = true`), sin caducidad que admita feeds
  no firmados (`SUSignedFeedFailureExpirationInterval = 0`).
- La clave privada está únicamente en el Llavero de la Mac de publicación, cuenta
  `imac-second-display-updates`. Ni el repositorio ni las apps contienen esa clave.
  Las apps consumidoras no necesitan acceso al Llavero del desarrollador.
- La búsqueda y descarga usan GitHub. Como cualquier servidor HTTP, GitHub recibe
  IP de conexión y cabeceras; Sparkle incluye nombre/versión de la app en User-Agent.
  El perfil del sistema está desactivado. No se envían pantalla, clave de emparejamiento
  ni información de las ventanas. El flujo de video sigue exclusivamente en la LAN.
- Los feeds ofrecen las versiones experimentales que el mantenedor publique
  explícitamente. No se instala cualquier commit o release encontrada por una API.

## Preparar y publicar una versión

1. Incrementar `version` y el entero `build` de `Config/release.json`. El build debe
   aumentar en cada publicación. No cambiar la clave pública en una actualización
   ordinaria. Añadir `docs/releases/vX.Y.Z.html` con notas en español.
2. Compilar, validar y empaquetar:

   ```bash
   bash scripts/build.sh
   bash scripts/package.sh
   python3 scripts/make-appcasts.py
   ```

   `make-appcasts.py` comprueba que la clave del Llavero coincide con la pública,
   firma los dos ZIPs y genera/verifica `updates/sender.xml` y `updates/receiver.xml`.
   Puede solicitar acceso al Llavero. No exporta claves. No modificar ZIPs ni feeds
   después de firmar; cualquier cambio requiere empaquetar y firmar otra vez.
3. Publicar primero el código de la versión y los ZIPs finales en la release
   `vX.Y.Z`, con los nombres habituales y sumas SHA-256. Comprobar que ambos assets
   están disponibles y coinciden con los archivos firmados.
4. Publicar entonces los nuevos feeds en `main/updates/`. Esta es la acción que
   anuncia la versión a las apps existentes. Evita anunciar un ZIP que todavía no
   existe. GitHub puede tardar en propagar el contenido de las URLs raw.
5. Confirmar los feeds públicos, sus firmas y una búsqueda manual desde la versión
   anterior en una copia de prueba. No usar las apps de trabajo como primer ensayo.

En una nueva Mac de desarrollo se puede compilar sin la clave privada. Firmar una
release exige recuperar de forma segura el Llavero o una copia privada de la clave.
No generar otra clave y sustituir la pública sin planificar la migración. Si se pierde
la clave y no hay una vía válida de rotación, los usuarios necesitarán una instalación
manual de la nueva base de confianza.

## Prueba aislada de instalación

```bash
python3 scripts/prepare-update-test.py
```

Genera una carpeta `.build/update-smoke-…`, dos versiones de una app de prueba,
un identificador único y una clave efímera independiente. Verifica la firma del ZIP
con CryptoKit y comprueba rechazo al alterar un byte o usar otra clave. La carpeta
`server/` solo contiene feed y ZIP; la clave de prueba está fuera de ella y no se publica.

Sirve **solo** `server/` en loopback:

```bash
python3 -m http.server 18777 --bind 127.0.0.1 --directory RUTA_DE_LA_FIXTURE/server
```

Abre `installed/iMac Update Test.app`. Comprueba el bloqueo con «Simular sesión»,
desactiva esa simulación y busca actualizaciones. Ensaya posponer y, en otra búsqueda,
confirmar la instalación. Debe reiniciarse de 0.0.1 a 0.0.2. Verifica la versión en
la interfaz y en el Info.plist instalado. Cierra la app de prueba y el servidor.
Esta prueba no captura el escritorio ni reemplaza Sender o Receiver.

Los feeds HTTP de loopback son exclusivos de esa fixture. Las apps distribuidas
apuntan a HTTPS y no incluyen la excepción de red local de la app de prueba.

## Referencias

- [Sparkle: instalación y firmas](https://sparkle-project.org/documentation/).
- [Configuración de comprobaciones, consentimiento y feeds firmados](https://sparkle-project.org/documentation/customization/).
- [Publicar actualizaciones](https://sparkle-project.org/documentation/publishing/).
- [Delegado de actualización](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html).
