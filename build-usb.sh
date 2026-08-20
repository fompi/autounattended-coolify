#!/bin/sh
# build-usb.sh — genera el par user-data/meta-data del USB de instalación.
#
# Incrusta setup.sh dentro de user-data y, opcionalmente, hornea el token de
# Cloudflare para que el mini PC no pregunte absolutamente nada.
#
#   ./build-usb.sh                              # pregunta el token al arrancar el PC
#   ./build-usb.sh --cf-token=@/ruta/token      # cero interaccion en el destino
#   ./build-usb.sh --cf-token=@tok --domain=fompi.net --out /Volumes/CIDATA
#
# Solo genera ficheros: no toca ningun disco. Al final imprime los comandos
# exactos para copiarlos al USB.

set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
TPL="$HERE/cloud-init/user-data.tpl"
UNIT="$HERE/cloud-init/coolify-setup.service"
SETUP="$HERE/setup.sh"
OUT="$HERE/cloud-init"
KEYBOARD=es
CF_TOKEN=''
PASSTHRU=''
ISO_IN=''
ISO_OUT=''
SSH_KEY=''
RESCUE_PW=''

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

argval() {
    case "$1" in
        @-) cat ;;
        @*) f=${1#@}; [ -r "$f" ] || die "No se puede leer el fichero: $f"; cat "$f" ;;
        *)  printf '%s' "$1" ;;
    esac
}

usage() {
    cat <<EOF
build-usb.sh — prepara la instalacion desatendida.

MODO RECOMENDADO: reempaquetar la ISO. Produce una imagen que se graba con un
solo dd y arranca sin preguntar absolutamente nada.

  --iso=ORIGEN.iso    ISO de Ubuntu Server a reempaquetar.
  --iso-out=SALIDA    ISO resultante. Por defecto: ubuntu-autoinstall.iso

  Sin --iso solo se generan user-data/meta-data para copiarlos a mano a una
  particion FAT32 etiquetada CIDATA. Ojo: por ese camino el instalador PIDE
  CONFIRMACION por pantalla, porque 'autoinstall' no viaja en la linea de
  comandos del kernel. Solo el reempaquetado la evita.

OPCIONES
  --cf-token=VALOR    Token de Cloudflare a hornear. Acepta @/ruta/fichero o
                      @-. Si se omite, el mini PC lo preguntara al arrancar.
  --ssh-key=VALOR     Clave publica SSH para el usuario administrador. Acepta
                      @/ruta/id_ed25519.pub. Se instala como fichero aparte,
                      no como argumento, porque las claves llevan espacios.
                      Si se indica, se desactiva el acceso por contrasena.
  --rescue-password=V Contrasena para la cuenta 'installer'. Por defecto esa
                      cuenta nace BLOQUEADA y nadie puede entrar: si el
                      asistente fallara, la unica via seria el modo de
                      recuperacion de GRUB. Con esto tienes una puerta de
                      servicio. Acepta @/ruta/fichero o @-.
  --keyboard=XX       Teclado del instalador. Por defecto: es
  --out=DIR           Donde dejar user-data/meta-data. Por defecto: cloud-init/
  --                  Lo que venga despues se pasa tal cual a setup.sh:
                        ./build-usb.sh --iso=u.iso -- --domain=fompi.net
                      Estos argumentos se dividen por espacios en el destino,
                      asi que NINGUN valor puede contener espacios. Por eso
                      --ssh-key tiene su propia opcion. Si necesitas pasar una
                      contrasena con espacios, usa la forma @fichero de
                      setup.sh apuntando a un fichero del sistema destino.
  -h, --help          Esta ayuda.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cf-token=*) CF_TOKEN=$(argval "${1#*=}") ;;
        --cf-token)   shift; CF_TOKEN=$(argval "$1") ;;
        --iso=*)      ISO_IN=${1#*=} ;;
        --iso)        shift; ISO_IN=$1 ;;
        --iso-out=*)  ISO_OUT=${1#*=} ;;
        --iso-out)    shift; ISO_OUT=$1 ;;
        --rescue-password=*) RESCUE_PW=$(argval "${1#*=}") ;;
        --rescue-password)   shift; RESCUE_PW=$(argval "$1") ;;
        --ssh-key=*)  SSH_KEY=$(argval "${1#*=}") ;;
        --ssh-key)    shift; SSH_KEY=$(argval "$1") ;;
        --keyboard=*) KEYBOARD=${1#*=} ;;
        --out=*)      OUT=${1#*=} ;;
        --out)        shift; OUT=$1 ;;
        --)           shift; PASSTHRU="$*"; break ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage >&2; die "Opcion desconocida: $1" ;;
    esac
    shift
done

[ -r "$TPL" ]   || die "Falta la plantilla $TPL"
[ -r "$UNIT" ]  || die "Falta la unidad systemd $UNIT"
[ -r "$SETUP" ] || die "Falta $SETUP"
mkdir -p "$OUT"

sh -n "$SETUP" || die "setup.sh no pasa la comprobacion de sintaxis; no se genera nada."

TMP=$(mktemp -d) || die "No se pudo crear un directorio temporal"
trap 'rm -rf "$TMP"' EXIT INT TERM

# Hash SHA-512 para /etc/shadow. Se prueban varias herramientas porque ninguna
# esta garantizada: LibreSSL (macOS) no soporta 'passwd -6', y el modulo crypt
# de Python desaparecio en 3.13. Ninguna recibe la contrasena por argv, que
# seria visible en 'ps'.
hash_password() {
    if command -v mkpasswd >/dev/null 2>&1; then
        printf '%s' "$1" | mkpasswd -m sha-512 --stdin
    elif command -v openssl >/dev/null 2>&1 && printf x | openssl passwd -6 -stdin >/dev/null 2>&1; then
        printf '%s' "$1" | openssl passwd -6 -stdin
    elif command -v python3 >/dev/null 2>&1 && python3 -c 'import crypt' >/dev/null 2>&1; then
        RESCUE_PW_ENV="$1" python3 -c 'import crypt,os; print(crypt.crypt(os.environ["RESCUE_PW_ENV"], crypt.mksalt(crypt.METHOD_SHA512)))'
    else
        die "No hay forma de generar el hash SHA-512.
  Instala 'whois' (aporta mkpasswd) o usa un OpenSSL con 'passwd -6'."
    fi
}

# Por defecto la cuenta de instalacion queda bloqueada: '!' no es un hash
# valido, asi que no hay contrasena con la que entrar.
INSTALLER_PW_HASH='!'
if [ -n "$RESCUE_PW" ]; then
    INSTALLER_PW_HASH=$(hash_password "$RESCUE_PW") \
        || die "No se pudo generar el hash de la contrasena de rescate."
    case "$INSTALLER_PW_HASH" in
        \$6\$*) : ;;
        *) die "El hash generado no parece SHA-512: ${INSTALLER_PW_HASH%%\$*}" ;;
    esac
fi

# --- Bloque opcional con el token, como entrada extra de write_files --------
if [ -n "$SSH_KEY" ]; then
    case "$SSH_KEY" in
        ssh-ed25519*|ssh-rsa*|ecdsa-sha2*) : ;;
        *) die "Eso no parece una clave publica SSH: ${SSH_KEY%% *}" ;;
    esac
    PASSTHRU="$PASSTHRU --ssh-key=@/etc/coolify-setup.pub"
fi

if [ -n "$CF_TOKEN" ] || [ -n "$PASSTHRU" ]; then
    {
        printf '\n'
        printf "      - path: /etc/coolify-setup.env\n"
        printf "        owner: root:root\n"
        printf "        permissions: '0600'\n"
        printf "        content: |\n"
        [ -n "$CF_TOKEN" ] && printf "          CF_API_TOKEN=%s\n" "$CF_TOKEN"
        [ -n "$PASSTHRU" ] && printf "          SETUP_EXTRA_ARGS=%s\n" "$PASSTHRU"
        if [ -n "$SSH_KEY" ]; then
            printf '\n'
            printf "      - path: /etc/coolify-setup.pub\n"
            printf "        owner: root:root\n"
            printf "        permissions: '0644'\n"
            printf "        content: |\n"
            printf "          %s\n" "$SSH_KEY"
        fi
    } > "$TMP/envblock"
else
    : > "$TMP/envblock"
fi

# --- Ensamblado --------------------------------------------------------------
# El script se indenta 10 espacios para caber en el escalar literal de YAML.
sed 's/^/          /' "$SETUP" > "$TMP/setup.indented"
sed 's/^/          /' "$UNIT"  > "$TMP/unit.indented"

SETUP_FILE="$TMP/setup.indented" UNIT_FILE="$TMP/unit.indented" ENV_FILE="$TMP/envblock" \
awk -v kbd="$KEYBOARD" -v pw="$INSTALLER_PW_HASH" '
    $0 == "__SETUP_SH__"  { while ((getline l < ENVIRON["SETUP_FILE"]) > 0) print l; next }
    $0 == "__UNIT_FILE__" { while ((getline l < ENVIRON["UNIT_FILE"])  > 0) print l; next }
    $0 == "__ENV_FILE__"  { while ((getline l < ENVIRON["ENV_FILE"])   > 0) print l; next }
    { gsub(/__KEYBOARD__/, kbd); gsub(/__INSTALLER_PW_HASH__/, pw); print }
' "$TPL" > "$TMP/user-data"

grep -q '__SETUP_SH__\|__UNIT_FILE__\|__ENV_FILE__\|__KEYBOARD__\|__INSTALLER_PW_HASH__' \
    "$TMP/user-data" && die "Quedaron marcadores sin sustituir en user-data"

printf 'instance-id: coolify-minipc-%s\nlocal-hostname: ubuntu-tmp\n' \
    "$(date +%Y%m%d%H%M%S)" > "$TMP/meta-data"

# --- Verificacion ------------------------------------------------------------
# Si hay Python, se comprueba que el YAML es valido y que el script incrustado
# coincide byte a byte con el original. Vale la pena: un USB mal generado solo
# se descubre delante del mini PC.
if command -v python3 >/dev/null 2>&1; then
    python3 - "$TMP/user-data" "$SETUP" <<'PYEOF' || die "La verificacion del user-data generado ha fallado."
import sys
try:
    import yaml
except ImportError:
    print("  (pyyaml no instalado: se omite la validacion YAML)")
    sys.exit(0)
gen, src = sys.argv[1], sys.argv[2]
data = yaml.safe_load(open(gen))
ai = data["autoinstall"]
files = {w["path"]: w["content"] for w in ai["user-data"]["write_files"]}
assert "/usr/local/sbin/coolify-setup.sh" in files, "falta el script"
assert "/etc/systemd/system/coolify-setup.service" in files, "falta la unidad systemd"
original = open(src).read()
if files["/usr/local/sbin/coolify-setup.sh"].rstrip("\n") != original.rstrip("\n"):
    sys.exit("el script incrustado NO coincide con setup.sh")
print("  YAML valido; setup.sh incrustado identico al original")
if "/etc/coolify-setup.env" in files:
    print("  token horneado: el mini PC no preguntara nada")
PYEOF
else
    printf '  (sin python3: se omite la validacion del YAML generado)\n'
fi

mv "$TMP/user-data" "$OUT/user-data"
mv "$TMP/meta-data" "$OUT/meta-data"
chmod 600 "$OUT/user-data"

printf '\nGenerado:\n  %s\n  %s\n' "$OUT/user-data" "$OUT/meta-data"
if [ -n "$CF_TOKEN" ]; then
    printf '\n  user-data contiene el token de Cloudflare: tratalo como un secreto.\n'
fi

# --- Reempaquetado de la ISO -------------------------------------------------
# Sin esto el instalador PIDE CONFIRMACION por pantalla: subiquity solo acepta
# el autoinstall sin preguntar cuando 'autoinstall' viaja en la linea de
# comandos del kernel, y eso solo se consigue tocando el GRUB de la ISO.
# De paso metemos el cidata dentro, asi el USB es un unico dd.
if [ -n "$ISO_IN" ]; then
    [ -r "$ISO_IN" ] || die "No se puede leer la ISO: $ISO_IN"
    command -v xorriso >/dev/null 2>&1 || die "Hace falta xorriso para reempaquetar la ISO.
  Debian/Ubuntu:  sudo apt install xorriso
  macOS:          brew install xorriso
  Sin xorriso puedes seguir el camino manual de la particion CIDATA (README)."
    : "${ISO_OUT:=ubuntu-autoinstall.iso}"

    # Sin esto se destruiria la ISO de origen, que es justo lo que no se puede
    # perder: volver a bajarla son varios GB.
    if [ "$(cd "$(dirname "$ISO_IN")" && pwd)/$(basename "$ISO_IN")" \
       = "$(cd "$(dirname "$ISO_OUT")" 2>/dev/null && pwd || echo x)/$(basename "$ISO_OUT")" ]; then
        die "--iso y --iso-out apuntan al mismo fichero. Elige otra salida."
    fi
    # xorriso falla si el destino ya existe: reejecutar build-usb.sh es lo
    # normal, asi que se limpia primero.
    [ -e "$ISO_OUT" ] && { printf '  (sobrescribiendo %s)\n' "$ISO_OUT"; rm -f "$ISO_OUT"; }

    printf '\nReempaquetando %s -> %s\n' "$ISO_IN" "$ISO_OUT"
    # /cidata lleva, ademas del seed de cloud-init, los ficheros que
    # late-commands copia a /target durante la instalacion. Ese es el camino
    # principal: no depende del cloud-init del sistema destino (incidencia #1).
    mkdir -p "$TMP/cidata"
    cp "$OUT/user-data" "$OUT/meta-data" "$TMP/cidata/"
    install -m 0755 "$SETUP" "$TMP/cidata/coolify-setup.sh"
    install -m 0644 "$UNIT"  "$TMP/cidata/coolify-setup.service"
    if [ -n "$CF_TOKEN" ] || [ -n "$PASSTHRU" ]; then
        umask 077
        : > "$TMP/cidata/coolify-setup.env"
        [ -n "$CF_TOKEN" ] && printf 'CF_API_TOKEN=%s\n' "$CF_TOKEN" >> "$TMP/cidata/coolify-setup.env"
        [ -n "$PASSTHRU" ] && printf 'SETUP_EXTRA_ARGS=%s\n' "$PASSTHRU" >> "$TMP/cidata/coolify-setup.env"
        umask 022
    fi
    [ -n "$SSH_KEY" ] && printf '%s\n' "$SSH_KEY" > "$TMP/cidata/coolify-setup.pub"

    xorriso -osirrox on -indev "$ISO_IN" -extract /boot/grub/grub.cfg "$TMP/grub.cfg" 2>/dev/null \
        || die "La ISO no tiene /boot/grub/grub.cfg; no parece una Ubuntu Server reciente."
    chmod u+w "$TMP/grub.cfg"

    # 'autoinstall' evita la confirmacion; ds=nocloud apunta al cidata de la
    # ISO. El ';' se escapa porque para GRUB separa comandos.
    sed -e 's|^\([[:space:]]*linux[[:space:]]\{1,\}/casper/[a-z-]*vmlinuz\)[[:space:]]*|\1 autoinstall ds=nocloud\\;s=/cdrom/cidata/ |' \
        -e 's|^set timeout=.*|set timeout=1|' \
        "$TMP/grub.cfg" > "$TMP/grub.new"
    grep -q 'autoinstall' "$TMP/grub.new" || die "No se pudo inyectar 'autoinstall' en el grub.cfg de la ISO."
    mv "$TMP/grub.new" "$TMP/grub.cfg"

    # md5sum.txt cataloga el contenido original; hay que quitar de la lista lo
    # que acabamos de cambiar o la comprobacion de integridad fallaria.
    if xorriso -osirrox on -indev "$ISO_IN" -extract /md5sum.txt "$TMP/md5sum.txt" 2>/dev/null; then
        chmod u+w "$TMP/md5sum.txt"
        grep -v 'boot/grub/grub.cfg' "$TMP/md5sum.txt" > "$TMP/md5sum.new" || true
        mv "$TMP/md5sum.new" "$TMP/md5sum.txt"
        MD5MAP="-map $TMP/md5sum.txt /md5sum.txt"
    else
        MD5MAP=''
    fi

    # 'replay' reproduce el arranque original: la ISO sigue valiendo para BIOS
    # y para UEFI, que es lo que la hace hibrida.
    # shellcheck disable=SC2086
    xorriso -indev "$ISO_IN" -outdev "$ISO_OUT" \
        -boot_image any replay \
        -compliance no_emul_toc \
        -overwrite on \
        -map "$TMP/grub.cfg" /boot/grub/grub.cfg \
        $MD5MAP \
        -map "$TMP/cidata" /cidata >/dev/null 2>&1 \
        || die "xorriso fallo al reempaquetar la ISO."

    xorriso -osirrox on -indev "$ISO_OUT" -extract /boot/grub/grub.cfg "$TMP/verify.cfg" 2>/dev/null
    grep -q 'autoinstall ds=nocloud' "$TMP/verify.cfg" \
        || die "La ISO generada no contiene los parametros de arranque esperados."
    for f in user-data coolify-setup.sh coolify-setup.service; do
        xorriso -indev "$ISO_OUT" -lsl /cidata 2>/dev/null | grep -q "$f" \
            || die "La ISO generada no contiene /cidata/$f."
    done
    printf '  verificado: parametros de arranque y /cidata completo en la ISO\n'

    cat <<EOF

Listo. Graba la ISO en el USB y arranca el mini PC. No preguntara nada.

  Linux:  sudo dd if=$ISO_OUT of=/dev/sdX bs=4M status=progress conv=fsync
  macOS:  diskutil unmountDisk /dev/diskN && sudo dd if=$ISO_OUT of=/dev/rdiskN bs=4m
  Windows: Rufus, modo "DD Image"

Sirve igual para arranque BIOS y UEFI.
EOF
else
    cat <<EOF

Solo se han generado user-data/meta-data. Copialos a la raiz de una particion
FAT32 etiquetada CIDATA:

  Linux:  sudo mount /dev/sdX2 /mnt && sudo cp "$OUT"/user-data "$OUT"/meta-data /mnt && sudo umount /mnt
  macOS:  cp "$OUT"/user-data "$OUT"/meta-data /Volumes/CIDATA/

AVISO: por este camino el instalador se detiene a preguntar
"Continue with autoinstall? (yes|no)". Para que no pregunte nada, reempaqueta
la ISO con --iso=ubuntu-....iso
EOF
fi
