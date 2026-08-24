# USB de instalación desatendida — Ubuntu Server + Docker + Coolify + Cloudflare Tunnel

[![CI](https://github.com/fompi/autounattended-coolify/actions/workflows/ci.yml/badge.svg)](https://github.com/fompi/autounattended-coolify/actions/workflows/ci.yml)
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
3. La ISO de Ubuntu **Server** LTS: <https://ubuntu.com/download/server>. La de
   escritorio no vale: no lleva `subiquity` y el autoinstall no se aplica.
   Verifícala antes de usarla ([abajo](#verificar-la-iso-de-ubuntu)).
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

### Verificar la ISO de Ubuntu

Todo lo que se instala después hereda la confianza de ese fichero: si la ISO
está manipulada, da igual el resto, porque se instala un sistema comprometido y
encima se le hornea dentro el token de Cloudflare.

`build-usb.sh` comprueba **siempre**, antes de tocar nada, que el fichero sea de
verdad una ISO9660 (marca `CD001` en el offset 32769), que el volume ID no sea
el de una imagen de escritorio, que la arquitectura coincida, que no sea una
descarga truncada y que dentro haya `/casper/vmlinuz` y `/boot/grub/grub.cfg`.
Eso pilla los errores tontos, pero **no** demuestra que la ISO sea la de
Canonical. Para eso:

```bash
# Contra un hash que ya tienes:
./build-usb.sh --iso=ubuntu-24.04.4-live-server-amd64.iso \
               --iso-sha256=e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433

# O que se baje solo SHA256SUMS y su firma y lo compruebe todo:
./build-usb.sh --iso=ubuntu-24.04.4-live-server-amd64.iso --verify-iso
```

`--verify-iso` baja `SHA256SUMS` y `SHA256SUMS.gpg` de `releases.ubuntu.com`,
valida la firma con la clave de Canonical
(`843938DF228D22F7B3742BC0D94AA3F0EFE21092`) y busca el hash de tu ISO en la
lista. **Si no hay `gpg`, verifica solo el hash y lo dice**: sin firma, quien
pueda alterar la descarga de la ISO puede alterar también la lista. Si el hash
no cuadra, no se genera nada, haya firma o no.

<details>
<summary>Hacerlo a mano, con los comandos exactos</summary>

```bash
# 1. Bajar la lista de hashes y su firma (ajusta la versión).
curl -fLO https://releases.ubuntu.com/24.04.4/SHA256SUMS
curl -fLO https://releases.ubuntu.com/24.04.4/SHA256SUMS.gpg

# 2. Traer la clave de firma de las imágenes de Ubuntu.
gpg --keyserver hkps://keyserver.ubuntu.com \
    --recv-keys 843938DF228D22F7B3742BC0D94AA3F0EFE21092

# 3. Comprobar que la lista la firmó Canonical. Tiene que decir
#    "Good signature from Ubuntu CD Image Automatic Signing Key".
gpg --verify SHA256SUMS.gpg SHA256SUMS

# 4. Comprobar la ISO contra la lista ya verificada.
sha256sum --ignore-missing -c SHA256SUMS     # Linux
shasum -a 256 ubuntu-24.04.4-live-server-amd64.iso   # macOS: comparar a ojo
```

El paso 3 es el que importa: sin él solo estás comprobando que la ISO coincide
con una lista que has bajado del mismo sitio. En el paso 2, `gpg` avisará de que
la clave «no es de confianza» mientras no la firmes tú; eso es normal y no
invalida la comprobación de integridad.

</details>

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
[#1](https://github.com/fompi/autounattended-coolify/issues/1).

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
- **SHA-256** (en `build-usb.sh`): `sha256sum`, o `shasum -a 256`, o `openssl
  dgst`, o `python3`. Si pides verificar y no hay ninguna, falla en vez de
  seguir en silencio. `gpg` es opcional: sin él, `--verify-iso` comprueba el
  hash y avisa de que la firma no se ha validado.

`cloudflared` sí se instala en `/usr/local/bin`: no es andamiaje, es un servicio
permanente, y una unidad de systemd apuntando a un directorio temporal se
rompería al reiniciar.

Docker y Coolify solo se instalan en Linux. En macOS o BSD el script avisa y hay
que usar `--skip-docker` / `--skip-coolify`.

## Desarrollo

```bash
make test    # 257 comprobaciones, sin dependencias obligatorias
make lint    # shellcheck en dialecto sh + sintaxis en varios shells
make build   # genera cloud-init/user-data
make iso ISO=ubuntu-24.04.4-live-server-amd64.iso
```

La suite se salta los grupos para los que le falte una herramienta y lo dice.
En CI se exige que **no se omita ninguno**: si falta una dependencia en el
runner, el build falla en vez de dar verde sin haber probado.

Grupos: `syntax`, `json`, `validators`, `timezone`, `secrets`, `installer`,
`descargas`, `version`, `resolution`, `build`, `latecommands`. Se pueden pedir
sueltos: `sh tests/run.sh json build`.

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
- **Reinstalar no duplica el túnel.** El nombre del túnel sale del dominio del
  panel (`coolify-coolify.tudominio.tld`), no del hostname: formatear el mini PC
  y reinstalarlo con otro nombre de máquina reutiliza el mismo túnel en vez de
  crear uno nuevo y dejar el viejo huérfano apuntando a nada. Las instalaciones
  anteriores, que sí lo nombraban con el hostname, se detectan y se reutilizan
  tal cual: no se renombran ni se duplican. El nombre queda anotado en
  `tunnel.env` y en el resumen, para poder identificar después qué túnel de la
  cuenta es el de este equipo. **Nada se borra solo en Cloudflare**, tampoco con
  `--reset`: si abandonas un despliegue, el túnel y los CNAME hay que quitarlos a
  mano desde el panel de Cloudflare.
- **El túnel se comprueba conectado, no arrancado.** `systemctl is-active` no
  basta: `cloudflared` arranca y reintenta en bucle aunque el token no valga, así
  que «activo» no significa «conectado». El paso le pregunta a Cloudflare por el
  estado del túnel y espera a que sea `healthy` (acepta `degraded` —conecta y pasa
  tráfico, con menos conexiones al edge de las esperadas— pero avisa). El tiempo
  máximo son 120 s, ajustables con `TUNNEL_HEALTH_TIMEOUT`. Si no conecta, el
  mensaje distingue las tres causas, que tienen tres soluciones distintas: sin
  salida a internet, cortafuegos de salida bloqueando el puerto 7844, o token del
  túnel que no vale. Si no se puede ni preguntar, avisa y sigue: no conviene
  inventarse un modo de fallo tardío por no haber podido comprobar nada.
- **Dominio comodín.** El CNAME `*.app.tudominio.tld` ya está enrutado: al crear
  una app en Coolify le pones un dominio con ese patrón y funciona sin tocar DNS.
- **Integridad de lo que se instala.** `jq` y `cloudflared` se comprueban contra
  un SHA-256 antes de usarse; si no cuadra, el paso aborta y el fichero se
  borra, así que no queda nada sin verificar en el disco. Si en el sistema no
  hay `sha256sum`, `shasum` ni `openssl`, falla en vez de continuar a ciegas.
  Docker y Coolify no publican hash por versión: sin `--pin-docker` /
  `--pin-coolify` se avisa por pantalla y en el log de que se va a ejecutar un
  script remoto como root sin verificar. `--offline-dir=RUTA` coge los cuatro
  artefactos de un directorio local, y los verifica igual. Los matices —qué es
  verificación de verdad y qué es confianza en el primer uso— están en
  `SECURITY.md`.
- **Versiones.** `build-usb.sh` hornea `git describe --tags --always --dirty` en
  el `user-data`, y viaja hasta el destino por el `EnvironmentFile` de la unidad
  systemd (`SETUP_VERSION=`); si se construye fuera de un repositorio queda
  `sin-git`, que también es información. No se sustituye un marcador dentro de
  `setup.sh` a propósito: `build-usb.sh` exige que el script incrustado sea
  idéntico **byte a byte** al original. `setup.sh --version` y
  `build-usb.sh --version` responden en cualquier momento, el resumen final
  lleva una tabla con proyecto, sistema base, Docker, Coolify, `cloudflared` y
  `jq`, y lo mismo queda en `/etc/coolify-setup.version` (0644, sin secretos)
  para poder leerlo después sin rebuscar en el log.
- **Versiones fijadas.** `cloudflared` y `jq` se instalan en una versión concreta
  escrita en `setup.sh`, no en `latest`: la misma ISO tiene que dar el mismo
  sistema hoy y dentro de seis meses. El contrapeso es que **un pin envejece**:
  si nadie lo sube, acaba instalando una versión con vulnerabilidades conocidas,
  que es peor que `latest`. Mientras no haya un proceso que lo actualice, revisa
  el pin de vez en cuando y usa `--cloudflared-version=X` para saltártelo.

## Limitaciones conocidas

Análisis del proyecto a fecha de hoy. Cada punto tiene su incidencia con el
detalle, las implicaciones y un esbozo de solución.

### Seguridad

| | Qué pasa |
|---|---|
| [#2](https://github.com/fompi/autounattended-coolify/issues/2) | **Verificación de descargas incompleta.** `jq` y `cloudflared` sí se comprueban contra un SHA-256, pero el de `cloudflared` lo calculamos nosotros (Cloudflare no publica hashes): es confianza en el primer uso, no verificación independiente. El script de Docker y el de Coolify **no se verifican** salvo que los fijes con `--pin-docker` / `--pin-coolify`. Detalle en `SECURITY.md`. |
| [#4](https://github.com/fompi/autounattended-coolify/issues/4) | **Sin cortafuegos.** El panel de Coolify (8000) y el proxy (80) quedan accesibles desde toda la red local, saltándose el túnel. |
| [#8](https://github.com/fompi/autounattended-coolify/issues/8) | *Resuelto.* `build-usb.sh` comprueba la ISO de entrada (ISO9660, edición, arquitectura, tamaño y contenido) y sabe verificar hash y firma con `--iso-sha256` / `--verify-iso`. Sigue sin ser obligatorio: quien no lo pida, no verifica. |

### Sin verificar

| | Qué pasa |
|---|---|
| [#6](https://github.com/fompi/autounattended-coolify/issues/6) | **El paso `tunnel_service` nunca se ha probado con un túnel real.** Es el último eslabón: sin él no hay nada publicado. La comprobación ya no se conforma con `is-active` —pregunta a Cloudflare si el túnel está conectado, con reintentos y diagnóstico—, pero la conexión al edge real sigue sin ejercitarse. |
| [#10](https://github.com/fompi/autounattended-coolify/issues/10) | **x86_64 y arranque BIOS sin verificar**, siendo el destino declarado del proyecto. Todo se ha probado en arm64 con UEFI. |

### Deuda y operación

| | Qué pasa |
|---|---|
| [#7](https://github.com/fompi/autounattended-coolify/issues/7) | El registro del primer usuario de Coolify **raspa su HTML**: se romperá en alguna actualización de Coolify. Lo que ya no hace es mentir — el éxito se comprueba releyendo `/register`, no por el código HTTP— y el resumen distingue registrado, ya existía, pendiente y omitido (`--skip-coolify-register`). |
| [#11](https://github.com/fompi/autounattended-coolify/issues/11) | **Sin copias y sin monitorización.** No hay copia de `/data/coolify` ni aviso si el túnel se cae. Lo que sí está resuelto es el fallo más probable —los logs de los contenedores llenando el disco, ahora limitados en `/etc/docker/daemon.json`— y los parches de seguridad automáticos (`--auto-reboot`, `--no-unattended-upgrades`). |
| [#13](https://github.com/fompi/autounattended-coolify/issues/13) | Quedan pendientes las etiquetas semánticas, el workflow de release y el aviso en CI cuando se toca el código sin tocar el `CHANGELOG.md`. La trazabilidad básica ya está: ver «Versiones» más abajo. |
| [#14](https://github.com/fompi/autounattended-coolify/issues/14) | CI no se ejecuta por facturación de la cuenta; el badge da rojo sin haber probado nada. |
| [#15](https://github.com/fompi/autounattended-coolify/issues/15) | Reejecutar deja túneles huérfanos en Cloudflare. |

**Si vas a usarlo en serio**, lo mínimo antes es fijar Docker y Coolify con
`--pin-docker` / `--pin-coolify` ([#2](https://github.com/fompi/autounattended-coolify/issues/2)),
[#4](https://github.com/fompi/autounattended-coolify/issues/4) y
[#6](https://github.com/fompi/autounattended-coolify/issues/6): integridad de lo que se
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
- Reejecutar con otro hostname contra la API simulada deja **un solo túnel** en
  la cuenta, y un túnel con el nombre antiguo se reutiliza en vez de duplicarse.
- Espera a que el túnel aparezca conectado: reintenta mientras Cloudflare
  responde `inactive`, acepta `degraded`, y **falla** si nunca conecta, dentro
  del tiempo máximo configurado. Lo que no se puede probar aquí es la conexión
  real de `cloudflared` contra el edge.
- Precedencia argumentos > configuración guardada > derivado > preguntar.
- Idempotencia y reintento de pasos.
- Prompts vía `/dev/tty` con el script canalizado (`curl | sh`).
- `build-usb.sh`: YAML válido, `setup.sh` incrustado idéntico byte a byte,
  parámetros de arranque y `/cidata` presentes en la ISO, sobrescritura al
  reejecutar, y guarda que impide destruir la ISO de origen.
- Cordura de la ISO de entrada, con imágenes sintéticas hechas con `dd`: un
  fichero que no es ISO, una de escritorio y una descarga truncada fallan con
  un mensaje que dice qué hacer, y ninguna llega a borrar la ISO de salida
  anterior. El helper de SHA-256 se compara con la herramienta del sistema.

**No verificado:**

- Hardware x86_64 real (la VM es arm64; el reempaquetado conserva el arranque
  híbrido, pero el camino BIOS heredado no se ha ejercitado).
- La API **real** de Cloudflare: todas las llamadas se probaron contra un
  simulador que imita sus respuestas, no contra Cloudflare.
- El registro automático del primer usuario de Coolify, que depende del HTML
  de su formulario y es la parte más frágil.
- WiFi: no hay adaptador inalámbrico en la VM.
- `--verify-iso` contra una ISO oficial **completa**: la descarga de
  `SHA256SUMS` y la comparación del hash sí se han ejercitado, pero la
  validación de la firma con `gpg` no se ha probado de punta a punta.
