#!/bin/sh
# setup.sh — Docker + Coolify + Cloudflare Tunnel, desatendido y portable.
#
# Filosofía: no molestar al usuario con nada que se pueda derivar, obtener por
# API o generar. Lo que quede se acepta por línea de comandos o variable de
# entorno; y solo si aun así falta y hay terminal, se pregunta por pantalla.
#
# En la práctica el único dato irreducible es el API Token de Cloudflare.
#
#   sh setup.sh --cf-token=@/ruta/token      # cero interacción
#   CF_API_TOKEN=xxx sh setup.sh             # cero interacción
#   sh setup.sh                              # pregunta solo el token
#
# POSIX sh: funciona en dash, ash/busybox, bash, ksh, y el sh de *BSD/macOS.
# Las dependencias que falten (jq) se descargan a un directorio de trabajo y se
# usan desde ahí, sin instalarse en el sistema.

set -eu

VERSION="2.0"
UA="coolify-setup/$VERSION"

# ============================================================================
# Rutas de estado y trabajo
# ============================================================================

if [ "$(id -u)" = "0" ]; then
    STATE_DIR=/var/lib/coolify-setup
    LOG_FILE=/var/log/coolify-setup.log
    SUMMARY_FILE=/root/instalacion-resumen.txt
    CREDS_FILE=/root/instalacion-credenciales.txt
else
    STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/coolify-setup"
    LOG_FILE="$STATE_DIR/setup.log"
    SUMMARY_FILE="$HOME/instalacion-resumen.txt"
    CREDS_FILE="$HOME/instalacion-credenciales.txt"
fi
# Lo escribe el 'late-commands' del autoinstall y es de donde el servicio saca
# el token al reintentar. Se borra solo al completar con exito.
SETUP_ENV_FILE=/etc/coolify-setup.env
WORK_DIR="$STATE_DIR/work"      # dependencias descargadas, no instaladas
DONE_MARKER="$STATE_DIR/completed"

# ============================================================================
# Salida y registro
# ============================================================================

# Se mira stderr, que es por donde sale el diagnóstico coloreado.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$(printf '\033[0m'); C_BOLD=$(printf '\033[1m')
    C_RED=$(printf '\033[31m');  C_GREEN=$(printf '\033[32m')
    C_YELLOW=$(printf '\033[33m'); C_BLUE=$(printf '\033[34m')
    C_DIM=$(printf '\033[2m')
else
    C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Escribe en el log siempre; en pantalla con formato.
_logfile() {
    [ -n "${LOG_READY:-}" ] || return 0
    printf '[%s] %s\n' "$(_ts)" "$*" >> "$LOG_FILE"
}
# TODO el diagnóstico va a stderr, nunca a stdout. Estas funciones se acaban
# llamando desde dentro de sustituciones de comandos (json_get -> setup_json
# puede tener que descargar jq), y un mensaje de progreso colado en stdout se
# convertiría silenciosamente en parte del valor capturado.
# stdout queda reservado para datos: solo el resumen final.
log()   { _logfile "$*"; printf '%s\n' "$*" >&2; }
info()  { _logfile "INFO: $*";  printf '%s==>%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$*" >&2; }
ok()    { _logfile "OK: $*";    printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn()  { _logfile "WARN: $*";  printf '%s  !!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
note()  { _logfile "NOTE: $*";  printf '%s     %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }
err()   { _logfile "ERROR: $*"; printf '%s ERR%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; }

die() {
    err "$*"
    [ -n "${LOG_READY:-}" ] && printf '%s\n' "Log completo: $LOG_FILE" >&2
    exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# Borra un fichero sobrescribiéndolo antes si el sistema trae shred. Aviso:
# sobre SSD, COW o sistemas con journal, sobrescribir no garantiza nada — el
# bloque original puede seguir vivo. Es una mejora, no una promesa.
wipe_file() {
    [ -n "${1:-}" ] && [ -e "$1" ] || return 0
    if have shred && shred -u "$1" 2>/dev/null; then
        return 0
    fi
    rm -f "$1"
    return 0
}

# ============================================================================
# Argumentos
# ============================================================================

usage() {
    cat <<EOF
setup.sh $VERSION — Docker + Coolify + Cloudflare Tunnel, desatendido.

Uso: sh setup.sh [opciones]

Todo valor omitido se deriva, se obtiene por API o se genera. Lo único que no
se puede derivar es el API Token de Cloudflare: pásalo o se preguntará.

CLOUDFLARE
  --cf-token=VALOR       API Token con Zone:DNS:Edit + Zone:Zone:Read.
                         Acepta @/ruta/fichero o @- para leer de stdin.
                         Alternativa: variable de entorno CF_API_TOKEN.
  --domain=DOMINIO       Dominio raíz. Por defecto: se descubre vía API; si el
                         token cubre una sola zona se usa esa sin preguntar.
  --app-subdomain=SUB    Subdominio comodín para las apps. Por defecto: app
  --coolify-subdomain=S  Subdominio del panel de Coolify. Por defecto: coolify

SISTEMA (todo opcional, todo derivado o generado si se omite)
  --hostname=NOMBRE      Por defecto: primera etiqueta del dominio.
  --admin-user=USUARIO   Por defecto: SUDO_USER, o el primer usuario con sudo,
                         o se crea 'admin'.
  --admin-password=V     Por defecto: se genera. Acepta @fichero / @-.
  --ssh-key=VALOR        Clave pública SSH. Acepta @fichero. Si se indica, se
                         deshabilita la autenticación por contraseña.
  --timezone=TZ          Por defecto: la del sistema; si el sistema está en UTC,
                         se deduce por geolocalización de la IP (ver --no-geoip).
  --no-geoip             No consultar nunca ipapi.co para deducir la zona
                         horaria: si el sistema no la tiene, se queda en UTC.
                         Equivale a la variable de entorno NO_GEOIP=1.
  --wifi-ssid=SSID       Solo se usa (y se pregunta) si no hay red al arrancar.
  --wifi-password=V      Acepta @fichero / @-.

COOLIFY
  --coolify-email=MAIL   Por defecto: se deduce de la cuenta CF, o admin@dominio
  --coolify-password=V   Por defecto: se genera. Acepta @fichero / @-.

CONTROL
  -y, --yes              No pedir confirmación final.
  --non-interactive      Fallar en vez de preguntar si falta algún dato.
  --skip-docker          No instalar Docker.
  --skip-coolify         No instalar Coolify.
  --skip-tunnel          No crear el túnel de Cloudflare.
  --reset                Olvidar el estado previo y empezar de cero.
  --keep-secrets         No borrar al terminar los ficheros con el token de
                         Cloudflare, el del túnel y la configuración resuelta.
  --summary-no-secrets   No imprimir contraseñas por pantalla al terminar; se
                         quedan solo en el fichero de credenciales.
  --dry-run              Mostrar la configuración resuelta y salir.
  -h, --help             Esta ayuda.

SEGURIDAD
  Los secretos pasados como --flag=valor son visibles en 'ps'. Prefiere las
  variables de entorno o la forma @/ruta/fichero.
EOF
}

# Lee el valor de un argumento que puede ser literal, @fichero o @- (stdin).
argval() {
    case "$1" in
        @-) cat ;;
        @*) f=${1#@}; [ -r "$f" ] || die "No se puede leer el fichero: $f"; cat "$f" ;;
        *)  printf '%s' "$1" ;;
    esac
}

CF_TOKEN="${CF_API_TOKEN:-}"
ROOT_DOMAIN=''; APP_SUBDOMAIN=''; COOLIFY_SUBDOMAIN=''
NEW_HOSTNAME=''; ADMIN_USER=''; ADMIN_PASSWORD=''; SSH_KEY=''; TIMEZONE=''
TIMEZONE_SOURCE=''
WIFI_SSID=''; WIFI_PASSWORD=''
COOLIFY_EMAIL=''; COOLIFY_PASSWORD=''
ASSUME_YES=''; NON_INTERACTIVE=''; DRY_RUN=''
NO_GEOIP="${NO_GEOIP:-}"
SKIP_DOCKER=''; SKIP_COOLIFY=''; SKIP_TUNNEL=''; DO_RESET=''
KEEP_SECRETS=''; SUMMARY_NO_SECRETS=''

# Argumentos horneados en el USB al construirlo (via EnvironmentFile del
# servicio systemd). Van delante para que lo que se pase a mano los pueda pisar.
# La division en palabras aqui es intencionada.
if [ -n "${SETUP_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2086
    set -- $SETUP_EXTRA_ARGS "$@"
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --cf-token=*)           CF_TOKEN=$(argval "${1#*=}") ;;
        --cf-token)             shift; CF_TOKEN=$(argval "$1") ;;
        --domain=*)             ROOT_DOMAIN=${1#*=} ;;
        --domain)               shift; ROOT_DOMAIN=$1 ;;
        --app-subdomain=*)      APP_SUBDOMAIN=${1#*=} ;;
        --app-subdomain)        shift; APP_SUBDOMAIN=$1 ;;
        --coolify-subdomain=*)  COOLIFY_SUBDOMAIN=${1#*=} ;;
        --coolify-subdomain)    shift; COOLIFY_SUBDOMAIN=$1 ;;
        --hostname=*)           NEW_HOSTNAME=${1#*=} ;;
        --hostname)             shift; NEW_HOSTNAME=$1 ;;
        --admin-user=*)         ADMIN_USER=${1#*=} ;;
        --admin-user)           shift; ADMIN_USER=$1 ;;
        --admin-password=*)     ADMIN_PASSWORD=$(argval "${1#*=}") ;;
        --admin-password)       shift; ADMIN_PASSWORD=$(argval "$1") ;;
        --ssh-key=*)            SSH_KEY=$(argval "${1#*=}") ;;
        --ssh-key)              shift; SSH_KEY=$(argval "$1") ;;
        --timezone=*)           TIMEZONE=${1#*=}; TIMEZONE_SOURCE=indicada ;;
        --timezone)             shift; TIMEZONE=$1; TIMEZONE_SOURCE=indicada ;;
        --wifi-ssid=*)          WIFI_SSID=${1#*=} ;;
        --wifi-ssid)            shift; WIFI_SSID=$1 ;;
        --wifi-password=*)      WIFI_PASSWORD=$(argval "${1#*=}") ;;
        --wifi-password)        shift; WIFI_PASSWORD=$(argval "$1") ;;
        --coolify-email=*)      COOLIFY_EMAIL=${1#*=} ;;
        --coolify-email)        shift; COOLIFY_EMAIL=$1 ;;
        --coolify-password=*)   COOLIFY_PASSWORD=$(argval "${1#*=}") ;;
        --coolify-password)     shift; COOLIFY_PASSWORD=$(argval "$1") ;;
        -y|--yes)               ASSUME_YES=1 ;;
        --non-interactive)      NON_INTERACTIVE=1; ASSUME_YES=1 ;;
        --no-geoip)             NO_GEOIP=1 ;;
        --skip-docker)          SKIP_DOCKER=1 ;;
        --skip-coolify)         SKIP_COOLIFY=1 ;;
        --skip-tunnel)          SKIP_TUNNEL=1 ;;
        --reset)                DO_RESET=1 ;;
        --keep-secrets)         KEEP_SECRETS=1 ;;
        --summary-no-secrets)   SUMMARY_NO_SECRETS=1 ;;
        --dry-run)              DRY_RUN=1 ;;
        -h|--help)              usage; exit 0 ;;
        *) usage >&2; die "Opción desconocida: $1" ;;
    esac
    shift
done

# Los valores por defecto se aplican más abajo, tras recuperar la configuración
# de un intento anterior: si no, taparían lo que el usuario eligió esa vez.

# ============================================================================
# Arranque: estado, log, plataforma
# ============================================================================

[ -n "$DO_RESET" ] && rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR"
chmod 700 "$STATE_DIR"
: > "$LOG_FILE" 2>/dev/null || LOG_FILE="$STATE_DIR/setup.log"
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
LOG_READY=1

if [ -f "$DONE_MARKER" ] && [ -z "$DRY_RUN" ]; then
    log "Ya completado anteriormente. Usa --reset para volver a ejecutar."
    exit 0
fi

_logfile "=== setup.sh $VERSION arrancando (pid $$) ==="

OS=$(uname -s)
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)   ARCH_N=amd64 ;;
    aarch64|arm64)  ARCH_N=arm64 ;;
    armv7l|armv7)   ARCH_N=arm ;;
    *)              ARCH_N=$ARCH ;;
esac
case "$OS" in
    Linux)  OS_N=linux ;;
    Darwin) OS_N=darwin ;;
    FreeBSD|OpenBSD|NetBSD) OS_N=$(printf '%s' "$OS" | tr 'A-Z' 'a-z') ;;
    *)      OS_N=$(printf '%s' "$OS" | tr 'A-Z' 'a-z') ;;
esac
IS_ROOT=''; [ "$(id -u)" = "0" ] && IS_ROOT=1
HAS_SYSTEMD=''; [ -d /run/systemd/system ] && HAS_SYSTEMD=1

_logfile "Plataforma: $OS/$ARCH ($OS_N/$ARCH_N) root=${IS_ROOT:-no} systemd=${HAS_SYSTEMD:-no}"

# ============================================================================
# Capa HTTP: curl > wget > python3
# ============================================================================

HTTP=''
if   have curl;    then HTTP=curl
elif have wget;    then HTTP=wget
elif have python3; then HTTP=python3
elif have python;  then HTTP=python
else die "Se necesita curl, wget o python para continuar y no hay ninguno."
fi
_logfile "Cliente HTTP: $HTTP"

# fetch_stdout URL  -> cuerpo por stdout, !=0 si falla
fetch_stdout() {
    case "$HTTP" in
        curl) curl -fsSL -A "$UA" --connect-timeout 15 --max-time 300 "$1" ;;
        wget) wget -qO- -U "$UA" --timeout=30 "$1" ;;
        *)    "$HTTP" - "$1" <<'PYEOF'
import sys, urllib.request
req = urllib.request.Request(sys.argv[1], headers={'User-Agent': 'coolify-setup'})
sys.stdout.write(urllib.request.urlopen(req, timeout=60).read().decode('utf-8', 'replace'))
PYEOF
        ;;
    esac
}

# fetch_file URL DESTINO
fetch_file() {
    case "$HTTP" in
        curl) curl -fsSL -A "$UA" --connect-timeout 15 --max-time 600 -o "$2" "$1" ;;
        wget) wget -qO "$2" -U "$UA" --timeout=60 "$1" ;;
        *)    "$HTTP" - "$1" "$2" <<'PYEOF'
import sys, urllib.request
req = urllib.request.Request(sys.argv[1], headers={'User-Agent': 'coolify-setup'})
with urllib.request.urlopen(req, timeout=120) as r, open(sys.argv[2], 'wb') as f:
    f.write(r.read())
PYEOF
        ;;
    esac
}

# ============================================================================
# JSON: jq del sistema > python3 > jq descargado al workdir
# ============================================================================

JQ=''
JSON_MODE=''
PY=''
if   have python3; then PY=python3
elif have python;  then PY=python
fi

setup_json() {
    [ -n "$JSON_MODE" ] && return 0
    if have jq; then
        JQ=$(command -v jq); JSON_MODE=jq
    elif [ -n "$PY" ]; then
        JSON_MODE=py
    elif [ -x "$WORK_DIR/jq" ]; then
        JQ="$WORK_DIR/jq"; JSON_MODE=jq
    else
        # Descargar jq al directorio de trabajo. No se instala en el sistema.
        jq_plat=""
        case "$OS_N/$ARCH_N" in
            linux/amd64)  jq_plat=jq-linux-amd64 ;;
            linux/arm64)  jq_plat=jq-linux-arm64 ;;
            darwin/amd64) jq_plat=jq-macos-amd64 ;;
            darwin/arm64) jq_plat=jq-macos-arm64 ;;
        esac
        [ -n "$jq_plat" ] || die "Sin jq ni python disponibles y no hay binario de jq para $OS_N/$ARCH_N."
        info "Descargando jq a $WORK_DIR (uso temporal, no se instala)"
        fetch_file "https://github.com/jqlang/jq/releases/download/jq-1.7.1/$jq_plat" "$WORK_DIR/jq" \
            || die "No se pudo descargar jq."
        chmod +x "$WORK_DIR/jq"
        JQ="$WORK_DIR/jq"; JSON_MODE=jq
    fi
    _logfile "Motor JSON: $JSON_MODE"
}

# json_get RUTA  — lee JSON de stdin, imprime el valor o cadena vacía.
# RUTA en notación de punto con índices: .result[0].id
# Nota: el programa de Python se pasa con -c, NO por stdin (`python -`), porque
# stdin lo necesitamos libre para el JSON de entrada.
JSON_PY='
import sys, json, re
path = sys.argv[1]
try:
    cur = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for key, idx in re.findall(r"\.([A-Za-z_][A-Za-z0-9_]*)|\[(\d+)\]", path):
    try:
        cur = cur[key] if key else cur[int(idx)]
    except Exception:
        sys.exit(0)
if cur is None:
    sys.exit(0)
if isinstance(cur, bool):
    print("true" if cur else "false")
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur))
else:
    print(cur)
'

json_get() {
    setup_json
    if [ "$JSON_MODE" = jq ]; then
        # Sin "// empty": ese operador de jq trata false como vacío, y
        # necesitamos distinguir false de ausente en .success.
        _jv=$("$JQ" -r "$1" 2>/dev/null) || return 0
        [ "$_jv" = "null" ] && return 0
        printf '%s\n' "$_jv"
    else
        "$PY" -c "$JSON_PY" "$1" 2>/dev/null || true
    fi
    return 0
}

# Escapa una cadena para incrustarla en un literal JSON.
json_escape() {
    printf '%s' "$1" \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | tr -d '\n\r\t'
}

# ============================================================================
# API de Cloudflare
# ============================================================================

# Sobrescribible con CF_API_BASE para pruebas contra un servidor simulado.
CF_API="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"

# cf_api METODO RUTA [CUERPO]  -> JSON por stdout
cf_api() {
    cf_m=$1; cf_p=$2; cf_b=${3:-}
    case "$HTTP" in
        curl)
            if [ -n "$cf_b" ]; then
                curl -sS -X "$cf_m" "$CF_API$cf_p" \
                    -H "Authorization: Bearer $CF_TOKEN" \
                    -H "Content-Type: application/json" \
                    -A "$UA" --connect-timeout 15 --max-time 120 --data "$cf_b"
            else
                curl -sS -X "$cf_m" "$CF_API$cf_p" \
                    -H "Authorization: Bearer $CF_TOKEN" \
                    -H "Content-Type: application/json" \
                    -A "$UA" --connect-timeout 15 --max-time 120
            fi
            ;;
        wget)
            if [ -n "$cf_b" ]; then
                wget -qO- --method="$cf_m" \
                    --header="Authorization: Bearer $CF_TOKEN" \
                    --header="Content-Type: application/json" \
                    --body-data="$cf_b" "$CF_API$cf_p"
            else
                wget -qO- --method="$cf_m" \
                    --header="Authorization: Bearer $CF_TOKEN" \
                    --header="Content-Type: application/json" \
                    "$CF_API$cf_p"
            fi
            ;;
        *)
            CF_TOKEN="$CF_TOKEN" "$HTTP" - "$cf_m" "$CF_API$cf_p" "$cf_b" <<'PYEOF'
import sys, os, urllib.request, urllib.error
method, url, body = sys.argv[1], sys.argv[2], sys.argv[3]
data = body.encode() if body else None
req = urllib.request.Request(url, data=data, method=method, headers={
    'Authorization': 'Bearer ' + os.environ['CF_TOKEN'],
    'Content-Type': 'application/json',
    'User-Agent': 'coolify-setup'})
try:
    sys.stdout.write(urllib.request.urlopen(req, timeout=60).read().decode())
except urllib.error.HTTPError as e:
    sys.stdout.write(e.read().decode())
PYEOF
            ;;
    esac
}

# Ejecuta una llamada y falla con el mensaje de error de Cloudflare si no fue OK.
cf_call() {
    cf_out=$(cf_api "$@" 2>/dev/null) || { err "Fallo de red llamando a la API de Cloudflare"; return 1; }
    if [ "$(printf '%s' "$cf_out" | json_get '.success')" != "true" ]; then
        cf_msg=$(printf '%s' "$cf_out" | json_get '.errors[0].message')
        err "Cloudflare rechazó $1 $2: ${cf_msg:-respuesta inesperada}"
        _logfile "Respuesta completa: $cf_out"
        return 1
    fi
    printf '%s' "$cf_out"
}

# ============================================================================
# Interfaz de usuario: whiptail/dialog si existen, si no lectura por terminal
# ============================================================================

UI=''
if   have whiptail; then UI=whiptail
elif have dialog;   then UI=dialog
else UI=plain
fi

# De dónde leer las respuestas. Con `curl ... | sh` stdin es el propio script,
# así que hay que abrir la terminal de control explícitamente o no se podría
# preguntar nada en el caso de uso más habitual.
TTY_DEV=''
if [ -t 0 ]; then
    TTY_DEV=/dev/stdin
elif ( : < /dev/tty ) 2>/dev/null; then
    TTY_DEV=/dev/tty
fi
[ -n "$TTY_DEV" ] || UI=none
[ -n "$NON_INTERACTIVE" ] && UI=none
_logfile "Interfaz: $UI (tty: ${TTY_DEV:-ninguna})"

BT="Instalación desatendida — Coolify"

ui_msg() {
    case "$UI" in
        whiptail|dialog) "$UI" --backtitle "$BT" --msgbox "$1" 12 72 < "$TTY_DEV" ;;
        *) printf '\n%s\n\n' "$1" ;;
    esac
}

# ui_input ETIQUETA DEFECTO -> valor por stdout
ui_input() {
    case "$UI" in
        whiptail|dialog)
            "$UI" --backtitle "$BT" --inputbox "$1" 11 72 "$2" 3>&1 1>&2 2>&3 < "$TTY_DEV"
            ;;
        plain)
            _p=$(printf '%s' "$1" | sed 's/:$//')
            if [ -n "$2" ]; then printf '%s [%s]: ' "$_p" "$2" >&2
            else printf '%s: ' "$_p" >&2; fi
            read -r _v < "$TTY_DEV" || return 1
            [ -n "$_v" ] || _v=$2
            printf '%s' "$_v"
            ;;
        none) return 1 ;;
    esac
}

# ui_secret ETIQUETA -> valor por stdout (sin eco)
ui_secret() {
    case "$UI" in
        whiptail|dialog)
            "$UI" --backtitle "$BT" --passwordbox "$1" 11 72 3>&1 1>&2 2>&3 < "$TTY_DEV"
            ;;
        plain)
            printf '%s: ' "$(printf '%s' "$1" | sed 's/:$//')" >&2
            if stty -echo < "$TTY_DEV" 2>/dev/null; then
                read -r _v < "$TTY_DEV" || { stty echo < "$TTY_DEV" 2>/dev/null; return 1; }
                stty echo < "$TTY_DEV" 2>/dev/null
                printf '\n' >&2
            else
                read -r _v < "$TTY_DEV" || return 1
            fi
            printf '%s' "$_v"
            ;;
        none) return 1 ;;
    esac
}

# ui_menu ETIQUETA "clave1" "desc1" "clave2" "desc2" ... -> clave por stdout
ui_menu() {
    _label=$1; shift
    case "$UI" in
        whiptail|dialog)
            _n=$(( $# / 2 ))
            "$UI" --backtitle "$BT" --menu "$_label" 18 72 "$_n" "$@" 3>&1 1>&2 2>&3 < "$TTY_DEV"
            ;;
        plain)
            printf '\n%s\n' "$_label" >&2
            _i=1; _keys=''
            while [ $# -gt 0 ]; do
                printf '  %s) %s — %s\n' "$_i" "$1" "$2" >&2
                _keys="$_keys$1
"
                _i=$(( _i + 1 )); shift 2
            done
            printf 'Elige [1]: ' >&2
            read -r _sel < "$TTY_DEV" || return 1
            [ -n "$_sel" ] || _sel=1
            printf '%s' "$_keys" | sed -n "${_sel}p"
            ;;
        none) return 1 ;;
    esac
}

ui_yesno() {
    [ -n "$ASSUME_YES" ] && return 0
    case "$UI" in
        whiptail|dialog) "$UI" --backtitle "$BT" --yesno "$1" 20 72 < "$TTY_DEV" ;;
        plain)
            printf '\n%s\n¿Continuar? [S/n]: ' "$1"
            read -r _a < "$TTY_DEV" || return 1
            case "${_a:-s}" in [sSyY]*) return 0 ;; *) return 1 ;; esac
            ;;
        none) return 0 ;;
    esac
}

# Pide un dato obligatorio; si no hay terminal, explica qué flag usar y aborta.
require_interactive() {
    [ "$UI" = none ] && die "Falta $1 y no hay terminal para preguntarlo. Pásalo con $2."
    return 0
}

# ============================================================================
# Validación y generación
# ============================================================================

valid_domain() {
    printf '%s' "$1" | grep -Eq '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
}
valid_label() {
    printf '%s' "$1" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'
}
valid_email() {
    printf '%s' "$1" | grep -Eq '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
}

# Zona horaria que ya tiene el sistema, por stdout; cadena vacía si no hay.
# El parámetro RAIZ solo existe para poder probar la función contra un /etc
# simulado: en producción se llama sin argumentos.
system_timezone() {
    _tzroot=${1:-}
    _tz=''
    if [ -r "$_tzroot/etc/timezone" ]; then
        _tz=$(tr -d ' \n\r' < "$_tzroot/etc/timezone" 2>/dev/null || true)
    fi
    if [ -z "$_tz" ] && [ -L "$_tzroot/etc/localtime" ]; then
        _tz=$(readlink "$_tzroot/etc/localtime" 2>/dev/null | sed 's#.*/zoneinfo/##')
    fi
    printf '%s' "$_tz"
}

# Cierto si la zona horaria no dice nada del sitio donde está el equipo. UTC no
# es un dato: es lo que queda cuando nadie ha elegido nada.
tz_is_placeholder() {
    case "${1:-}" in
        ''|UTC|Etc/UTC|GMT|Etc/GMT|Universal|Etc/Universal) return 0 ;;
        *) return 1 ;;
    esac
}

gen_password() {
    if [ -r /dev/urandom ]; then
        LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | dd bs=1 count=24 2>/dev/null
    elif have openssl; then
        openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-24
    else
        die "No hay fuente de aleatoriedad para generar contraseñas."
    fi
}

# ============================================================================
# Pasos idempotentes
# ============================================================================

step_done() { [ -f "$STATE_DIR/step.$1" ]; }
step_mark() { touch "$STATE_DIR/step.$1"; }

# run_step NOMBRE DESCRIPCION funcion
run_step() {
    _sname=$1; _sdesc=$2; _sfn=$3
    if step_done "$_sname"; then
        note "$_sdesc — ya hecho, se omite"
        return 0
    fi
    info "$_sdesc"
    if "$_sfn"; then
        step_mark "$_sname"
        ok "$_sdesc"
    else
        err "Falló: $_sdesc"
        err "Corrige el problema y vuelve a ejecutar; los pasos ya completados no se repetirán."
        [ -n "$HAS_SYSTEMD" ] && [ -n "$IS_ROOT" ] && \
            note "Reintentar con: systemctl start coolify-setup.service"
        die "Instalación interrumpida en el paso '$_sname'. Log: $LOG_FILE"
    fi
}

# ============================================================================
# FASE 1 — Resolver configuración (derivar > argumentos > preguntar)
# ============================================================================

# Recupera valores de una ejecución anterior para no volver a preguntar.
# Se cargan con prefijo SAVED_ y solo rellenan huecos: lo que venga por línea de
# comandos o entorno en este reintento tiene que seguir mandando sobre lo viejo.
CONFIG_FILE="$STATE_DIR/config.env"
if [ -f "$CONFIG_FILE" ]; then
    _logfile "Recuperando configuración previa de $CONFIG_FILE"
    eval "$(sed -n 's/^\([A-Z_][A-Z0-9_]*\)=/SAVED_\1=/p' "$CONFIG_FILE")"
    for _k in CF_TOKEN ROOT_DOMAIN ZONE_ID ACCOUNT_ID APP_SUBDOMAIN COOLIFY_SUBDOMAIN \
              NEW_HOSTNAME ADMIN_USER ADMIN_PASSWORD SSH_KEY TIMEZONE TIMEZONE_SOURCE \
              WIFI_SSID WIFI_PASSWORD COOLIFY_EMAIL COOLIFY_PASSWORD; do
        eval "_cur=\${$_k:-}; _old=\${SAVED_$_k:-}"
        [ -z "$_cur" ] && [ -n "$_old" ] && eval "$_k=\$_old"
    done
    unset _k _cur _old
fi

: "${APP_SUBDOMAIN:=app}"
: "${COOLIFY_SUBDOMAIN:=coolify}"

info "Resolviendo configuración"

# --- Red disponible ------------------------------------------------------
has_network() {
    # Camino rápido: preguntar por la ruta por defecto con lo que haya.
    if have ip && ip route 2>/dev/null | grep -q '^default'; then return 0; fi
    if have route && route -n get default >/dev/null 2>&1; then return 0; fi
    # Linux sin iproute2 (contenedores e imágenes mínimas): mirar /proc.
    # El destino 00000000 es la ruta por defecto.
    if [ -r /proc/net/route ] \
       && awk 'NR>1 && $2=="00000000" {found=1} END {exit !found}' /proc/net/route; then
        return 0
    fi
    # Último recurso: probar de verdad. Que falten las herramientas de red no
    # significa que falte la red, y dar un falso negativo aquí bloquea todo
    # pidiendo una WiFi que no hace ninguna falta.
    fetch_stdout "https://cloudflare.com/cdn-cgi/trace" >/dev/null 2>&1 && return 0
    return 1
}

if ! has_network; then
    warn "No se detecta ruta por defecto: hace falta configurar la red."
    if [ -z "$WIFI_SSID" ]; then
        require_interactive "la configuración de red" "--wifi-ssid/--wifi-password"
        while :; do
            WIFI_SSID=$(ui_input "No hay red. SSID de la WiFi a la que conectar:" "") \
                || die "Cancelado por el usuario."
            [ -n "$WIFI_SSID" ] && break
            ui_msg "El SSID no puede estar vacío."
        done
    fi
    if [ -z "$WIFI_PASSWORD" ]; then
        WIFI_PASSWORD=$(ui_secret "Contraseña de la red '$WIFI_SSID':") || true
    fi
    note "Se conectará a la WiFi '$WIFI_SSID' antes de continuar."
else
    ok "Red disponible"
    WIFI_SSID=''
fi

# --- Token de Cloudflare: el único dato irreducible ----------------------
while :; do
    if [ -z "$CF_TOKEN" ]; then
        require_interactive "el API Token de Cloudflare" "--cf-token o CF_API_TOKEN"
        printf '\n'
        note "Necesitas un API Token con permisos Zone:DNS:Edit y Zone:Zone:Read."
        note "Créalo en https://dash.cloudflare.com/profile/api-tokens"
        CF_TOKEN=$(ui_secret "Cloudflare API Token:") || die "Cancelado por el usuario."
    fi
    if [ -z "$CF_TOKEN" ]; then
        ui_msg "El token no puede estar vacío."
        continue
    fi
    if cf_call GET /user/tokens/verify >/dev/null 2>&1; then
        ok "Token de Cloudflare verificado"
        break
    fi
    err "El token no es válido o no tiene permisos."
    CF_TOKEN=''
    [ "$UI" = none ] && die "Token de Cloudflare inválido."
done

# --- Zona / dominio: derivado de la propia API ---------------------------
if [ -z "$ROOT_DOMAIN" ]; then
    info "Descubriendo zonas accesibles con este token"
    zones_json=$(cf_call GET "/zones?per_page=50") || die "No se pudieron listar las zonas."
    zone_count=$(printf '%s' "$zones_json" | json_get '.result_info.count')
    : "${zone_count:=0}"
    if [ "$zone_count" = "1" ]; then
        ROOT_DOMAIN=$(printf '%s' "$zones_json" | json_get '.result[0].name')
        ZONE_ID=$(printf '%s' "$zones_json" | json_get '.result[0].id')
        ok "Única zona del token: $ROOT_DOMAIN (no hace falta preguntar)"
    elif [ "$zone_count" = "0" ]; then
        die "El token no da acceso a ninguna zona. Revisa sus permisos."
    else
        require_interactive "el dominio" "--domain"
        # Construir el menú a partir de las zonas devueltas.
        set --
        i=0
        while [ "$i" -lt "$zone_count" ] && [ "$i" -lt 50 ]; do
            zn=$(printf '%s' "$zones_json" | json_get ".result[$i].name")
            zs=$(printf '%s' "$zones_json" | json_get ".result[$i].status")
            [ -n "$zn" ] && set -- "$@" "$zn" "${zs:-?}"
            i=$(( i + 1 ))
        done
        ROOT_DOMAIN=$(ui_menu "El token cubre varias zonas. ¿Cuál usar?" "$@") \
            || die "Cancelado por el usuario."
    fi
fi
valid_domain "$ROOT_DOMAIN" || die "Dominio no válido: $ROOT_DOMAIN"
valid_label "$APP_SUBDOMAIN" || die "Subdominio de apps no válido: $APP_SUBDOMAIN"
valid_label "$COOLIFY_SUBDOMAIN" || die "Subdominio de Coolify no válido: $COOLIFY_SUBDOMAIN"

# ZONE_ID puede venir ya del bloque anterior; si no, resolverlo.
if [ -z "${ZONE_ID:-}" ]; then
    ZONE_ID=$(cf_call GET "/zones?name=$ROOT_DOMAIN" | json_get '.result[0].id') \
        || die "No se pudo resolver la zona $ROOT_DOMAIN."
    [ -n "$ZONE_ID" ] || die "La zona $ROOT_DOMAIN no existe en esta cuenta."
fi

ACCOUNT_ID=$(cf_call GET "/zones/$ZONE_ID" | json_get '.result.account.id') || true
if [ -z "${ACCOUNT_ID:-}" ]; then
    ACCOUNT_ID=$(cf_call GET /accounts | json_get '.result[0].id') \
        || die "No se pudo determinar el ID de cuenta de Cloudflare."
fi
ok "Zona $ROOT_DOMAIN resuelta"

# --- Hostname: derivado del dominio --------------------------------------
if [ -z "$NEW_HOSTNAME" ]; then
    # Quedarse con la primera etiqueta: el hostname actual puede ser un FQDN
    # ('host.local' vía mDNS, 'host.example.com'), y ahí solo interesa el nombre.
    cur=$(hostname 2>/dev/null | cut -d. -f1 || echo '')
    case "$cur" in
        ''|localhost|ubuntu|ubuntu-tmp|debian|linux|archlinux|raspberrypi)
            NEW_HOSTNAME=$(printf '%s' "$ROOT_DOMAIN" | cut -d. -f1) ;;
        *)  NEW_HOSTNAME=$cur ;;
    esac
    note "Hostname derivado: $NEW_HOSTNAME"
fi
valid_label "$NEW_HOSTNAME" || die "Hostname no válido: $NEW_HOSTNAME"

# --- Usuario administrador: reutilizar o crear ---------------------------
ADMIN_USER_EXISTED=''
if [ -z "$ADMIN_USER" ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        ADMIN_USER=$SUDO_USER
    elif [ -r /etc/passwd ]; then
        # Primer usuario normal que no sea la cuenta temporal del instalador.
        ADMIN_USER=$(awk -F: '$3>=1000 && $3<65534 && $1!="nobody" && $1!="installer" {print $1; exit}' /etc/passwd)
    fi
    : "${ADMIN_USER:=admin}"
    note "Usuario administrador: $ADMIN_USER"
fi
id "$ADMIN_USER" >/dev/null 2>&1 && ADMIN_USER_EXISTED=1

# Solo se genera contraseña si vamos a crear el usuario; a un usuario que ya
# existe no se le toca la credencial.
if [ -z "$ADMIN_PASSWORD" ] && [ -z "$ADMIN_USER_EXISTED" ] && [ -z "$SSH_KEY" ]; then
    ADMIN_PASSWORD=$(gen_password)
    note "Contraseña de $ADMIN_USER generada (irá al fichero de credenciales)"
fi

# Clave SSH ya presente en el sistema: reutilizarla en vez de pedirla.
if [ -z "$SSH_KEY" ] && [ -n "$ADMIN_USER_EXISTED" ]; then
    ak=$(eval echo "~$ADMIN_USER")/.ssh/authorized_keys
    if [ -s "$ak" ]; then
        note "El usuario ya tiene claves SSH autorizadas; se respetan"
    fi
fi

# --- Zona horaria: sistema -> geolocalización -> UTC ---------------------
# El orden importa. La zona del sistema ya suele estar bien (el instalador de
# Ubuntu la fija) y no le cuenta nada a nadie; la geolocalización revela a un
# tercero la IP pública y el momento de la instalación, así que es el último
# recurso, se anuncia antes de hacerla y se puede desactivar.
if [ -z "$TIMEZONE" ]; then
    TIMEZONE=$(system_timezone)
    if ! tz_is_placeholder "$TIMEZONE"; then
        TIMEZONE_SOURCE=sistema
        note "Zona horaria del sistema: $TIMEZONE"
    elif [ -n "$NO_GEOIP" ]; then
        TIMEZONE_SOURCE=utc
        : "${TIMEZONE:=UTC}"
        note "Zona horaria: $TIMEZONE (geolocalización desactivada por --no-geoip/NO_GEOIP)."
        note "Si no es la que quieres, pásala con --timezone=Area/Ciudad."
    else
        warn "El sistema no tiene zona horaria propia; está en ${TIMEZONE:-UTC}."
        note "Para deducirla se va a consultar https://ipapi.co/timezone, que verá la"
        note "IP pública de este equipo y el momento de la instalación."
        note "Para evitarlo: --timezone=Area/Ciudad, o --no-geoip para quedarse en UTC."
        geo_tz=$(fetch_stdout "https://ipapi.co/timezone" 2>/dev/null | tr -d ' \n\r' || true)
        if [ -n "$geo_tz" ] && [ -e "/usr/share/zoneinfo/$geo_tz" ]; then
            TIMEZONE=$geo_tz
            TIMEZONE_SOURCE=geoip
            note "Zona horaria deducida por geolocalización: $TIMEZONE"
        else
            TIMEZONE_SOURCE=utc
            : "${TIMEZONE:=UTC}"
            note "La geolocalización no devolvió una zona válida; se queda en $TIMEZONE."
        fi
    fi
fi
: "${TIMEZONE:=UTC}"
: "${TIMEZONE_SOURCE:=indicada}"

# --- Datos de Coolify: derivados y generados -----------------------------
if [ -z "$COOLIFY_EMAIL" ]; then
    # El nombre de cuenta de Cloudflare suele contener el email del titular.
    acct_name=$(cf_call GET "/accounts/$ACCOUNT_ID" 2>/dev/null | json_get '.result.name' || true)
    COOLIFY_EMAIL=$(printf '%s' "$acct_name" | grep -Eo '[^[:space:]@]+@[^[:space:]@]+\.[a-zA-Z]{2,}' | head -n1 || true)
    if [ -n "$COOLIFY_EMAIL" ]; then
        note "Email de Coolify deducido de la cuenta Cloudflare: $COOLIFY_EMAIL"
    else
        COOLIFY_EMAIL="admin@$ROOT_DOMAIN"
        note "Email de Coolify por defecto: $COOLIFY_EMAIL"
    fi
fi
valid_email "$COOLIFY_EMAIL" || die "Email de Coolify no válido: $COOLIFY_EMAIL"

if [ -z "$COOLIFY_PASSWORD" ]; then
    COOLIFY_PASSWORD=$(gen_password)
    note "Contraseña de Coolify generada (irá al fichero de credenciales)"
fi

APP_WILDCARD="*.$APP_SUBDOMAIN.$ROOT_DOMAIN"
COOLIFY_FQDN="$COOLIFY_SUBDOMAIN.$ROOT_DOMAIN"

# --- Guardar configuración resuelta para reintentos ----------------------
save_config() {
    umask 077
    cat > "$CONFIG_FILE" <<EOF
CF_TOKEN='$(printf '%s' "$CF_TOKEN" | sed "s/'/'\\\\''/g")'
ROOT_DOMAIN='$ROOT_DOMAIN'
ZONE_ID='$ZONE_ID'
ACCOUNT_ID='$ACCOUNT_ID'
APP_SUBDOMAIN='$APP_SUBDOMAIN'
COOLIFY_SUBDOMAIN='$COOLIFY_SUBDOMAIN'
NEW_HOSTNAME='$NEW_HOSTNAME'
ADMIN_USER='$ADMIN_USER'
ADMIN_PASSWORD='$(printf '%s' "$ADMIN_PASSWORD" | sed "s/'/'\\\\''/g")'
SSH_KEY='$(printf '%s' "$SSH_KEY" | sed "s/'/'\\\\''/g")'
TIMEZONE='$TIMEZONE'
TIMEZONE_SOURCE='$TIMEZONE_SOURCE'
WIFI_SSID='$(printf '%s' "$WIFI_SSID" | sed "s/'/'\\\\''/g")'
WIFI_PASSWORD='$(printf '%s' "$WIFI_PASSWORD" | sed "s/'/'\\\\''/g")'
COOLIFY_EMAIL='$COOLIFY_EMAIL'
COOLIFY_PASSWORD='$(printf '%s' "$COOLIFY_PASSWORD" | sed "s/'/'\\\\''/g")'
EOF
    chmod 600 "$CONFIG_FILE"
}
save_config

# --- Resumen y confirmación ----------------------------------------------
CONFIG_SUMMARY="Configuración resuelta:

  Hostname .......... $NEW_HOSTNAME
  Usuario admin ..... $ADMIN_USER $([ -n "$ADMIN_USER_EXISTED" ] && echo '(ya existe, no se toca)' || echo '(se creará)')
  Zona horaria ...... $TIMEZONE (origen: $TIMEZONE_SOURCE)
  Red ............... $([ -n "$WIFI_SSID" ] && echo "WiFi '$WIFI_SSID'" || echo 'Ethernet/DHCP')

  Dominio ........... $ROOT_DOMAIN
  Apps .............. https://$APP_WILDCARD  ->  localhost:80
  Panel Coolify ..... https://$COOLIFY_FQDN  ->  localhost:8000
  Email Coolify ..... $COOLIFY_EMAIL

  Contraseñas generadas automáticamente; al terminar quedan en
  $CREDS_FILE (modo 0600), no en el resumen."

printf '\n%s\n\n' "$CONFIG_SUMMARY"

if [ -n "$DRY_RUN" ]; then
    log "--dry-run: no se ejecuta nada más."
    exit 0
fi

ui_yesno "$CONFIG_SUMMARY

¿Proceder con la instalación?" || die "Cancelado por el usuario."

# ============================================================================
# FASE 2 — Ejecución
# ============================================================================

need_root() {
    [ -n "$IS_ROOT" ] && return 0
    err "Este paso necesita privilegios de root. Reejecuta con sudo."
    return 1
}

# --- Red WiFi -------------------------------------------------------------
do_wifi() {
    [ -n "$WIFI_SSID" ] || return 0
    need_root || return 1
    have nmcli || { err "nmcli no disponible; no se puede configurar la WiFi automáticamente."; return 1; }
    nmcli radio wifi on || true
    nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" || return 1
    has_network || { err "Conectado a la WiFi pero sigue sin haber ruta por defecto."; return 1; }
}
run_step wifi "Conexión WiFi" do_wifi

# --- Hostname -------------------------------------------------------------
do_hostname() {
    need_root || return 1
    if have hostnamectl && [ -n "$HAS_SYSTEMD" ]; then
        hostnamectl set-hostname "$NEW_HOSTNAME" || return 1
    elif [ "$OS_N" = darwin ]; then
        scutil --set HostName "$NEW_HOSTNAME" || return 1
    else
        hostname "$NEW_HOSTNAME" || return 1
        printf '%s\n' "$NEW_HOSTNAME" > /etc/hostname 2>/dev/null || true
    fi
    if [ -w /etc/hosts ] && ! grep -q "[[:space:]]$NEW_HOSTNAME\$" /etc/hosts; then
        printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >> /etc/hosts
    fi
}
run_step hostname "Hostname -> $NEW_HOSTNAME" do_hostname

# --- Zona horaria ---------------------------------------------------------
do_timezone() {
    need_root || return 1
    if have timedatectl && [ -n "$HAS_SYSTEMD" ]; then
        timedatectl set-timezone "$TIMEZONE" || return 1
    elif [ -e "/usr/share/zoneinfo/$TIMEZONE" ]; then
        ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime || return 1
        printf '%s\n' "$TIMEZONE" > /etc/timezone 2>/dev/null || true
    else
        warn "Zona horaria $TIMEZONE no encontrada; se deja la actual."
    fi
}
run_step timezone "Zona horaria -> $TIMEZONE" do_timezone

# --- Usuario administrador -----------------------------------------------
do_admin_user() {
    need_root || return 1
    [ "$OS_N" = linux ] || { warn "Gestión de usuarios solo automatizada en Linux; se omite."; return 0; }

    if ! id "$ADMIN_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$ADMIN_USER" || return 1
        ok "Usuario $ADMIN_USER creado"
    fi

    # Grupo de administración según distribución.
    for g in sudo wheel; do
        if getent group "$g" >/dev/null 2>&1; then
            usermod -aG "$g" "$ADMIN_USER" || return 1
            break
        fi
    done

    if [ -n "$ADMIN_PASSWORD" ]; then
        printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" | chpasswd || return 1
    fi

    if [ -n "$SSH_KEY" ]; then
        home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
        mkdir -p "$home/.ssh" && chmod 700 "$home/.ssh"
        if ! grep -qF "$SSH_KEY" "$home/.ssh/authorized_keys" 2>/dev/null; then
            printf '%s\n' "$SSH_KEY" >> "$home/.ssh/authorized_keys"
        fi
        chmod 600 "$home/.ssh/authorized_keys"
        chown -R "$ADMIN_USER" "$home/.ssh"
        # Con clave SSH configurada, se desactiva el acceso por contraseña.
        if [ -d /etc/ssh/sshd_config.d ]; then
            printf 'PasswordAuthentication no\n' > /etc/ssh/sshd_config.d/90-no-password.conf
            [ -n "$HAS_SYSTEMD" ] && systemctl reload ssh 2>/dev/null || true
        fi
    fi
    return 0
}
run_step admin_user "Usuario administrador '$ADMIN_USER'" do_admin_user

# --- Docker ---------------------------------------------------------------
do_docker() {
    [ -n "$SKIP_DOCKER" ] && { note "omitido por --skip-docker"; return 0; }
    if have docker && docker info >/dev/null 2>&1; then
        ok "Docker ya operativo"
    else
        need_root || return 1
        [ "$OS_N" = linux ] || { err "La instalación automática de Docker solo está soportada en Linux. En macOS instala Docker Desktop y reejecuta con --skip-docker."; return 1; }
        fetch_file "https://get.docker.com" "$WORK_DIR/get-docker.sh" || return 1
        sh "$WORK_DIR/get-docker.sh" || return 1
    fi
    if [ -n "$HAS_SYSTEMD" ]; then
        systemctl enable --now docker || return 1
    fi
    usermod -aG docker "$ADMIN_USER" 2>/dev/null || true
    docker info >/dev/null 2>&1 || { err "Docker instalado pero no responde."; return 1; }
}
run_step docker "Docker" do_docker

# --- Coolify --------------------------------------------------------------
wait_for_http() {
    # wait_for_http URL SEGUNDOS
    _u=$1; _limit=$2; _waited=0
    while [ "$_waited" -lt "$_limit" ]; do
        if fetch_stdout "$_u" >/dev/null 2>&1; then return 0; fi
        sleep 5; _waited=$(( _waited + 5 ))
        [ $(( _waited % 30 )) -eq 0 ] && note "esperando a $_u ... ${_waited}s"
    done
    return 1
}

do_coolify() {
    [ -n "$SKIP_COOLIFY" ] && { note "omitido por --skip-coolify"; return 0; }
    need_root || return 1
    [ "$OS_N" = linux ] || { err "Coolify solo se instala en Linux. Usa --skip-coolify en otros sistemas."; return 1; }

    if [ ! -d /data/coolify ]; then
        fetch_file "https://cdn.coollabs.io/coolify/install.sh" "$WORK_DIR/install-coolify.sh" || return 1
        # El instalador de Coolify requiere bash.
        have bash || { err "El instalador de Coolify necesita bash y no está disponible."; return 1; }
        bash "$WORK_DIR/install-coolify.sh" || return 1
    fi
    note "Esperando a que Coolify responda en localhost:8000 (puede tardar minutos)"
    wait_for_http "http://localhost:8000" 600 || { err "Coolify no respondió en 10 minutos."; return 1; }
}
run_step coolify "Coolify" do_coolify

do_coolify_domain() {
    [ -n "$SKIP_COOLIFY" ] && return 0
    envf=/data/coolify/source/.env
    [ -f "$envf" ] || { warn "No se encontró $envf; se omite la configuración del dominio."; return 0; }
    if grep -q '^APP_URL=' "$envf"; then
        sed -i.bak "s#^APP_URL=.*#APP_URL=https://$COOLIFY_FQDN#" "$envf"
    else
        printf 'APP_URL=https://%s\n' "$COOLIFY_FQDN" >> "$envf"
    fi
    ( cd /data/coolify/source && docker compose up -d --force-recreate 2>/dev/null ) || true
    wait_for_http "http://localhost:8000" 300 || warn "Coolify tarda en volver tras el reinicio."
    return 0
}
run_step coolify_domain "Dominio del panel -> $COOLIFY_FQDN" do_coolify_domain

# Registro del primer usuario. Coolify no expone API para esto (el token de API
# se genera desde la UI, después de existir un usuario), así que se automatiza
# el formulario público /register. Si falla, se deja indicado en el resumen.
COOLIFY_REGISTERED=''
do_coolify_register() {
    [ -n "$SKIP_COOLIFY" ] && return 0
    if [ "$HTTP" != curl ]; then
        warn "El registro automático del primer usuario necesita curl; hazlo manualmente."
        return 0
    fi
    jar="$WORK_DIR/coolify-cookies.txt"
    rm -f "$jar"
    page=$(curl -sS -c "$jar" -A "$UA" "http://localhost:8000/register" 2>/dev/null) || {
        warn "No se pudo abrir /register; regístrate manualmente."; return 0; }

    # Si Coolify ya tiene usuario, /register redirige o no muestra el formulario.
    case "$page" in
        *'name="_token"'*) : ;;
        *) warn "Coolify no muestra el formulario de registro (¿ya hay un usuario?). Regístrate manualmente."
           return 0 ;;
    esac
    token=$(printf '%s' "$page" | sed -n 's/.*name="_token"[^>]*value="\([^"]*\)".*/\1/p' | head -n1)
    [ -n "$token" ] || token=$(printf '%s' "$page" | sed -n 's/.*value="\([^"]*\)"[^>]*name="_token".*/\1/p' | head -n1)
    [ -n "$token" ] || { warn "No se pudo extraer el token CSRF; regístrate manualmente."; return 0; }

    code=$(curl -sS -o "$WORK_DIR/register-response.html" -w '%{http_code}' \
        -b "$jar" -c "$jar" -A "$UA" \
        --data-urlencode "_token=$token" \
        --data-urlencode "name=$ADMIN_USER" \
        --data-urlencode "email=$COOLIFY_EMAIL" \
        --data-urlencode "password=$COOLIFY_PASSWORD" \
        --data-urlencode "password_confirmation=$COOLIFY_PASSWORD" \
        "http://localhost:8000/register" 2>/dev/null) || code=000

    case "$code" in
        302|200|303)
            COOLIFY_REGISTERED=1
            ok "Primer usuario de Coolify registrado ($COOLIFY_EMAIL)"
            ;;
        *)
            warn "El registro automático devolvió HTTP $code; tendrás que registrarte a mano."
            _logfile "Respuesta de registro guardada en $WORK_DIR/register-response.html"
            ;;
    esac
    rm -f "$jar"
    return 0
}
run_step coolify_register "Primer usuario de Coolify" do_coolify_register

# --- cloudflared: binario -------------------------------------------------
CLOUDFLARED_BIN=''
do_cloudflared_bin() {
    [ -n "$SKIP_TUNNEL" ] && return 0
    if have cloudflared; then
        CLOUDFLARED_BIN=$(command -v cloudflared)
        return 0
    fi
    # cloudflared es un servicio permanente, no andamiaje: va a /usr/local/bin
    # para que la unidad de systemd siga siendo válida tras reiniciar.
    dest=/usr/local/bin/cloudflared
    [ -n "$IS_ROOT" ] || dest="$WORK_DIR/cloudflared"
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-$OS_N-$ARCH_N"
    info "Descargando cloudflared ($OS_N/$ARCH_N)"
    fetch_file "$url" "$dest.tmp" || { err "No se pudo descargar cloudflared desde $url"; return 1; }
    chmod +x "$dest.tmp" && mv "$dest.tmp" "$dest" || return 1
    "$dest" --version >/dev/null 2>&1 || { err "El binario descargado de cloudflared no funciona."; return 1; }
    CLOUDFLARED_BIN=$dest
}
run_step cloudflared_bin "Binario de cloudflared" do_cloudflared_bin
[ -z "$CLOUDFLARED_BIN" ] && have cloudflared && CLOUDFLARED_BIN=$(command -v cloudflared)
[ -z "$CLOUDFLARED_BIN" ] && [ -x /usr/local/bin/cloudflared ] && CLOUDFLARED_BIN=/usr/local/bin/cloudflared

# --- Túnel ----------------------------------------------------------------
TUNNEL_FILE="$STATE_DIR/tunnel.env"
# shellcheck source=/dev/null
[ -f "$TUNNEL_FILE" ] && . "$TUNNEL_FILE"

do_tunnel_create() {
    [ -n "$SKIP_TUNNEL" ] && return 0
    tname="coolify-$NEW_HOSTNAME"

    # Reutilizar el túnel si ya existe con ese nombre (reintentos limpios).
    existing=$(cf_call GET "/accounts/$ACCOUNT_ID/cfd_tunnel?name=$tname&is_deleted=false" 2>/dev/null \
        | json_get '.result[0].id' || true)
    if [ -n "$existing" ]; then
        TUNNEL_ID=$existing
        note "Reutilizando el túnel existente '$tname'"
        tok=$(cf_call GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" | json_get '.result') || return 1
        TUNNEL_TOKEN=$tok
    else
        body="{\"name\":\"$(json_escape "$tname")\",\"config_src\":\"cloudflare\"}"
        resp=$(cf_call POST "/accounts/$ACCOUNT_ID/cfd_tunnel" "$body") || return 1
        TUNNEL_ID=$(printf '%s' "$resp" | json_get '.result.id')
        TUNNEL_TOKEN=$(printf '%s' "$resp" | json_get '.result.token')
    fi
    [ -n "$TUNNEL_ID" ] && [ -n "$TUNNEL_TOKEN" ] || { err "No se obtuvo el ID/token del túnel."; return 1; }

    umask 077
    printf "TUNNEL_ID='%s'\nTUNNEL_TOKEN='%s'\n" "$TUNNEL_ID" "$TUNNEL_TOKEN" > "$TUNNEL_FILE"
    chmod 600 "$TUNNEL_FILE"
}
run_step tunnel_create "Túnel de Cloudflare" do_tunnel_create
# shellcheck source=/dev/null
[ -f "$TUNNEL_FILE" ] && . "$TUNNEL_FILE"

do_tunnel_ingress() {
    [ -n "$SKIP_TUNNEL" ] && return 0
    body="{\"config\":{\"ingress\":[
        {\"hostname\":\"$(json_escape "$APP_WILDCARD")\",\"service\":\"http://localhost:80\"},
        {\"hostname\":\"$(json_escape "$COOLIFY_FQDN")\",\"service\":\"http://localhost:8000\"},
        {\"service\":\"http_status:404\"}]}}"
    cf_call PUT "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" "$body" >/dev/null || return 1
}
run_step tunnel_ingress "Reglas de enrutado del túnel" do_tunnel_ingress

do_dns() {
    [ -n "$SKIP_TUNNEL" ] && return 0
    target="$TUNNEL_ID.cfargotunnel.com"
    for name in "*.$APP_SUBDOMAIN" "$COOLIFY_SUBDOMAIN"; do
        fqdn="$name.$ROOT_DOMAIN"
        body="{\"type\":\"CNAME\",\"name\":\"$(json_escape "$name")\",\"content\":\"$target\",\"proxied\":true,\"ttl\":1}"
        rid=$(cf_api GET "/zones/$ZONE_ID/dns_records?name=$fqdn" 2>/dev/null | json_get '.result[0].id' || true)
        if [ -n "$rid" ]; then
            cf_call PUT "/zones/$ZONE_ID/dns_records/$rid" "$body" >/dev/null || return 1
            note "CNAME actualizado: $fqdn"
        else
            cf_call POST "/zones/$ZONE_ID/dns_records" "$body" >/dev/null || return 1
            note "CNAME creado: $fqdn"
        fi
    done
}
run_step dns "Registros DNS" do_dns

do_tunnel_service() {
    [ -n "$SKIP_TUNNEL" ] && return 0
    need_root || return 1
    [ -n "$CLOUDFLARED_BIN" ] || { err "No hay binario de cloudflared."; return 1; }
    if [ -n "$HAS_SYSTEMD" ] && systemctl is-active --quiet cloudflared 2>/dev/null; then
        ok "cloudflared ya está corriendo"
        return 0
    fi
    "$CLOUDFLARED_BIN" service uninstall >/dev/null 2>&1 || true
    "$CLOUDFLARED_BIN" service install "$TUNNEL_TOKEN" || return 1
    if [ -n "$HAS_SYSTEMD" ]; then
        systemctl enable --now cloudflared || return 1
        sleep 5
        systemctl is-active --quiet cloudflared || { err "cloudflared no arrancó."; return 1; }
    fi
}
run_step tunnel_service "Servicio cloudflared" do_tunnel_service

# ============================================================================
# FASE 3 — Resumen
# ============================================================================

svc_state() {
    if [ -n "$HAS_SYSTEMD" ]; then systemctl is-active "$1" 2>/dev/null || echo inactivo
    else echo 'n/d'; fi
}

# El resumen se parte en dos a propósito. Uno se puede enseñar, pegar en un
# ticket o dejar en pantalla; el otro tiene contraseñas en claro y hay que
# tratarlo como lo que es.
# Se aísla en una función para poder probarla: la suite la carga con eval y
# comprueba que el resumen no lleva contraseñas y el de credenciales sí.
write_summaries() {
    {
        printf '=== Instalación completada — %s ===\n\n' "$(_ts)"
        printf 'SISTEMA\n'
        printf '  Hostname .......... %s\n' "$NEW_HOSTNAME"
        printf '  Zona horaria ...... %s (origen: %s)\n' "$TIMEZONE" "$TIMEZONE_SOURCE"
        printf '  Usuario admin ..... %s\n' "$ADMIN_USER"
        if [ -n "$ADMIN_PASSWORD" ]; then
            printf '  Acceso ............ contraseña generada (en %s)\n' "$CREDS_FILE"
        elif [ -n "$SSH_KEY" ]; then
            printf '  Acceso ............ solo clave SSH (contraseña deshabilitada)\n'
        else
            printf '  Acceso ............ sin cambios (el usuario ya existía)\n'
        fi
        printf '\nCOOLIFY\n'
        printf '  Panel ............. https://%s\n' "$COOLIFY_FQDN"
        printf '  Email ............. %s\n' "$COOLIFY_EMAIL"
        printf '  Contraseña ........ en %s\n' "$CREDS_FILE"
        if [ -n "$COOLIFY_REGISTERED" ]; then
            printf '  Estado ............ usuario registrado, listo para entrar\n'
        elif [ -z "$SKIP_COOLIFY" ]; then
            printf '  Estado ............ PENDIENTE: abre el panel y regístrate con\n'
            printf '                      el email y contraseña de las credenciales\n'
            printf '                      (el primer usuario registrado es el propietario).\n'
        fi
        printf '\nAPPS\n'
        printf '  Patrón de dominio . https://<lo-que-sea>.%s.%s\n' "$APP_SUBDOMAIN" "$ROOT_DOMAIN"
        printf '  Al crear una app en Coolify, ponle un dominio con ese patrón:\n'
        printf '  el comodín ya está enrutado, no hay que tocar DNS por cada app.\n'
        printf '\nCLOUDFLARE TUNNEL\n'
        printf '  Zona .............. %s\n' "$ROOT_DOMAIN"
        printf '  Tunnel ID ......... %s\n' "${TUNNEL_ID:-omitido}"
        printf '  CNAME ............. %s y %s\n' "$APP_WILDCARD" "$COOLIFY_FQDN"
        printf '\nESTADO DE SERVICIOS\n'
        printf '  docker ............ %s\n' "$(svc_state docker)"
        printf '  cloudflared ....... %s\n' "$(svc_state cloudflared)"
        printf '\nSECRETOS\n'
        printf '  Credenciales ...... %s (modo 0600)\n' "$CREDS_FILE"
        printf '  Guárdalas en un gestor de contraseñas y borra ese fichero.\n'
        if [ -n "$KEEP_SECRETS" ]; then
            printf '  Ficheros .......... CONSERVADOS por --keep-secrets:\n'
            printf '                      %s\n' "$CONFIG_FILE"
            printf '                      %s\n' "$TUNNEL_FILE"
            [ -n "$IS_ROOT" ] && printf '                      %s\n' "$SETUP_ENV_FILE"
            printf '                      Contienen el API Token de Cloudflare y el\n'
            printf '                      token del túnel en claro. Bórralos a mano.\n'
        else
            printf '  Ficheros .......... borrados (token de Cloudflare, token del\n'
            printf '                      túnel y configuración resuelta).\n'
        fi
        printf '  El token de Cloudflare ya no hace falta aquí: el túnel está creado.\n'
        printf '  Puedes rotarlo sin romper nada.\n'
        printf '\n  Log completo ...... %s\n' "$LOG_FILE"
    } > "$SUMMARY_FILE"
    chmod 600 "$SUMMARY_FILE"

    {
        printf '=== Credenciales — %s ===\n\n' "$(_ts)"
        printf 'Contraseñas en claro. Guárdalas en un gestor de contraseñas y borra\n'
        printf 'este fichero:  shred -u %s   (o rm -f)\n\n' "$CREDS_FILE"
        printf 'SISTEMA\n'
        printf '  Usuario admin ..... %s\n' "$ADMIN_USER"
        if [ -n "$ADMIN_PASSWORD" ]; then
            printf '  Contraseña ........ %s\n' "$ADMIN_PASSWORD"
        elif [ -n "$SSH_KEY" ]; then
            printf '  Acceso ............ solo clave SSH (contraseña deshabilitada)\n'
        else
            printf '  Contraseña ........ sin cambios (el usuario ya existía)\n'
        fi
        printf '\nCOOLIFY\n'
        printf '  Panel ............. https://%s\n' "$COOLIFY_FQDN"
        printf '  Email ............. %s\n' "$COOLIFY_EMAIL"
        printf '  Contraseña ........ %s\n' "$COOLIFY_PASSWORD"
    } > "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
}

wipe_secrets() {
    if [ -n "$KEEP_SECRETS" ]; then
        warn "Se conservan los ficheros con secretos (--keep-secrets). Bórralos a mano."
        return 0
    fi
    wipe_file "$CONFIG_FILE"
    wipe_file "$TUNNEL_FILE"
    [ -n "$IS_ROOT" ] && wipe_file "$SETUP_ENV_FILE"
    note "Secretos borrados del disco; las credenciales quedan en $CREDS_FILE"
    return 0
}

# El orden de estas tres líneas NO es negociable: primero se escriben resumen y
# credenciales, luego la marca de completado, y solo entonces se borran los
# secretos. Al revés, un fallo entre medias dejaría el equipo sin marca y sin
# token: el servicio volvería a arrancar y pediría el token en bucle a alguien
# que ya no lo tiene a mano.
write_summaries
touch "$DONE_MARKER"
wipe_secrets

if [ -n "$HAS_SYSTEMD" ] && [ -n "$IS_ROOT" ]; then
    systemctl disable coolify-setup.service >/dev/null 2>&1 || true
fi

printf '\n'
cat "$SUMMARY_FILE"
if [ -n "$SUMMARY_NO_SECRETS" ]; then
    printf '\n%sCredenciales en %s (no se imprimen: --summary-no-secrets)%s\n\n' \
        "$C_BOLD" "$CREDS_FILE" "$C_RESET"
else
    printf '\n'
    cat "$CREDS_FILE"
    printf '\n'
fi
printf '%sResumen en %s — credenciales en %s%s\n\n' \
    "$C_BOLD" "$SUMMARY_FILE" "$CREDS_FILE" "$C_RESET"

# Con whiptail, dar tiempo a leer antes de que systemd limpie la consola.
if [ "$UI" = whiptail ] || [ "$UI" = dialog ]; then
    ui_msg "Instalación completada.

Panel: https://$COOLIFY_FQDN
Apps:  https://<nombre>.$APP_SUBDOMAIN.$ROOT_DOMAIN

Resumen en $SUMMARY_FILE
Credenciales en $CREDS_FILE (guárdalas y borra el fichero)"
fi

exit 0
