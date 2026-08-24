# Política de seguridad

## Reportar una vulnerabilidad

Usa los [avisos de seguridad privados][adv] de GitHub. No abras una incidencia
pública para algo explotable.

[adv]: https://github.com/fompi/autounattended-coolify/security/advisories/new

Respuesta orientativa: acuse en 72 h, valoración en una semana.

## Modelo de amenaza

Este proyecto construye medios de instalación y ejecuta scripts con privilegios
de root. Conviene tener claro qué protege y qué no.

**Lo que asume de confianza:**

- La máquina donde corres `build-usb.sh`.
- El USB físico entre que lo grabas y arrancas el mini PC.
- La red desde la que se descargan Docker, Coolify, cloudflared y `jq`.
- Los proveedores de esos artefactos (Docker, Coollabs, Cloudflare, jq).

**Lo que no protege hoy:**

- **Integridad de las descargas.** Ninguna descarga se verifica contra un hash
  o una firma. Un compromiso de esos orígenes, o un intermediario capaz de
  romper TLS, ejecuta código como root. Seguimiento en las incidencias.
- **El token en el medio.** Con `--cf-token`, el token de Cloudflare viaja **en
  claro** dentro del `user-data` de la ISO. Quien tenga el USB lo tiene.
- **Los secretos mientras dura la instalación.** Hasta que termina con éxito,
  el token de Cloudflare está en `/etc/coolify-setup.env` y en
  `/var/lib/coolify-setup/config.env`, y el del túnel en
  `tunnel.env`, todos en modo 0600. Tienen que seguir ahí: son de donde sale el
  reintento si algo falla a mitad.
- **Credenciales tras la instalación.** Las contraseñas generadas quedan en
  claro en `/root/instalacion-credenciales.txt` (modo 0600, propiedad de root)
  y sin caducidad. Es un compromiso deliberado: sin ellas el equipo queda
  inaccesible. Guárdalas en un gestor de contraseñas y borra el fichero.
- **Borrado seguro.** Los secretos se borran con `shred -u` cuando está
  disponible, pero sobre SSD, COW o sistemas con journal eso **no garantiza**
  que el contenido desaparezca del medio físico.
- **La cuenta de rescate mientras la instalación no termine.** Con
  `--rescue-password`, hasta que el último paso la retira hay una cuenta `sudo`
  con una contraseña que comparten todos los equipos hechos con ese USB. Ver
  «La cuenta de rescate» más abajo.

## Qué pasa con los secretos al terminar

Al completar con éxito, y en este orden exacto:

1. Se escribe `/root/instalacion-resumen.txt` **sin** credenciales y
   `/root/instalacion-credenciales.txt` **con** ellas (0600).
2. Se marca la instalación como completada.
3. Se borran `config.env`, `tunnel.env` y `/etc/coolify-setup.env`.

El orden importa: si se borrasen los secretos antes de marcar el completado y
algo fallase en medio, el servicio de primer arranque volvería a ejecutarse y
pediría el token en bucle. Si la instalación **falla** a mitad, no se borra
nada: el reintento los necesita.

`--keep-secrets` conserva los tres ficheros y lo dice en el resumen.
`--summary-no-secrets` no imprime ninguna contraseña por pantalla (útil con la
consola a la vista o grabándose); las credenciales van solo al fichero.

**Rotar el token de Cloudflare después ya no hace falta**: una vez creado el
túnel y los CNAME, el equipo no vuelve a usarlo. Rótalo igualmente si el USB o
la ISO salieron de tu control.

## Llamadas salientes

Todo lo que `setup.sh` habla con el exterior, y cuándo. No hay ninguna otra.

| Destino | Cuándo | Qué revela |
|---|---|---|
| `api.cloudflare.com` | siempre (salvo `--skip-tunnel`, que aún así verifica el token) | el token, el dominio y la IP pública |
| `cloudflare.com/cdn-cgi/trace` | solo si no se detecta ruta por defecto con las herramientas del sistema | la IP pública |
| `ipapi.co/timezone` | **condicional**: solo si el sistema no tiene zona horaria propia (está en UTC), no se pasó `--timezone` y no se pasó `--no-geoip`/`NO_GEOIP=1` | la IP pública y el momento de la instalación |
| `get.docker.com` | salvo `--skip-docker`, y solo si Docker no está ya instalado | la IP pública |
| `cdn.coollabs.io/coolify/install.sh` | salvo `--skip-coolify`, y solo si `/data/coolify` no existe | la IP pública |
| `github.com/cloudflare/cloudflared/releases/...` | salvo `--skip-tunnel`, y solo si `cloudflared` no está ya instalado | la IP pública |
| `github.com/jqlang/jq/releases/...` | solo si no hay `jq` **ni** Python en el sistema | la IP pública |
| `http://localhost:8000` | salvo `--skip-coolify` | nada: es local |

La llamada a `ipapi.co` se anuncia por pantalla antes de hacerse. Es la única
que existe solo para adivinar un dato y la única que se puede desactivar sin
perder funcionalidad: sin ella el equipo se queda en UTC, que en un servidor es
una elección perfectamente defendible.

Ninguna descarga se verifica contra un hash o una firma (ver más arriba).

## La cuenta de rescate

El autoinstall crea una cuenta `installer` en el grupo `sudo`. Nace bloqueada
(`!`), pero con `--rescue-password` nace con una **contraseña real y
permanente**, y con SSH por contraseña admitido y un nombre adivinable: un
usuario por defecto con contraseña por defecto, que es exactamente lo que
buscan los escáneres. Peor aún, la contraseña se elige al construir el USB, así
que **todos los equipos instalados con ese mismo USB comparten la misma
contraseña de root efectiva**.

El último paso de `setup.sh` la retira, y solo después de comprobar que el
administrador real existe, está en `sudo`/`wheel`/`admin` y tiene una
credencial utilizable (hash de verdad en `/etc/shadow` o `authorized_keys` no
vacío). Por defecto la bloquea, la saca de sudo y le pone una shell de
`nologin` — lo de la shell no es adorno: `usermod -L` tacha el hash pero **no**
impide entrar con clave SSH.

Ese paso nunca aborta la instalación: si no puede retirarla, avisa y lo deja
escrito en el resumen, que indica siempre en qué estado quedó la cuenta.
Abortar dejaría al usuario sin el fichero de credenciales generadas, que es
peor. Y si el asistente **falla a mitad**, la cuenta sigue viva a propósito:
es la vía de rescate. En ese caso, retírala a mano cuando recuperes el acceso:

```bash
usermod -L installer && usermod -s /usr/sbin/nologin installer
gpasswd -d installer sudo
```

`--purge-installer` la borra con su home, `--keep-rescue` la conserva.

## Manejo de secretos

- Prefiere `--cf-token=@fichero` o la variable `CF_API_TOKEN`. Un
  `--cf-token=valor` literal es visible en `ps` para cualquier usuario.
- El token solo necesita `Zone:DNS:Edit` y `Zone:Zone:Read` **sobre la zona que
  vayas a usar**. No uses un token global.
- Borra el USB cuando termines si horneaste el token.
- Rota el token si el USB o la ISO salen de tu control.

## Alcance

Entra en alcance el código de este repositorio. No entran Coolify, Docker,
cloudflared ni la API de Cloudflare: repórtalo a quien corresponda.
