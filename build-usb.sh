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
ISO_SHA256=''
VERIFY_ISO=0
ARCH=amd64
SSH_KEY=''
RESCUE_PW=''

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'AVISO: %s\n' "$*" >&2; }

# Revision de git con la que se construye. Se hornea en el user-data para poder
# responder despues a "que version instalo este equipo". Construir fuera de un
# repositorio tambien es informacion, asi que se deja constancia.
project_version() {
    if command -v git >/dev/null 2>&1 \
       && git -C "$HERE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        _v=$(git -C "$HERE" describe --tags --always --dirty 2>/dev/null) || _v=''
        [ -n "$_v" ] && { printf '%s' "$_v"; return 0; }
    fi
    printf 'sin-git'
}
BUILD_VERSION=$(project_version)

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

VERIFICACION DE LA ISO DE ENTRADA
  Siempre se comprueba lo barato: que sea de verdad una ISO9660, que no sea la
  de escritorio (no lleva subiquity: el autoinstall no se aplicaria), que no
  este truncada y que tenga /casper y /boot/grub/grub.cfg. Ademas:

  --iso-sha256=HASH   Comprueba el SHA-256 de la ISO contra ese valor. Si no
                      cuadra, no se genera nada.
  --verify-iso        Baja SHA256SUMS y SHA256SUMS.gpg de releases.ubuntu.com,
                      valida la firma de Canonical (si hay gpg) y comprueba la
                      ISO contra la lista. Sin gpg verifica solo el hash y lo
                      dice: la lista descargada podria estar manipulada.
  --arch=ARCO         Arquitectura esperada. Por defecto: amd64

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
  --version           Imprime la revision de git que se horneara y sale.
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
        --iso-sha256=*) ISO_SHA256=$(argval "${1#*=}") ;;
        --iso-sha256)   shift; ISO_SHA256=$(argval "$1") ;;
        --verify-iso) VERIFY_ISO=1 ;;
        --arch=*)     ARCH=${1#*=} ;;
        --arch)       shift; ARCH=$1 ;;
        --rescue-password=*) RESCUE_PW=$(argval "${1#*=}") ;;
        --rescue-password)   shift; RESCUE_PW=$(argval "$1") ;;
        --ssh-key=*)  SSH_KEY=$(argval "${1#*=}") ;;
        --ssh-key)    shift; SSH_KEY=$(argval "$1") ;;
        --keyboard=*) KEYBOARD=${1#*=} ;;
        --out=*)      OUT=${1#*=} ;;
        --out)        shift; OUT=$1 ;;
        --)           shift; PASSTHRU="$*"; break ;;
        --version)    printf 'build-usb.sh %s\n' "$BUILD_VERSION"; exit 0 ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage >&2; die "Opcion desconocida: $1" ;;
    esac
    shift
done

if [ -z "$ISO_IN" ] && { [ -n "$ISO_SHA256" ] || [ "$VERIFY_ISO" = 1 ]; }; then
    die "--iso-sha256 y --verify-iso verifican la ISO de entrada, asi que
  necesitan --iso=ORIGEN.iso. Sin --iso no hay ISO que verificar."
fi

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

# Las lineas del EnvironmentFile de la unidad systemd, en UN SOLO SITIO.
# Antes se generaban en dos -el bloque write_files de aqui abajo y el /cidata
# que va dentro de la ISO- y tocar solo uno dejaba sin datos justo el camino
# que de verdad funciona en el destino: el de late-commands.
env_lines() {
    if [ -n "$CF_TOKEN" ]; then printf 'CF_API_TOKEN=%s\n' "$CF_TOKEN"; fi
    if [ -n "$PASSTHRU" ]; then printf 'SETUP_EXTRA_ARGS=%s\n' "$PASSTHRU"; fi
    # Siempre, haya token o no: es lo unico que permite saber despues con que
    # version se instalo el equipo.
    printf 'SETUP_VERSION=%s\n' "$BUILD_VERSION"
}

{
    printf '\n'
    printf "      - path: /etc/coolify-setup.env\n"
    printf "        owner: root:root\n"
    printf "        permissions: '0600'\n"
    printf "        content: |\n"
    # 10 espacios: el escalar literal de YAML donde va incrustado.
    env_lines | sed 's/^/          /'
    if [ -n "$SSH_KEY" ]; then
        printf '\n'
        printf "      - path: /etc/coolify-setup.pub\n"
        printf "        owner: root:root\n"
        printf "        permissions: '0644'\n"
        printf "        content: |\n"
        printf "          %s\n" "$SSH_KEY"
    fi
} > "$TMP/envblock"

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
env = files.get("/etc/coolify-setup.env", "")
ver = [l for l in env.splitlines() if l.startswith("SETUP_VERSION=")]
assert ver, "el user-data no hornea SETUP_VERSION"
print("  version horneada: " + ver[0].split("=", 1)[1])
if "CF_API_TOKEN=" in env:
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

# --- Verificacion de la ISO de entrada ---------------------------------------
# Toda la cadena posterior hereda la confianza de este fichero: si la ISO esta
# manipulada da igual lo demas, porque se instala un sistema comprometido y
# encima se le hornea dentro el token de Cloudflare. Estas comprobaciones
# corren ANTES de borrar la ISO de salida anterior: fallar aqui no debe
# destruir el resultado del intento previo.

# Ubuntu CD Image Automatic Signing Key: la que firma SHA256SUMS.gpg en
# releases.ubuntu.com. Va aqui a proposito, no se descarga: una clave que se
# baja del mismo sitio que la firma no demuestra nada.
UBUNTU_CD_KEY=843938DF228D22F7B3742BC0D94AA3F0EFE21092

ISO_VOLID=''
ISO_IN_SHA=''

# Se llega por dos caminos distintos (volume id y contenido de /casper), asi
# que el mensaje esta una sola vez.
DESKTOP_MSG="eso es una ISO de Ubuntu Desktop y hace falta la de Ubuntu Server.
  El escritorio no lleva subiquity, o sea que el autoinstall no se aplica: el
  instalador ignoraria por completo el user-data generado.
  Descarga la de servidor: https://ubuntu.com/download/server"

# SHA-256 de un fichero. Se prueban varias herramientas porque ninguna esta
# garantizada: sha256sum es de coreutils (no viene en macOS), shasum llega con
# Perl y openssl no siempre esta. Devuelve 1 si no hay ninguna, para que quien
# llame decida si eso es fatal o solo una molestia.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$1" <<'PYEOF'
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], 'rb') as f:
    for chunk in iter(lambda: f.read(1 << 20), b''):
        h.update(chunk)
print(h.hexdigest())
PYEOF
    else
        return 1
    fi
}

fetch_url() { # fetch_url URL DESTINO
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 120 -o "$2" -- "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 120 -O "$2" -- "$1"
    else
        return 127
    fi
}

# --verify-iso: comprueba la ISO contra la lista oficial de Canonical.
verify_from_ubuntu() { # verify_from_ubuntu VERSION
    v_ver=$1
    [ -n "$v_ver" ] || die "--verify-iso no sabe que version de Ubuntu buscar:
  el volume id de la ISO ('$ISO_VOLID') no lleva un numero de version.
  Usa --iso-sha256=HASH con el valor que publica Canonical."
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        die "--verify-iso necesita curl o wget para bajar SHA256SUMS.
  Sin red, verifica a mano y pasa --iso-sha256=HASH."
    fi

    # releases.ubuntu.com solo conserva el ultimo punto de cada serie, y a
    # veces bajo el nombre de la serie. Se prueban los dos.
    v_series=${v_ver%.*}
    case "$v_series" in *.*) : ;; *) v_series=$v_ver ;; esac
    v_base=''
    for u in "https://releases.ubuntu.com/$v_ver" "https://releases.ubuntu.com/$v_series"; do
        if fetch_url "$u/SHA256SUMS" "$TMP/SHA256SUMS"; then v_base=$u; break; fi
    done
    [ -n "$v_base" ] || die "No se ha podido descargar SHA256SUMS de Ubuntu $v_ver.
  Puede que esa version ya no este en releases.ubuntu.com, o que no haya red.
  Verifica a mano y pasa --iso-sha256=HASH."

    # Firma. Sin gpg (o sin la clave) se sigue, pero diciendolo en claro.
    v_sig=0
    v_why='no hay gpg instalado'
    if fetch_url "$v_base/SHA256SUMS.gpg" "$TMP/SHA256SUMS.gpg"; then
        if command -v gpg >/dev/null 2>&1; then
            v_home="$TMP/gnupg"
            mkdir -p "$v_home"
            chmod 700 "$v_home"
            v_src=''
            # Primero el llavero del usuario; si no esta, el keyserver. Nunca
            # se escribe en el llavero del usuario: todo va al temporal.
            if gpg --batch --export "$UBUNTU_CD_KEY" > "$TMP/cdkey.gpg" 2>/dev/null \
               && [ -s "$TMP/cdkey.gpg" ]; then
                v_src='tu llavero'
            elif gpg --homedir "$v_home" --batch --keyserver hkps://keyserver.ubuntu.com \
                     --recv-keys "$UBUNTU_CD_KEY" >/dev/null 2>&1 \
                 && gpg --homedir "$v_home" --batch --export "$UBUNTU_CD_KEY" \
                     > "$TMP/cdkey.gpg" 2>/dev/null && [ -s "$TMP/cdkey.gpg" ]; then
                v_src='keyserver.ubuntu.com'
            else
                v_why='no se ha podido obtener la clave de Canonical'
            fi
            if [ -n "$v_src" ]; then
                gpg --homedir "$v_home" --batch --import "$TMP/cdkey.gpg" >/dev/null 2>&1 || true
                if gpg --homedir "$v_home" --batch --status-fd 1 --verify \
                       "$TMP/SHA256SUMS.gpg" "$TMP/SHA256SUMS" > "$TMP/gpg.status" 2>/dev/null \
                   && grep '^\[GNUPG:\] VALIDSIG' "$TMP/gpg.status" | grep -q "$UBUNTU_CD_KEY"; then
                    printf '  firma de Canonical verificada (clave %s, via %s)\n' \
                        "$UBUNTU_CD_KEY" "$v_src"
                    v_sig=1
                else
                    die "La firma de SHA256SUMS NO valida contra la clave de Canonical
  ($UBUNTU_CD_KEY). O la descarga esta manipulada, o el fichero llego roto.
  No se sigue: verificar el hash contra una lista que no es de fiar no sirve."
                fi
            fi
        fi
    else
        v_why='no se ha podido descargar SHA256SUMS.gpg'
    fi
    if [ "$v_sig" = 0 ]; then
        warn "NO se ha comprobado la firma de SHA256SUMS: $v_why.
  Se verifica solo el hash contra la lista descargada, y esa lista PODRIA
  ESTAR MANIPULADA: quien pueda alterar la ISO por el camino puede alterar
  tambien la lista. Instala gpg y repite para tener la cadena completa."
    fi

    # Se busca por hash, no por nombre: la ISO local puede estar renombrada y
    # aun asi ser la buena. El nombre lo dice la propia lista.
    if v_line=$(grep -i "^${ISO_IN_SHA}[[:space:]]" "$TMP/SHA256SUMS"); then
        v_name=${v_line##* }
        v_name=${v_name#\*}
        printf '  la ISO coincide con la publicada por Canonical: %s\n' "$v_name"
        case "$v_name" in
            *live-server*) : ;;
            *) warn "Pero '$v_name' no es una imagen live-server: el autoinstall
  solo funciona con la de servidor." ;;
        esac
    else
        # Ojo: el SHA256SUMS de un punto de serie lista tambien el punto
        # anterior, asi que primero se busca el nombre exacto de esta version.
        v_want=$(grep -iE "ubuntu-$v_ver-live-server-$ARCH\.iso\$" "$TMP/SHA256SUMS" \
                 | awk '{print $1}' | head -1)
        [ -n "$v_want" ] || v_want=$(grep -iE "live-server-$ARCH\.iso\$" "$TMP/SHA256SUMS" \
                 | awk '{print $1}' | tail -1)
        die "El SHA-256 de la ISO no aparece en el SHA256SUMS de Ubuntu $v_ver.
  Calculado:  $ISO_IN_SHA
  Publicado:  ${v_want:-(no hay imagen live-server-$ARCH en esa lista)}
  Esa ISO no es la que publica Canonical. No se genera nada."
    fi
}

# Cordura de la ISO de entrada. Lo barato primero: un fichero que no es una
# ISO o una descarga truncada mueren sin gastar minutos en calcular hashes.
iso_sanity() {
    # 1. ISO9660: el descriptor primario lleva 'CD001' en el offset 32769. Con
    #    esto caen los ficheros que no son ISO y las descargas truncadas de
    #    menos de 32 KiB, sin necesitar xorriso.
    s_magic=$(dd if="$ISO_IN" bs=1 skip=32769 count=5 2>/dev/null | tr -d '\0')
    [ "$s_magic" = "CD001" ] || die "$ISO_IN no es una imagen ISO9660.
  En el offset 32769 deberia estar la marca 'CD001' y hay [$s_magic].
  Comprueba que has bajado la ISO entera y que no es un HTML de error."

    # 2. Volume id (offset 32808, 32 bytes). En la oficial vale
    #    'Ubuntu-Server 24.04.4 LTS amd64': dice edicion, version y arquitectura.
    ISO_VOLID=$(dd if="$ISO_IN" bs=1 skip=32808 count=32 2>/dev/null \
                | tr -d '\0' | sed 's/[[:space:]]*$//')
    s_vol=$(printf '%s' "$ISO_VOLID" | tr 'A-Z' 'a-z')
    s_arch=$(printf '%s' "$ARCH" | tr 'A-Z' 'a-z')
    case "$s_vol" in
        *desktop*) die "$DESKTOP_MSG
  (volume id: '$ISO_VOLID')" ;;
        *server*)  : ;;
        # Las de escritorio se llaman 'Ubuntu 24.04.4 LTS amd64', sin 'Server'.
        *ubuntu*)  die "$DESKTOP_MSG
  (volume id: '$ISO_VOLID', no dice 'Server')" ;;
        *) warn "El volume id de la ISO ('$ISO_VOLID') no parece de Ubuntu.
  Se sigue, pero el reempaquetado esta pensado para Ubuntu Server." ;;
    esac
    case "$s_vol" in
        *"$s_arch"*) : ;;
        *) warn "El volume id ('$ISO_VOLID') no menciona la arquitectura '$ARCH'.
  Si el mini PC no es de esa arquitectura, no arrancara. Usa --arch para
  cambiar lo que se espera." ;;
    esac

    # 3. Tamano. 'stat' no se puede usar: sus opciones difieren entre GNU y BSD.
    #    Por debajo de 1 GiB no hay ninguna Ubuntu Server: es una descarga a
    #    medias. Entre 1 y 2 GiB solo se avisa, porque las series antiguas
    #    andaban por ahi.
    s_bytes=$(ls -l "$ISO_IN" | awk '{print $5}')
    case "$s_bytes" in ''|*[!0-9]*) s_bytes=0 ;; esac
    if awk -v n="$s_bytes" 'BEGIN{exit !(n < 1073741824)}'; then
        die "La ISO ocupa $s_bytes bytes: ninguna Ubuntu Server baja del giga.
  La descarga se ha quedado a medias. Bajala otra vez."
    elif awk -v n="$s_bytes" 'BEGIN{exit !(n < 2147483648)}'; then
        warn "La ISO ocupa $s_bytes bytes, menos de los ~2,5 GB de una Ubuntu
  Server reciente. Puede estar incompleta."
    fi

    # 4. Contenido, con el mismo xorriso que hace falta para reempaquetar. El
    #    grub.cfg se extrae aqui, no despues: asi la ISO de salida anterior
    #    sigue intacta si esto falla. La exigencia de xorriso va aqui y no
    #    antes para que lo barato (que no sea una ISO, que sea la de
    #    escritorio) se detecte igual en un equipo sin xorriso.
    command -v xorriso >/dev/null 2>&1 || die "Hace falta xorriso para reempaquetar la ISO.
  Debian/Ubuntu:  sudo apt install xorriso
  macOS:          brew install xorriso
  Sin xorriso puedes seguir el camino manual de la particion CIDATA (README)."
    xorriso -osirrox on -indev "$ISO_IN" -extract /boot/grub/grub.cfg "$TMP/grub.cfg" 2>/dev/null \
        || die "La ISO no tiene /boot/grub/grub.cfg; no parece una Ubuntu Server reciente."
    xorriso -indev "$ISO_IN" -lsl /casper > "$TMP/casper.ls" 2>/dev/null || true
    grep -q 'vmlinuz' "$TMP/casper.ls" \
        || die "La ISO no tiene /casper/vmlinuz: no es una imagen live de Ubuntu."
    if grep -q 'ubuntu-server-minimal\.squashfs' "$TMP/casper.ls"; then
        :
    elif grep -qE '(^|[^A-Za-z0-9._-])(filesystem|minimal)\.squashfs' "$TMP/casper.ls"; then
        die "$DESKTOP_MSG
  (en /casper hay el squashfs del escritorio, no ubuntu-server-minimal.squashfs)"
    else
        warn "No se reconoce el contenido de /casper: falta
  ubuntu-server-minimal.squashfs. Se sigue, pero esto no parece una imagen
  de Ubuntu Server."
    fi

    # 5. Hashes. Lo que se pide por argumento se valida antes de calcular
    #    nada: hashear varios GB para luego descubrir que el hash esperado
    #    estaba mal escrito es tiempo tirado.
    s_want=''
    if [ -n "$ISO_SHA256" ]; then
        s_want=$(printf '%s' "$ISO_SHA256" | tr 'A-Z' 'a-z')
        case "$s_want" in
            ????????????????????????????????????????????????????????????????) : ;;
            *) die "--iso-sha256 espera 64 digitos hexadecimales y ha recibido
  [$ISO_SHA256]." ;;
        esac
        case "$s_want" in
            *[!0-9a-f]*) die "--iso-sha256 no es hexadecimal: [$ISO_SHA256]." ;;
        esac
    fi

    # Se calcula una sola vez y se reutiliza: son varios GB.
    if ISO_IN_SHA=$(sha256_of "$ISO_IN"); then
        case "$ISO_IN_SHA" in
            ????????????????????????????????????????????????????????????????) : ;;
            *) ISO_IN_SHA='' ;;
        esac
    else
        ISO_IN_SHA=''
    fi

    if [ -n "$s_want" ]; then
        # Sin herramienta no se degrada a silencio: han pedido verificar.
        [ -n "$ISO_IN_SHA" ] || die "Has pedido --iso-sha256 y en este equipo no hay
  con que calcular un SHA-256 (sha256sum, shasum, openssl o python3).
  Instala una de esas y repite: verificar a medias es no verificar."
        [ "$ISO_IN_SHA" = "$s_want" ] || die "El SHA-256 de la ISO NO coincide.
  Esperado: $s_want
  Obtenido: $ISO_IN_SHA
  O la descarga esta corrupta o la ISO no es la que crees. No se genera nada."
        printf '  sha256 de la ISO de entrada verificado contra --iso-sha256\n'
    fi

    if [ "$VERIFY_ISO" = 1 ]; then
        [ -n "$ISO_IN_SHA" ] || die "Has pedido --verify-iso y en este equipo no hay
  con que calcular un SHA-256 (sha256sum, shasum, openssl o python3)."
        s_ver=''
        for w in $ISO_VOLID; do
            case "$w" in
                [0-9][0-9].[0-9][0-9]|[0-9][0-9].[0-9][0-9].[0-9]*) s_ver=$w; break ;;
            esac
        done
        verify_from_ubuntu "$s_ver"
    fi

    if [ -n "$ISO_IN_SHA" ]; then
        printf '  ISO de entrada: %s\n  sha256:         %s\n' "$ISO_VOLID" "$ISO_IN_SHA"
    else
        warn "No hay ninguna herramienta de SHA-256 en este equipo: no se puede
  dejar constancia de que ISO ha salido este USB."
    fi
}

# --- Reempaquetado de la ISO -------------------------------------------------
# Sin esto el instalador PIDE CONFIRMACION por pantalla: subiquity solo acepta
# el autoinstall sin preguntar cuando 'autoinstall' viaja en la linea de
# comandos del kernel, y eso solo se consigue tocando el GRUB de la ISO.
# De paso metemos el cidata dentro, asi el USB es un unico dd.
if [ -n "$ISO_IN" ]; then
    [ -r "$ISO_IN" ] || die "No se puede leer la ISO: $ISO_IN"

    printf '\nComprobando %s\n' "$ISO_IN"
    iso_sanity

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
    # El MISMO env_lines que el bloque write_files. Si aqui se generase aparte,
    # cualquier cosa que se anadiese alli no llegaria por este camino, que es
    # el principal.
    umask 077
    env_lines > "$TMP/cidata/coolify-setup.env"
    umask 022
    [ -n "$SSH_KEY" ] && printf '%s\n' "$SSH_KEY" > "$TMP/cidata/coolify-setup.pub"

    # El grub.cfg ya lo extrajo iso_sanity, antes de tocar nada.
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

    # Trazabilidad: con estos dos hashes se sabe que USB salio de que imagen.
    ISO_OUT_SHA=$(sha256_of "$ISO_OUT") || ISO_OUT_SHA=''
    if [ -n "$ISO_IN_SHA" ] || [ -n "$ISO_OUT_SHA" ]; then
        printf '\nsha256\n  entrada (%s): %s\n  salida  (%s): %s\n' \
            "$ISO_IN"  "${ISO_IN_SHA:-(no calculado)}" \
            "$ISO_OUT" "${ISO_OUT_SHA:-(no calculado)}"
    fi

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
