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
- Los proveedores de los artefactos (Docker, Coollabs, Cloudflare, jq).
- Para Docker y Coolify, además, la red: su script se descarga y se ejecuta sin
  verificar salvo que lo fijes tú (ver abajo).

**Lo que no protege hoy:**

- **Integridad de las descargas: parcial, y el reparto no es uniforme.** Ver
  «Verificación de las descargas» más abajo. En resumen: `jq` se verifica
  contra el hash que publica su autor; `cloudflared` contra un hash que
  calculamos nosotros una vez —que es confianza en el primer uso, no
  verificación independiente—; y el script de Docker y el de Coolify **no se
  verifican** salvo que pases `--pin-docker` / `--pin-coolify`.
- **El token en el medio.** Con `--cf-token`, el token de Cloudflare viaja **en
  claro** dentro del `user-data` de la ISO. Quien tenga el USB lo tiene.
- **Los secretos mientras dura la instalación.** Hasta que termina con éxito,
  el token de Cloudflare está en `/etc/coolify-setup.env` y en
  `/var/lib/coolify-setup/config.env`, y el del túnel en
  `tunnel.env`, todos en modo 0600. Tienen que seguir ahí: son de donde sale el
  reintento si algo falla a mitad.
- **`/etc/coolify-setup.version`.** Se escribe en 0644 a propósito: dice qué
  versión del proyecto y de cada componente instaló el equipo, y no lleva
  ningún secreto. Cualquier usuario local puede leerlo — es información de
  inventario, no de acceso.
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

## Verificación de las descargas

Lo que se verifica, y con qué honestidad. La diferencia entre los tres casos
importa más que el hecho de que haya verificación:

| Artefacto | Qué se comprueba | De dónde sale el hash |
|---|---|---|
| `jq` | SHA-256 contra la tabla de `setup.sh` | del `sha256sum.txt` que publica la propia release de `jqlang/jq`. Es verificación contra lo que dice el autor. |
| `cloudflared` | SHA-256 contra la tabla de `setup.sh` | **calculado por nosotros** descargando el binario una vez (2026-08-24). Cloudflare **no publica hashes** de sus releases. |
| `get-docker.sh` | nada, salvo `--pin-docker=SHA256` | no existe hash por versión. |
| `install.sh` de Coolify | nada, salvo `--pin-coolify=SHA256` | no existe hash por versión. |

**Lo de `cloudflared` es confianza en el primer uso, no verificación.** El hash
de la tabla dice «esto es lo mismo que había el día que lo miramos», no «esto
es lo que Cloudflare firma». Si el binario de aquel día ya estuviera
comprometido, el hash lo perpetuaría sin que nadie se enterase. Detecta cambios
posteriores; no sustituye a una firma que Cloudflare no ofrece.

Reglas del mecanismo:

- El hash se comprueba con `sha256sum`, `shasum -a 256` u `openssl dgst
  -sha256`, en ese orden. Si **no hay ninguna**, el paso falla: no se continúa
  sin poder verificar.
- Un hash que no cuadra aborta el paso **y borra el fichero**. No queda ningún
  binario ni script sin verificar en el disco.
- La tabla vive dentro de `setup.sh` porque el script viaja solo (`curl | sh`, o
  incrustado en el `user-data`) y no tiene el repositorio al lado.
- `--pin-cloudflared=SHA256` manda sobre la tabla: sirve para instalar con
  `--cloudflared-version=X` una versión que este script no conoce, sin
  renunciar a verificar. Sin pin y sin entrada en la tabla, el paso falla.

Para fijar Docker o Coolify, calcula el hash una vez desde una máquina y una red
en las que confíes:

```bash
curl -fsSL https://get.docker.com | sha256sum
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sha256sum
```

y pásalos con `--pin-docker=` y `--pin-coolify=`. **Envejecen**: ambos scripts
cambian sin previo aviso, y cuando cambien la instalación fallará hasta que
actualices el pin. Sin pin no se bloquea nada, pero se avisa por pantalla y en
el log de que se va a ejecutar como root un script remoto sin verificar.

`--offline-dir=RUTA` coge los cuatro artefactos de un directorio local en vez de
la red, con estos nombres exactos: `get-docker.sh`, `install-coolify.sh`,
`cloudflared-linux-ARCH` y `jq-linux-ARCH`. Lo que venga de ahí **se verifica
igual**: un directorio local no es una fuente de confianza por ser local.

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
