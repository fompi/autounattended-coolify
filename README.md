# USB de instalación desatendida — Ubuntu Server + Docker + Coolify + Cloudflare Tunnel

[![CI](https://github.com/fompi/culificador/actions/workflows/ci.yml/badge.svg)](https://github.com/fompi/culificador/actions/workflows/ci.yml)
[![Licencia: MIT](https://img.shields.io/badge/licencia-MIT-blue.svg)](LICENSE)
[![POSIX sh](https://img.shields.io/badge/shell-POSIX%20sh-89e051.svg)](CONTRIBUTING.md)
[![Ubuntu 24.04 LTS](https://img.shields.io/badge/Ubuntu-24.04%20LTS-E95420.svg?logo=ubuntu&logoColor=white)](https://ubuntu.com/download/server)

Arrancas el mini PC desde el USB y, sin tocar nada, acabas con Ubuntu Server
instalado, Docker y Coolify corriendo, y un túnel de Cloudflare enrutando
`*.app.tudominio.tld` y `coolify.tudominio.tld` hacia el equipo.

El principio de diseño es **no preguntar nada que se pueda averiguar**. Todo lo
derivable se deriva, todo lo generable se genera, y lo que quede se acepta por
línea de comandos. En la práctica solo hay un dato irreducible: el **API Token
de Cloudflare**.

## Estado

| Fase | Estado |
|---|---|
| Construir la ISO desatendida | Funciona. Verificado. |
| Instalación de Ubuntu sin intervención | Funciona. Verificado en VM. |
| Arranque del asistente en el primer boot | Funciona. Verificado en VM. |
| Hostname, zona horaria, usuario, SSH, Docker | Funciona. Verificado en VM. |
| Coolify y registro de su primer usuario | Funciona. Verificado en VM. |
| Túnel, reglas de enrutado y registros DNS | Funciona contra una API de Cloudflare **simulada**, no contra la real. |
| Arranque del servicio `cloudflared` | Sin verificar: necesita un túnel real de Cloudflare. |

Lo único que no se ha ejercitado contra servicios reales es la parte final:
las llamadas a Cloudflare se probaron contra un simulador que imita sus
respuestas, y el registro del primer usuario de Coolify depende del HTML de su
formulario. Ver [Qué está verificado y qué no](#qué-está-verificado-y-qué-no).

## Qué se pregunta y qué no

| Dato | De dónde sale |
|---|---|
| **Cloudflare API Token** | **Único dato que hay que dar.** Por `--cf-token`, por `CF_API_TOKEN`, o preguntado por pantalla. |
| Dominio raíz | `GET /zones` con ese token. Si el token cubre **una** zona se usa sin preguntar; si cubre varias, se elige de un menú (o `--domain`). |
| Subdominio de apps | `app` por defecto (`--app-subdomain`). |
| Subdominio del panel | `coolify` por defecto (`--coolify-subdomain`). |
| Hostname | Primera etiqueta del hostname actual si no es genérico; si lo es, primera etiqueta del dominio. |
| Usuario administrador | `SUDO_USER`, o el primer usuario con uid ≥ 1000, o se crea `admin`. |
| Contraseña del admin | Generada (24 caracteres). Aparece en `/root/instalacion-credenciales.txt`. |
| Clave SSH | Se respeta la que ya haya en `authorized_keys`; si se pasa `--ssh-key`, se desactiva el acceso por contraseña. |
| Zona horaria | La del sistema; si el sistema está en UTC, geolocalización de la IP pública (evitable con `--no-geoip`); si falla, UTC. |
| Email del admin de Coolify | Extraído del nombre de la cuenta de Cloudflare; si no, `admin@<dominio>`. |
| Contraseña de Coolify | Generada. Aparece en `/root/instalacion-credenciales.txt`. |
| Tunnel ID, rutas DNS, tokens internos | Creados vía API. |
| WiFi | **Solo se pregunta si no hay red al arrancar.** Con Ethernet ni se menciona. |

## Requisitos previos

1. El dominio dado de alta como zona en Cloudflare, con los nameservers apuntando allí.
2. Un API Token con `Zone → DNS → Edit` y `Zone → Zone → Read` sobre esa zona.
   Se crea en <https://dash.cloudflare.com/profile/api-tokens>.
3. La ISO de Ubuntu Server LTS: <https://ubuntu.com/download/server>.
4. Ethernet conectado (recomendado). Si no, tendrás que teclear SSID y contraseña.

No hace falta generar hashes de contraseña ni preparar nada más: la cuenta que
usa el instalador nace bloqueada y el usuario real lo crea el propio script.

## Ficheros

| Fichero | Qué hace |
|---|---|
| `setup.sh` | Todo el trabajo. POSIX sh, autónomo, sirve también fuera del USB. |
| `cloud-init/user-data.tpl` | Plantilla de autoinstall de Ubuntu. |
| `cloud-init/coolify-setup.service` | Unidad systemd del asistente. Fuente única, usada por los dos caminos de instalación. |
| `build-usb.sh` | Incrusta `setup.sh` en la plantilla y genera `cloud-init/user-data`. |
| `cloud-init/user-data`, `meta-data` | Generados por `build-usb.sh`. No se versionan: pueden llevar el token dentro. |
| `tests/run.sh` | Suite de pruebas. `make test`. |
| `tests/cf-mock.py` | Simulador de la API de Cloudflare que usan las pruebas. |
| `Makefile` | Atajos: `make test`, `make lint`, `make iso ISO=...`. |

## Uso

### 1. Construir la ISO

El camino recomendado reempaqueta la ISO de Ubuntu: mete dentro la
configuración y añade `autoinstall` a los parámetros de arranque. El resultado
se graba con un solo `dd` y no pregunta nada.

```bash
./build-usb.sh --iso=ubuntu-24.04.4-live-server-amd64.iso --cf-token=@/ruta/tu-token.txt
```

Sin `--cf-token`, el token se pide por pantalla en el primer arranque y no queda
ningún secreto en el USB:

```bash
./build-usb.sh --iso=ubuntu-24.04.4-live-server-amd64.iso
```

Para entrar por SSH con tu clave, `--ssh-key` (se instala como fichero aparte,
porque las claves llevan espacios y los argumentos se dividen por espacios):

```bash
./build-usb.sh --iso=ubuntu.iso --cf-token=@tok --ssh-key=@~/.ssh/id_ed25519.pub
```

Cualquier otra opción de `setup.sh` se puede fijar de antemano tras `--`:

```bash
./build-usb.sh --iso=ubuntu.iso --cf-token=@tok -- --domain=fompi.net --app-subdomain=svc
```

Necesita `xorriso` (`apt install xorriso` o `brew install xorriso`).
`build-usb.sh` valida el YAML, comprueba que el `setup.sh` incrustado coincide
byte a byte con el original, y verifica que la ISO resultante lleva los
parámetros de arranque y el `/cidata` dentro.

> Con el token horneado, la ISO **contiene un secreto**. No la subas a ningún
> sitio y borra el USB al terminar.

### 2. Grabar el USB

```bash
sudo dd if=ubuntu-autoinstall.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

En macOS: `diskutil unmountDisk /dev/diskN && sudo dd if=ubuntu-autoinstall.iso of=/dev/rdiskN bs=4m`.
En Windows: Rufus en modo «DD Image».

Vale para BIOS y UEFI: el reempaquetado conserva el arranque híbrido original de
la ISO, y `storage.layout: lvm` crea la ESP o la partición `bios_grub` según cómo
haya arrancado el equipo.

<details>
<summary>Alternativa manual (partición CIDATA) — <b>no queda desatendida</b></summary>

Sin `--iso`, `build-usb.sh` solo genera `user-data` y `meta-data` para copiarlos
a una partición FAT32 etiquetada `CIDATA`:

```bash
sudo dd if=ubuntu-24.04.4-live-server-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
sudo parted /dev/sdX -- mkpart primary fat32 -100MB 100%
sudo mkfs.vfat -n CIDATA /dev/sdX3
sudo mount /dev/sdX3 /mnt && sudo cp cloud-init/user-data cloud-init/meta-data /mnt && sudo umount /mnt
```

Subiquity encuentra la configuración, **pero se detiene a preguntar**:

```
Confirmation is required to continue.
Add 'autoinstall' to your kernel command line to avoid this
Continue with autoinstall? (yes|no)
```

Es una protección deliberada de subiquity: solo se salta el aviso cuando
`autoinstall` viaja en la línea de comandos del kernel, y eso exige tocar el
GRUB de la ISO. Por eso el reempaquetado es el camino recomendado. Si usas este,
tendrás que teclear `yes` una vez.

</details>

### 3. Qué vas a ver

1. **Instalación base**, sin una sola pregunta: particionado de todo el disco,
   red por DHCP, paquetes base. 5–15 minutos. Se reinicia solo.
2. **Primer arranque**: el asistente toma la consola.
   - Con el token horneado y una sola zona: **no pregunta nada**.
   - Sin token horneado: pide el token (oculto) y, si hace falta, la zona.
   - Sin red: pide SSID y contraseña antes de nada.
   - Muestra la configuración resuelta y pide confirmación (evitable con `-y`).
3. **Instalación automática**: Docker, Coolify, cloudflared, túnel y DNS.
   Coolify tarda varios minutos en levantar sus contenedores.
4. **Resumen final** en pantalla y en `/root/instalacion-resumen.txt`: URLs,
   estado de cada servicio y el patrón de dominio para las apps. Las
   credenciales generadas van aparte, a `/root/instalacion-credenciales.txt`
   (modo 0600); guárdalas en un gestor de contraseñas y borra el fichero.

Después, el servicio se autodesactiva y no vuelve a ejecutarse.

## Usarlo fuera del USB

`setup.sh` no depende del instalador. En cualquier Linux ya arrancado:

```bash
sudo sh setup.sh --cf-token=@tok
```

También funciona canalizado, que es el caso donde `stdin` es el propio script:
el asistente abre `/dev/tty` para preguntar.

```bash
curl -fsSL https://tu-servidor/setup.sh | sudo sh -s -- --cf-token=@/root/tok
```

Opciones completas con `sh setup.sh --help`.

## Cómo se instala el asistente (y por qué así)

El asistente de primer arranque se instala con **`late-commands`**, que corren
en el entorno del instalador con el sistema destino montado en `/target`. Ahí se
copian el script y la unidad systemd, y se crea a mano el enlace en
`multi-user.target.wants`.

Lo natural habría sido usar `write_files` y `runcmd` bajo `autoinstall.user-data`,
que es lo que la documentación de Ubuntu describe: esas directivas «afectan al
sistema destino y se procesan en el primer arranque». En la práctica **no
funcionó**: el servicio no se instalaba nunca y fallaba en silencio, sin un solo
error. Es un modo de fallo bien documentado — `write_files` y `runcmd` son
módulos *per-instance*, y cloud-init los omite si cree que ya vio esa instancia,
cosa que puede pasar cuando el propio autoinstall se entrega por un seed NoCloud
en el medio de instalación. Los detalles están en la incidencia
[#1](https://github.com/fompi/culificador/issues/1).

La diferencia de fondo no es qué mecanismo es más bonito, sino cuál es
**observable cuando falla**. `late-commands` corre en un momento conocido y su
salida sale por la consola del instalador; el otro camino depende del estado
interno de cloud-init en el destino y, cuando no hace nada, no dice por qué.

Dos precauciones que vienen de haber roto esto:

- El bloque termina siempre en `true`. Un `late-commands` que devuelve error
  **aborta la instalación entera** y deja el equipo sin instalar. Nos pasó.
- No se usa `systemctl` dentro de `/target`: el enlace simbólico se crea a mano,
  que es justo lo que hace `systemctl enable` y no necesita un systemd corriendo
  allí.

El bloque `user-data` se mantiene como camino redundante e idempotente: cubre el
caso de arrancar desde una partición CIDATA suelta, donde no hay `/cdrom/cidata`
del que copiar.

## Portabilidad y dependencias

Escrito en POSIX sh: comprobado en `dash`, `bash`, `zsh`, `ksh` y el `sh` de
macOS. Sin bashismos (nada de arrays, `[[ ]]` ni `printf -v`).

Se adapta a lo que encuentre en la máquina:

- **HTTP**: `curl`, o `wget`, o `python3`.
- **JSON**: `jq` del sistema, o `python3`, y si no hay ninguno **descarga `jq`
  al directorio de trabajo y lo usa desde ahí, sin instalarlo**.
- **Interfaz**: `whiptail`, o `dialog`, o preguntas de texto plano.

`cloudflared` sí se instala en `/usr/local/bin`: no es andamiaje, es un servicio
permanente, y una unidad de systemd apuntando a un directorio temporal se
rompería al reiniciar.

Docker y Coolify solo se instalan en Linux. En macOS o BSD el script avisa y hay
que usar `--skip-docker` / `--skip-coolify`.

## Desarrollo

```bash
make test    # 81 comprobaciones, sin dependencias obligatorias
make lint    # shellcheck en dialecto sh + sintaxis en varios shells
make build   # genera cloud-init/user-data
make iso ISO=ubuntu-24.04.4-live-server-amd64.iso
```

La suite se salta los grupos para los que le falte una herramienta y lo dice.
En CI se exige que **no se omita ninguno**: si falta una dependencia en el
runner, el build falla en vez de dar verde sin haber probado.

Grupos: `syntax`, `json`, `validators`, `resolution`, `build`, `latecommands`.
Se pueden pedir sueltos: `sh tests/run.sh json build`.

**Lo que la suite no puede cubrir**, y hay que probar a mano en una VM:

- El arranque real desde la ISO y el primer boot.
- El paso `tunnel_service`, que habla con el edge real de Cloudflare.

Si tocas `cloud-init/user-data.tpl`, la unidad systemd o el bloque
`late-commands`, prueba en una VM. Ese camino ya se rompió una vez **en
silencio**, y las pruebas automáticas solo comprueban la forma del artefacto,
no que arranque.

Detalles en [CONTRIBUTING.md](CONTRIBUTING.md). Modelo de amenaza y manejo de
secretos en [SECURITY.md](SECURITY.md).

## Si algo falla

El script es reintentable por pasos: cada paso completado deja una marca en
`/var/lib/coolify-setup/` y no se repite.

```bash
sudo systemctl start coolify-setup.service
```

o directamente `sudo sh /usr/local/sbin/coolify-setup.sh`. Para empezar de cero,
añade `--reset`.

Log completo con marcas de tiempo en `/var/log/coolify-setup.log`.

Los argumentos de línea de comandos siempre pisan la configuración guardada de
un intento anterior, así que puedes corregir un valor sin `--reset`.

**Recuperar el acceso**: la cuenta `installer` nace bloqueada a propósito, así
que no hace falta generar ningún hash al construir el USB. Si quieres una puerta
de servicio por si el asistente fallara antes de crear tu usuario:

```bash
./build-usb.sh --iso=ubuntu.iso --rescue-password=@/ruta/a/una/contrasena
```

Sin ella, la única vía es el modo de recuperación de GRUB (mantén
<kbd>Shift</kbd> al arrancar → *Advanced options* → *recovery mode* →
*root shell*).

La puerta de servicio **se cierra sola**. El último paso del asistente, ya con
todo lo demás terminado, comprueba que tu usuario administrador existe, manda
(sudo/wheel/admin) y tiene con qué entrar (contraseña real o `authorized_keys`);
solo entonces bloquea `installer`, la saca de sudo y le pone una shell que no
deja iniciar sesión. Si no puede verificarlo, **no la toca** y lo dice en el
resumen: prefiere una cuenta de rescate viva a un equipo inaccesible. Si el
asistente falló a mitad, `installer` sigue utilizable a propósito y tendrás que
retirarla a mano. `--purge-installer` la borra con su home, `--keep-rescue` la
conserva tal cual, y `--installer-user=NOMBRE` sirve si le pusiste otro nombre.

## Cosas que conviene saber

- **El primer usuario de Coolify.** Coolify no expone API para crearlo: su token
  de API se genera desde la interfaz, y para eso ya tiene que existir un
  usuario. El script automatiza el formulario público `/register` con las
  credenciales generadas. Es la parte más frágil del conjunto porque depende del
  HTML de Coolify; si falla, no rompe nada — el resumen final te dice que entres
  al panel y te registres con el email y la contraseña que ya tienes ahí. El
  primer usuario registrado es el propietario.
- **Geolocalización.** La zona horaria se toma del sistema. Solo si el sistema
  está en UTC —o sea, si nadie ha elegido ninguna— se consulta `ipapi.co`, y se
  avisa por pantalla antes de hacerlo: esa llamada revela tu IP pública y el
  momento de la instalación. Con `--timezone=Europe/Madrid` o con `--no-geoip`
  (o `NO_GEOIP=1`) no se hace nunca. `SECURITY.md` enumera todas las llamadas
  salientes del script.
- **Secretos al terminar.** El resumen se parte en dos: `instalacion-resumen.txt`
  (sin credenciales, se puede enseñar) e `instalacion-credenciales.txt` (0600,
  con las contraseñas). Al completar con éxito se borran el token de Cloudflare
  y el del túnel del disco; con `--keep-secrets` se conservan y el resumen lo
  advierte. Si la instalación falla a mitad **no se borra nada**: el reintento
  los necesita.
- **Secretos en `ps`.** Un `--cf-token=xxx` literal es visible para otros
  usuarios de la máquina. Usa `@fichero`, `@-` o la variable de entorno.
- **Dominio comodín.** El CNAME `*.app.tudominio.tld` ya está enrutado: al crear
  una app en Coolify le pones un dominio con ese patrón y funciona sin tocar DNS.

## Limitaciones conocidas

Análisis del proyecto a fecha de hoy. Cada punto tiene su incidencia con el
detalle, las implicaciones y un esbozo de solución.

### Seguridad

| | Qué pasa |
|---|---|
| [#2](https://github.com/fompi/culificador/issues/2) | **Ninguna descarga se verifica.** Docker, Coolify, `jq` y `cloudflared` se bajan y se ejecutan como root sin comprobar hash ni firma. La única protección es TLS. |
| [#4](https://github.com/fompi/culificador/issues/4) | **Sin cortafuegos.** El panel de Coolify (8000) y el proxy (80) quedan accesibles desde toda la red local, saltándose el túnel. |
| [#8](https://github.com/fompi/culificador/issues/8) | `build-usb.sh` no verifica la ISO de entrada. |

### Sin verificar

| | Qué pasa |
|---|---|
| [#6](https://github.com/fompi/culificador/issues/6) | **El paso `tunnel_service` nunca se ha probado con un túnel real.** Es el último eslabón: sin él no hay nada publicado. |
| [#10](https://github.com/fompi/culificador/issues/10) | **x86_64 y arranque BIOS sin verificar**, siendo el destino declarado del proyecto. Todo se ha probado en arm64 con UEFI. |

### Deuda y operación

| | Qué pasa |
|---|---|
| [#5](https://github.com/fompi/culificador/issues/5) | `cloudflared` se instala desde `latest`: dos equipos con la misma ISO acaban distintos. |
| [#7](https://github.com/fompi/culificador/issues/7) | El registro del primer usuario de Coolify raspa su HTML. Se romperá en alguna actualización. |
| [#11](https://github.com/fompi/culificador/issues/11) | Sin copias, sin actualizaciones planificadas y sin monitorización. |
| [#13](https://github.com/fompi/culificador/issues/13) | Sin versionado real: no se puede saber qué versión instaló un equipo. |
| [#14](https://github.com/fompi/culificador/issues/14) | CI no se ejecuta por facturación de la cuenta; el badge da rojo sin haber probado nada. |
| [#15](https://github.com/fompi/culificador/issues/15) | Reejecutar deja túneles huérfanos en Cloudflare. |

**Si vas a usarlo en serio**, lo mínimo antes es [#2](https://github.com/fompi/culificador/issues/2),
[#4](https://github.com/fompi/culificador/issues/4) y
[#6](https://github.com/fompi/culificador/issues/6): integridad de lo que se
instala, no quedar expuesto en la LAN, y comprobar que el túnel levanta de
verdad.

## Qué está verificado y qué no

Probado ejecutándolo, no solo leyéndolo.

**En una VM (QEMU, Ubuntu Server 24.04.4, UEFI):**

- La ISO reempaquetada arranca e instala **sin ninguna intervención**:
  particionado LVM de todo el disco, red DHCP, reinicio.
- Tras el reinicio, el asistente arranca solo y llega hasta el final:
  `late-commands` deja los tres ficheros con los permisos correctos, el
  servicio queda `enabled` y se ejecuta tomando la consola.
- Comprobado dentro del sistema instalado: hostname derivado a `fompi`,
  zona horaria `Europe/Madrid` aplicada (se ve en el propio log, cuyas marcas
  de tiempo saltan dos horas justo en ese paso), usuario `ferran` creado en los
  grupos `sudo` y `docker`, acceso por SSH con la clave horneada, y Docker
  29.7.2 instalado y respondiendo.
- Las llamadas a Cloudflare salen del sistema instalado y llegan al simulador:
  verificación del token, resolución de la zona y consulta de la cuenta.
- Coolify instalado con sus seis contenedores en estado *healthy*, dominio del
  panel configurado, y **el primer usuario registrado automáticamente** — que
  era la parte más frágil de todo el conjunto.
- `cloudflared` descargado para `linux/arm64`, túnel creado por API, reglas de
  enrutado aplicadas (comodín a `localhost:80`, panel a `localhost:8000`,
  `404` por defecto) y los dos CNAME creados.
- El reintento se ejerció **en una avería real**, no simulada: un paso falló por
  un fallo de red, y al relanzar el servicio saltó los diez pasos ya
  completados y continuó justo donde se había quedado.
- Todo esto salió de ahí, no de la teoría:
  - Con la partición CIDATA sola, el instalador **se para a preguntar**
    (`Continue with autoinstall?`). Por eso existe el reempaquetado de la ISO.
  - Un `late-commands` que habilitaba el servicio **abortaba la instalación**:
    la unidad todavía no existe en ese momento, la escribe cloud-init en el
    primer arranque.
  - `runcmd` con solo `enable` no habría lanzado el asistente hasta el
    **segundo** reinicio; hace falta `start --no-block`.

**En contenedores Ubuntu 24.04 reales:**

- Con **solo `curl`** (sin `jq`, sin `python3`): descarga `jq` al directorio de
  trabajo, lo usa desde ahí y **no lo instala en el sistema**.
- Sin `curl` ni `wget` ni `python3`: falla limpio explicando qué falta.
- Pasos de sistema aplicados de verdad y comprobados después: hostname,
  timezone (symlink y `/etc/timezone`), usuario creado en el grupo `sudo`,
  hash de contraseña puesto, entrada en `/etc/hosts`.
- Un sistema mínimo sin `iproute2` daba **falso negativo de red** y pedía WiFi
  sin necesidad; ahora hay respaldo por `/proc/net/route` y sonda HTTP real.

**En el host:**

- Sintaxis POSIX en `dash`, `bash`, `zsh`, `ksh` y `sh`.
- `json_get` con los dos motores (`jq` y `python3`) dando salida idéntica.
- Flujo de resolución completo contra una API de Cloudflare simulada:
  descubrimiento de zona, menú multi-zona, derivación de hostname, email y
  zona horaria, creación de túnel, ingress y registros DNS.
- Precedencia argumentos > configuración guardada > derivado > preguntar.
- Idempotencia y reintento de pasos.
- Prompts vía `/dev/tty` con el script canalizado (`curl | sh`).
- `build-usb.sh`: YAML válido, `setup.sh` incrustado idéntico byte a byte,
  parámetros de arranque y `/cidata` presentes en la ISO, sobrescritura al
  reejecutar, y guarda que impide destruir la ISO de origen.

**No verificado:**

- Hardware x86_64 real (la VM es arm64; el reempaquetado conserva el arranque
  híbrido, pero el camino BIOS heredado no se ha ejercitado).
- La API **real** de Cloudflare: todas las llamadas se probaron contra un
  simulador que imita sus respuestas, no contra Cloudflare.
- El registro automático del primer usuario de Coolify, que depende del HTML
  de su formulario y es la parte más frágil.
- WiFi: no hay adaptador inalámbrico en la VM.
