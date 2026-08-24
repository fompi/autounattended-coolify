# Registro de cambios

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/).
Versionado [semántico](https://semver.org/lang/es/).

## [No publicado]

### Añadido
- Suite de pruebas (`tests/run.sh`) con 208 comprobaciones y un simulador de la
  API de Cloudflare.
- Integración continua: shellcheck en dialecto `sh`, sintaxis en cinco shells,
  la suite completa y comprobaciones de que no se filtran secretos.
- `LICENSE` (MIT), `SECURITY.md` con el modelo de amenaza, `CONTRIBUTING.md`,
  `Makefile` y plantillas de incidencia y de PR.

### Seguridad
- **La zona horaria se pregunta primero al sistema** ([#12]). La consulta a
  `ipapi.co` queda como último recurso, se anuncia antes de hacerse y se puede
  desactivar con `--no-geoip` o `NO_GEOIP=1`. `SECURITY.md` enumera todas las
  llamadas salientes.
- **Los secretos se borran al terminar** ([#3]). El token de Cloudflare, el del
  túnel y la configuración resuelta se borran (con `shred -u` si está) en el
  camino de éxito y solo después de marcar el completado. El resumen se parte
  en dos: uno sin credenciales y `/root/instalacion-credenciales.txt` (0600)
  con ellas. Nuevas `--keep-secrets` y `--summary-no-secrets`.
- **La cuenta de rescate `installer` se retira** ([#9]) en el último paso, tras
  verificar que el administrador real existe, manda y tiene con qué entrar. Se
  bloquea, sale de sudo y pasa a una shell de `nologin`. Nuevas
  `--keep-rescue`, `--purge-installer` e `--installer-user`. El paso nunca
  aborta la instalación y el resumen dice siempre cómo quedó la cuenta.

### Seguridad
- **Las descargas se verifican contra un SHA-256** ([#2]). `jq` contra el hash
  que publica su release; `cloudflared` contra uno calculado por nosotros —que
  es confianza en el primer uso, no verificación independiente: Cloudflare no
  publica hashes—. Un hash que no cuadra aborta el paso y borra el fichero; si
  no hay `sha256sum`, `shasum` ni `openssl`, falla en vez de continuar a
  ciegas. Docker y Coolify no tienen artefacto verificable: nuevas
  `--pin-docker` y `--pin-coolify`, y sin pin se avisa por pantalla y en el log
  de que se ejecuta un script remoto como root sin verificar. Nuevas también
  `--pin-cloudflared` y `--offline-dir`. `SECURITY.md` explica qué es
  verificación de verdad y qué no.

### Cambiado
- **Versionado real** ([#13]). `build-usb.sh` hornea `git describe --tags
  --always --dirty` en el `user-data`, y llega al destino por el
  `EnvironmentFile` de la unidad systemd (`SETUP_VERSION=`), no por un marcador
  dentro de `setup.sh`: el script incrustado tiene que seguir siendo idéntico
  byte a byte al original. Nuevo `--version` en **ambos** scripts, tabla de
  versiones en el resumen final y `/etc/coolify-setup.version` (0644, sin
  secretos). El `EnvironmentFile` se genera ahora en un solo sitio, del que
  beben tanto el bloque `write_files` como el `/cidata` de la ISO.
- **`cloudflared` se instala en una versión fija** ([#5]), no desde
  `releases/latest`: la misma ISO tiene que dar el mismo sistema. Nueva
  `--cloudflared-version=X`, que sobrevive al reintento. La URL de `jq` pasa a
  componerse con la misma constante de versión.

### Corregido
- **El registro del primer usuario de Coolify daba éxitos falsos** ([#7]). Se
  daba por bueno cualquier 200, 302 o 303, y un 200 es justo el caso del
  formulario devuelto con errores de validación pintados dentro. Ahora, tras el
  POST, se vuelve a pedir `/register`: Coolify lo cierra en cuanto existe el
  primer usuario, así que si sigue ofreciendo el formulario es que no se
  registró nadie. Distinguir el formulario de registro del de login exige
  `password_confirmation`, porque `name="_token"` lo llevan los dos. El resumen
  pasa de dos estados a cuatro —registrado, ya existía, pendiente y omitido—, y
  el estado va a `$STATE_DIR`, no a una variable en memoria: `run_step` no
  reejecuta un paso ya hecho, así que en un reintento la variable estaba vacía y
  el resumen decía «pendiente» de un usuario que sí se había registrado. Nueva
  `--skip-coolify-register`.
- **Reejecutar dejaba túneles huérfanos en Cloudflare** ([#15]). El nombre del
  túnel era `coolify-$HOSTNAME`, así que reinstalar el equipo con otro hostname
  creaba uno nuevo y abandonaba el viejo apuntando a una máquina que ya no
  existe. Ahora se deriva del FQDN del panel —que es lo que identifica el
  despliegue y sobrevive al formateo—, recortado a los 63 caracteres que
  admite Cloudflare. Los túneles con el nombre antiguo se detectan y se
  reutilizan tal cual, sin renombrarlos ni duplicarlos. El nombre se anota en
  `tunnel.env` y en el resumen para poder identificar después lo que creamos
  nosotros, y la ayuda de `--reset` deja claro que no borra nada en Cloudflare.
- **El paso `tunnel_service` daba falsos positivos** ([#6]). `systemctl
  is-active` tras un `sleep 5` no prueba nada: `cloudflared` arranca y
  reintenta en bucle aunque el token no valga. Ahora se le pregunta a
  Cloudflare por el estado del túnel hasta verlo `healthy` (o `degraded`, que
  se acepta avisando), con reintentos y un tiempo máximo configurable con
  `TUNNEL_HEALTH_TIMEOUT`. Si no conecta, el error distingue las tres causas
  —sin salida a internet, puerto 7844 bloqueado, token del túnel inválido—, que
  tienen tres soluciones distintas. Y un `cloudflared` ya activo solo se da por
  bueno si lleva el token de *este* túnel, no el de un intento anterior.
- `do_cloudflared_bin` no tenía guarda de sistema operativo: en macOS componía
  `cloudflared-darwin-amd64`, que no existe como asset, y moría con un 404
  opaco. Ahora lo dice y apunta a `brew install cloudflared`.
- El bloque `late-commands` usaba `install -D`, que es una extensión de GNU.
  Ahora `mkdir -p` + `cp` + `chmod`, para poder ejecutarlo y comprobarlo en
  cualquier POSIX.

## [0.2.0] — 2026-08-21

### Corregido
- **El asistente de primer arranque no se ejecutaba** ([#1]). Tres defectos:
  dependía de que el cloud-init del destino re-ejecutase módulos
  *per-instance*; el netplan hacía match con `en*` y dejaba sin red a las
  máquinas cuya interfaz es `eth0`; y la unidad llevaba `Before=` de las getty,
  con lo que un asistente colgado dejaba el equipo sin login.

### Añadido
- `--rescue-password` en `build-usb.sh`.
- Reempaquetado de la ISO con `--iso`: mete el `cidata` dentro y añade
  `autoinstall` al arranque, para que el USB sea un único `dd`.

## [0.1.0] — 2026-08-20

### Añadido
- `setup.sh`: instalador portable en POSIX sh de Docker, Coolify y el túnel.
- Plantilla de autoinstall y `build-usb.sh`.

[#1]: https://github.com/fompi/autounattended-coolify/issues/1
[#2]: https://github.com/fompi/autounattended-coolify/issues/2
[#3]: https://github.com/fompi/autounattended-coolify/issues/3
[#5]: https://github.com/fompi/autounattended-coolify/issues/5
[#6]: https://github.com/fompi/autounattended-coolify/issues/6
[#7]: https://github.com/fompi/autounattended-coolify/issues/7
[#9]: https://github.com/fompi/autounattended-coolify/issues/9
[#12]: https://github.com/fompi/autounattended-coolify/issues/12
[#15]: https://github.com/fompi/autounattended-coolify/issues/15
[#1]: https://github.com/fompi/culificador/issues/1
[#2]: https://github.com/fompi/culificador/issues/2
[#3]: https://github.com/fompi/culificador/issues/3
[#5]: https://github.com/fompi/culificador/issues/5
[#9]: https://github.com/fompi/culificador/issues/9
[#12]: https://github.com/fompi/culificador/issues/12
[#13]: https://github.com/fompi/culificador/issues/13
