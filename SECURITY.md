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
- **El token en el disco.** Tras la instalación queda en
  `/etc/coolify-setup.env` (modo 0600) y no se borra.
- **Credenciales en el resumen.** `/root/instalacion-resumen.txt` guarda en
  claro las contraseñas generadas, con modo 0600 y sin caducidad.

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
