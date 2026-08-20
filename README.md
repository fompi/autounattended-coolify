# USB de instalación desatendida — Ubuntu Server + Docker + Coolify + Cloudflare Tunnel

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
| Asistente de primer arranque (Docker, Coolify, túnel) | **No arranca.** En investigación. |

El instalador deja Ubuntu Server puesto sin tocar nada, pero tras el reinicio el
asistente no llega a ejecutarse, así que Docker, Coolify y el túnel **no se
configuran todavía**. `setup.sh` sí funciona si lo lanzas a mano sobre un
sistema ya arrancado (ver [Usarlo fuera del USB](#usarlo-fuera-del-usb)).

Detalle y seguimiento en las incidencias del repositorio.

## Qué se pregunta y qué no

| Dato | De dónde sale |
|---|---|
| **Cloudflare API Token** | **Único dato que hay que dar.** Por `--cf-token`, por `CF_API_TOKEN`, o preguntado por pantalla. |
| Dominio raíz | `GET /zones` con ese token. Si el token cubre **una** zona se usa sin preguntar; si cubre varias, se elige de un menú (o `--domain`). |
| Subdominio de apps | `app` por defecto (`--app-subdomain`). |
| Subdominio del panel | `coolify` por defecto (`--coolify-subdomain`). |
| Hostname | Primera etiqueta del hostname actual si no es genérico; si lo es, primera etiqueta del dominio. |
| Usuario administrador | `SUDO_USER`, o el primer usuario con uid ≥ 1000, o se crea `admin`. |
| Contraseña del admin | Generada (24 caracteres). Aparece en el resumen final. |
| Clave SSH | Se respeta la que ya haya en `authorized_keys`; si se pasa `--ssh-key`, se desactiva el acceso por contraseña. |
| Zona horaria | Geolocalización de la IP pública; si falla, la del sistema; si no, UTC. |
| Email del admin de Coolify | Extraído del nombre de la cuenta de Cloudflare; si no, `admin@<dominio>`. |
| Contraseña de Coolify | Generada. Aparece en el resumen final. |
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
| `build-usb.sh` | Incrusta `setup.sh` en la plantilla y genera `cloud-init/user-data`. |
| `cloud-init/user-data`, `meta-data` | Generados por `build-usb.sh`. No se versionan: pueden llevar el token dentro. |

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

   > **Hoy esto no ocurre**: el sistema arranca hasta el login y el asistente
   > no se lanza. Lo de abajo describe el comportamiento previsto, todavía no
   > alcanzado.

   - Con el token horneado y una sola zona: **no pregunta nada**.
   - Sin token horneado: pide el token (oculto) y, si hace falta, la zona.
   - Sin red: pide SSID y contraseña antes de nada.
   - Muestra la configuración resuelta y pide confirmación (evitable con `-y`).
3. **Instalación automática**: Docker, Coolify, cloudflared, túnel y DNS.
   Coolify tarda varios minutos en levantar sus contenedores.
4. **Resumen final** en pantalla y en `/root/instalacion-resumen.txt`: URLs,
   credenciales generadas, estado de cada servicio y el patrón de dominio para
   las apps.

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

**Recuperar el acceso**: la cuenta `installer` nace bloqueada a propósito. Si el
asistente fallara antes de crear tu usuario, entra por el modo de recuperación
de GRUB (mantén <kbd>Shift</kbd> al arrancar → *Advanced options* → *recovery
mode* → *root shell*).

## Cosas que conviene saber

- **El primer usuario de Coolify.** Coolify no expone API para crearlo: su token
  de API se genera desde la interfaz, y para eso ya tiene que existir un
  usuario. El script automatiza el formulario público `/register` con las
  credenciales generadas. Es la parte más frágil del conjunto porque depende del
  HTML de Coolify; si falla, no rompe nada — el resumen final te dice que entres
  al panel y te registres con el email y la contraseña que ya tienes ahí. El
  primer usuario registrado es el propietario.
- **Geolocalización.** Para deducir la zona horaria se consulta `ipapi.co`, lo
  que revela tu IP pública a ese servicio. Con `--timezone=Europe/Madrid` no se
  hace ninguna llamada.
- **Secretos en `ps`.** Un `--cf-token=xxx` literal es visible para otros
  usuarios de la máquina. Usa `@fichero`, `@-` o la variable de entorno.
- **Dominio comodín.** El CNAME `*.app.tudominio.tld` ya está enrutado: al crear
  una app en Coolify le pones un dominio con ese patrón y funciona sin tocar DNS.

## Qué está verificado y qué no

Probado ejecutándolo, no solo leyéndolo.

**En una VM (QEMU, Ubuntu Server 24.04.4, UEFI):**

- La ISO reempaquetada arranca e instala **sin ninguna intervención**:
  particionado LVM de todo el disco, red DHCP, reinicio.
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

**Verificado que NO funciona:**

- El asistente de primer arranque no se ejecuta tras el reinicio. Esperando
  seis minutos con la consola serie enganchada: el sistema llega al login,
  el hostname sigue sin cambiar y no hay ni una sola llamada a la API.
  `subiquity/Userdata/apply_autoinstall_config` sí terminó sin avisos durante
  la instalación, así que subiquity leyó y aplicó el bloque `user-data`.

**No verificado:**

- Hardware x86_64 real (la VM es arm64; el reempaquetado conserva el arranque
  híbrido, pero el camino BIOS heredado no se ha ejercitado).
- La API **real** de Cloudflare: todas las llamadas se probaron contra un
  simulador que imita sus respuestas, no contra Cloudflare.
- El registro automático del primer usuario de Coolify, que depende del HTML
  de su formulario y es la parte más frágil.
- WiFi: no hay adaptador inalámbrico en la VM.
