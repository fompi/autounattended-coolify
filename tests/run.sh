#!/bin/sh
# tests/run.sh — suite de pruebas del proyecto.
#
# Sin dependencias obligatorias mas alla de sh y python3. Lo que falte se
# omite anunciandolo, para que la suite corra igual en un portatil que en CI.
#
#   sh tests/run.sh              # todo
#   sh tests/run.sh json build   # solo esos grupos
#
# Grupos: syntax json validators timezone secrets resolution build latecommands
#
# Lo que NO cubre, y hay que probar a mano en una VM: el arranque real desde
# la ISO, y el paso tunnel_service (habla con el edge real de Cloudflare).

set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname "$HERE")
TMP=$(mktemp -d)
MOCK_PID=''
cleanup() {
    [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

PASS=0; FAIL=0; SKIP=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    G=$(printf '\033[32m'); R=$(printf '\033[31m'); Y=$(printf '\033[33m')
    B=$(printf '\033[1m'); Z=$(printf '\033[0m')
else
    G=''; R=''; Y=''; B=''; Z=''
fi

group()  { printf '\n%s== %s%s\n' "$B" "$1" "$Z"; }
ok()     { PASS=$((PASS+1)); printf '  %sok%s   %s\n' "$G" "$Z" "$1"; }
bad()    { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$R" "$Z" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
skip()   { SKIP=$((SKIP+1)); printf '  %sskip%s %s (%s)\n' "$Y" "$Z" "$1" "$2"; }
have()   { command -v "$1" >/dev/null 2>&1; }

# is "descripcion" "esperado" "obtenido"
is() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "esperado [$2], obtenido [$3]"; fi
}

# Ojo: no llamar a esta variable GROUPS. En bash es especial (los grupos del
# usuario) y asignarla revienta el script bajo 'set -e'.
WANTED="${*:-syntax json validators timezone secrets resolution build latecommands}"
want() {
    for g in $WANTED; do [ "$g" = "$1" ] && return 0; done
    return 1
}

# ---------------------------------------------------------------- sintaxis
if want syntax; then
group "Sintaxis y estilo"
for f in setup.sh build-usb.sh tests/run.sh; do
    for s in sh dash bash ksh zsh; do
        have "$s" || continue
        if $s -n "$ROOT/$f" 2>"$TMP/err"; then
            ok "$f pasa $s -n"
        else
            bad "$f pasa $s -n" "$(head -2 "$TMP/err")"
        fi
    done
done
if have shellcheck; then
    for f in setup.sh build-usb.sh; do
        if shellcheck -s sh -S warning "$ROOT/$f" > "$TMP/sc" 2>&1; then
            ok "$f limpio en shellcheck"
        else
            bad "$f limpio en shellcheck" "$(head -6 "$TMP/sc")"
        fi
    done
else
    skip "shellcheck" "no instalado"
fi
# Bashismos que romperian en dash/ash. Se buscan explicitamente porque la
# herramienta shellcheck no siempre esta instalada.
# (Ojo: un comentario que empiece por "# shellcheck " se interpreta como
#  directiva y rompe el analisis. De ahi la redaccion.)
for pat in '\[\[[[:space:]]' 'printf -v' '\bdeclare\b' '\blocal -' '\$\{[A-Za-z_]*\^\^\}' '\$\{[A-Za-z_]*,,\}'; do
    if grep -nE "$pat" "$ROOT/setup.sh" "$ROOT/build-usb.sh" > "$TMP/hit" 2>/dev/null; then
        bad "sin bashismos ($pat)" "$(head -2 "$TMP/hit")"
    else
        ok "sin bashismos ($pat)"
    fi
done
fi

# ------------------------------------------------------------------- json
if want json; then
group "Extraccion de JSON (los dos motores deben coincidir)"
extract_fns() {
    # Carga las funciones puras de setup.sh en este shell.
    eval "$(awk '/^JSON_PY=.$/,/^.$/' "$ROOT/setup.sh")"
    eval "$(sed -n '/^json_get() {/,/^}/p' "$ROOT/setup.sh")"
    eval "$(sed -n '/^json_escape() {/,/^}/p' "$ROOT/setup.sh")"
    setup_json() { :; }
}
extract_fns
# Estas variables las consumen las funciones cargadas con eval mas arriba,
# cosa que el analizador no puede ver.
# shellcheck disable=SC2034
WORK_DIR="$TMP"

J='{"success":true,"result":[{"id":"abc","name":"fompi.net"}],"result_info":{"count":3}}'
E='{"success":false,"errors":[{"code":1000,"message":"Invalid API Token"}]}'
N='{"result":{"account":{"id":"acc-1"}}}'

run_json_cases() {
    eng=$1
    is "[$eng] .success"            "true"    "$(printf '%s' "$J" | json_get '.success')"
    is "[$eng] .result[0].id"       "abc"     "$(printf '%s' "$J" | json_get '.result[0].id')"
    is "[$eng] .result_info.count"  "3"       "$(printf '%s' "$J" | json_get '.result_info.count')"
    is "[$eng] indice fuera de rango" ""      "$(printf '%s' "$J" | json_get '.result[9].id')"
    is "[$eng] clave inexistente"   ""        "$(printf '%s' "$J" | json_get '.nope')"
    is "[$eng] anidado profundo"    "acc-1"   "$(printf '%s' "$N" | json_get '.result.account.id')"
    is "[$eng] json invalido"       ""        "$(printf 'no soy json' | json_get '.a')"
    # Regresion: jq trata false como vacio con '// empty'. Hay que poder
    # distinguir "el token es invalido" de "respuesta rara".
    is "[$eng] false != vacio"      "false"   "$(printf '%s' "$E" | json_get '.success')"
    is "[$eng] mensaje de error"    "Invalid API Token" "$(printf '%s' "$E" | json_get '.errors[0].message')"
}
if have python3; then
    # shellcheck disable=SC2034
    PY=python3
    # shellcheck disable=SC2034
    JSON_MODE=py
    run_json_cases py
else
    skip "motor python3" "no instalado"
fi
if have jq; then
    # shellcheck disable=SC2034
    JQ=$(command -v jq)
    # shellcheck disable=SC2034
    JSON_MODE=jq
    run_json_cases jq
else
    skip "motor jq" "no instalado"
fi
is "json_escape dobla la barra" 'co\"mi\\lla' "$(json_escape 'co"mi\lla')"
fi

# ------------------------------------------------------------- validadores
if want validators; then
group "Validadores y generacion"
eval "$(sed -n '/^valid_domain() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^valid_label() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^valid_email() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^gen_password() {/,/^}/p' "$ROOT/setup.sh")"
die() { printf '%s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

check() { # check fn valor esperado(0|1)
    if "$1" "$2"; then got=0; else got=1; fi
    if [ "$got" = "$3" ]; then ok "$1('$2')"; else bad "$1('$2')" "esperaba rc=$3"; fi
}
check valid_domain fompi.net 0
check valid_domain sub.fompi.net 0
check valid_domain fompi 1
check valid_domain "-mal.net" 1
check valid_domain "no_valido" 1
check valid_label app 0
check valid_label "a-b" 0
check valid_label "-x" 1
check valid_label "con.punto" 1
check valid_email a@b.com 0
check valid_email "a@b" 1
check valid_email "sin-arroba" 1

P1=$(gen_password); P2=$(gen_password)
is "contrasena de 24 caracteres" "24" "${#P1}"
if [ "$P1" != "$P2" ]; then ok "contrasenas distintas entre llamadas"
else bad "contrasenas distintas entre llamadas" "salio dos veces $P1"; fi
if printf '%s' "$P1" | grep -q '^[A-Za-z0-9]*$'; then ok "contrasena alfanumerica"
else bad "contrasena alfanumerica" "$P1"; fi
fi

# ---------------------------------------------------------- zona horaria
if want timezone; then
group "Zona horaria: sistema antes que geolocalizacion (#12)"
eval "$(sed -n '/^system_timezone() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^tz_is_placeholder() {/,/^}/p' "$ROOT/setup.sh")"

TZR="$TMP/tzroot"; mkdir -p "$TZR/etc"
is "sin /etc/timezone ni symlink no inventa nada" "" "$(system_timezone "$TZR")"
printf 'Europe/Madrid\n' > "$TZR/etc/timezone"
is "lee /etc/timezone" "Europe/Madrid" "$(system_timezone "$TZR")"
printf '  Europe/Madrid  \n' > "$TZR/etc/timezone"
is "recorta espacios y salto de linea" "Europe/Madrid" "$(system_timezone "$TZR")"
rm -f "$TZR/etc/timezone"
ln -sf /usr/share/zoneinfo/America/Bogota "$TZR/etc/localtime"
is "cae al symlink de /etc/localtime" "America/Bogota" "$(system_timezone "$TZR")"
: > "$TZR/etc/timezone"
is "/etc/timezone vacio no tapa al symlink" "America/Bogota" "$(system_timezone "$TZR")"

for tz in '' UTC Etc/UTC GMT; do
    if tz_is_placeholder "$tz"; then ok "tz_is_placeholder('$tz')"
    else bad "tz_is_placeholder('$tz')" "deberia considerarse vacia"; fi
done
for tz in Europe/Madrid America/Bogota Asia/Tokyo; do
    if tz_is_placeholder "$tz"; then bad "tz_is_placeholder('$tz')" "no es un relleno"
    else ok "no tz_is_placeholder('$tz')"; fi
done

# La regla entera: solo se llama a ipapi.co si la zona del sistema no dice
# nada, no se paso --timezone y no se paso --no-geoip. Se comprueba sobre el
# texto del script porque la llamada real no se puede hacer en la suite.
n=$(grep -c 'fetch_stdout "https://ipapi.co' "$ROOT/setup.sh" || true)
is "una sola llamada a ipapi.co en todo el script" "1" "$n"
# El aviso tiene que estar ANTES de la llamada, no despues.
avi=$(grep -n 'se va a consultar https://ipapi.co' "$ROOT/setup.sh" | cut -d: -f1 | head -n1)
lla=$(grep -n 'fetch_stdout "https://ipapi.co' "$ROOT/setup.sh" | cut -d: -f1 | head -n1)
if [ -n "$avi" ] && [ -n "$lla" ] && [ "$avi" -lt "$lla" ]; then
    ok "se avisa por pantalla antes de la llamada"
else
    bad "se avisa por pantalla antes de la llamada" "aviso en ${avi:-?}, llamada en ${lla:-?}"
fi
case "$(sh "$ROOT/setup.sh" --help 2>&1)" in
    *--no-geoip*) ok "--no-geoip aparece en la ayuda" ;;
    *) bad "--no-geoip aparece en la ayuda" ;;
esac
fi

# --------------------------------------------------------------- secretos
if want secrets; then
group "Secretos: borrado, resumen partido y orden de #3"
eval "$(sed -n '/^wipe_file() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^write_summaries() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^wipe_secrets() {/,/^}/p' "$ROOT/setup.sh")"
have() { command -v "$1" >/dev/null 2>&1; }
_ts() { echo '2026-01-01 00:00:00'; }
svc_state() { echo activo; }
warn() { :; }
note() { :; }

SEC="$TMP/sec"; mkdir -p "$SEC"

# wipe_file: borra lo que hay y no se queja de lo que no.
printf 'secreto\n' > "$SEC/victima"
wipe_file "$SEC/victima"
if [ -e "$SEC/victima" ]; then bad "wipe_file borra el fichero"; else ok "wipe_file borra el fichero"; fi
st=0; wipe_file "$SEC/no-existe" || st=$?
is "wipe_file devuelve 0 si no existe" "0" "$st"
st=0; wipe_file "" || st=$?
is "wipe_file devuelve 0 con argumento vacio" "0" "$st"

# El resumen no puede llevar contrasenas; el de credenciales, si. Las
# variables las consume write_summaries, cargada con eval: el analizador no
# puede verlo, de ahi la directiva.
# shellcheck disable=SC2034
fake_config() {
    NEW_HOSTNAME='maquina'
    TIMEZONE='Europe/Madrid'
    TIMEZONE_SOURCE='sistema'
    ADMIN_USER='admin'
    ADMIN_PASSWORD='CLAVEADMIN123'
    SSH_KEY=''
    COOLIFY_FQDN='coolify.fompi.net'
    COOLIFY_EMAIL='a@b.com'
    COOLIFY_PASSWORD='CLAVECOOLIFY456'
    COOLIFY_REGISTERED=1
    SKIP_COOLIFY=''
    APP_SUBDOMAIN='app'
    ROOT_DOMAIN='fompi.net'
    APP_WILDCARD='*.app.fompi.net'
    TUNNEL_ID='tid'
    LOG_FILE="$SEC/log"
    IS_ROOT=''
    KEEP_SECRETS=''
    SETUP_ENV_FILE="$SEC/etc-env"
    SUMMARY_FILE="$SEC/resumen.txt"
    CREDS_FILE="$SEC/credenciales.txt"
    CONFIG_FILE="$SEC/config.env"
    TUNNEL_FILE="$SEC/tunnel.env"
}
fake_config

write_summaries
if grep -q 'CLAVEADMIN123\|CLAVECOOLIFY456' "$SUMMARY_FILE"; then
    bad "el resumen no lleva contrasenas" "$(grep -n 'CLAVE' "$SUMMARY_FILE" | head -2)"
else
    ok "el resumen no lleva contrasenas"
fi
if grep -q 'CLAVEADMIN123' "$CREDS_FILE" && grep -q 'CLAVECOOLIFY456' "$CREDS_FILE"; then
    ok "las credenciales van a su propio fichero"
else
    bad "las credenciales van a su propio fichero"
fi
case "$(cat "$SUMMARY_FILE")" in
    *"$CREDS_FILE"*) ok "el resumen dice donde estan las credenciales" ;;
    *) bad "el resumen dice donde estan las credenciales" ;;
esac
if have stat; then
    for f in "$SUMMARY_FILE" "$CREDS_FILE"; do
        m=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null || echo '?')
        is "$(basename "$f") queda en 0600" "600" "$m"
    done
fi

# wipe_secrets: borra los tres, o los conserva si se pide.
printf "CF_TOKEN='x'\n" > "$CONFIG_FILE"
printf "TUNNEL_TOKEN='y'\n" > "$TUNNEL_FILE"
KEEP_SECRETS=1
wipe_secrets
if [ -f "$CONFIG_FILE" ] && [ -f "$TUNNEL_FILE" ]; then
    ok "--keep-secrets conserva los ficheros"
else
    bad "--keep-secrets conserva los ficheros"
fi
# shellcheck disable=SC2034
KEEP_SECRETS=''
wipe_secrets
if [ -e "$CONFIG_FILE" ] || [ -e "$TUNNEL_FILE" ]; then
    bad "sin --keep-secrets se borran config.env y tunnel.env"
else
    ok "sin --keep-secrets se borran config.env y tunnel.env"
fi
# Sin ser root no se toca /etc/coolify-setup.env: no es nuestro.
printf 'CF_API_TOKEN=x\n' > "$SETUP_ENV_FILE"
IS_ROOT=''; wipe_secrets
if [ -f "$SETUP_ENV_FILE" ]; then ok "sin root no se toca /etc/coolify-setup.env"
else bad "sin root no se toca /etc/coolify-setup.env"; fi
# shellcheck disable=SC2034
IS_ROOT=1
wipe_secrets
if [ -e "$SETUP_ENV_FILE" ]; then bad "como root se borra el env con el token"
else ok "como root se borra el env con el token"; fi

# El orden del camino de exito es lo critico de #3: si se borra el token antes
# de marcar el completado y algo falla en medio, el servicio vuelve a arrancar
# y pide el token en bucle.
l_sum=$(grep -n '^write_summaries$' "$ROOT/setup.sh" | cut -d: -f1 | head -n1)
l_mark=$(grep -n '^touch "\$DONE_MARKER"$' "$ROOT/setup.sh" | cut -d: -f1 | head -n1)
l_wipe=$(grep -n '^wipe_secrets$' "$ROOT/setup.sh" | cut -d: -f1 | head -n1)
if [ -n "$l_sum" ] && [ -n "$l_mark" ] && [ -n "$l_wipe" ] \
   && [ "$l_sum" -lt "$l_mark" ] && [ "$l_mark" -lt "$l_wipe" ]; then
    ok "orden resumen -> marca de completado -> borrado"
else
    bad "orden resumen -> marca de completado -> borrado" \
        "resumen=${l_sum:-?} marca=${l_mark:-?} borrado=${l_wipe:-?}"
fi
for f in --keep-secrets --summary-no-secrets; do
    case "$(sh "$ROOT/setup.sh" --help 2>&1)" in
        *"$f"*) ok "$f aparece en la ayuda" ;;
        *) bad "$f aparece en la ayuda" ;;
    esac
done
fi

# --------------------------------------------------------------- resolucion
if want resolution; then
group "Resolucion de configuracion (contra la API simulada)"
if ! have python3; then
    skip "grupo entero" "hace falta python3 para el simulador"
else
    PORT=8799
    python3 "$HERE/cf-mock.py" "$PORT" >"$TMP/mock.log" 2>&1 &
    MOCK_PID=$!
    # Esperar a que escuche en vez de dormir a ciegas.
    # Esperar a que el simulador escuche. Nada de /dev/tcp: es de bash y este
    # script tambien tiene que correr en dash.
    i=0
    while [ $i -lt 100 ]; do
        if python3 -c "import socket,sys
s = socket.socket(); s.settimeout(0.2)
sys.exit(0 if s.connect_ex(('127.0.0.1', $PORT)) == 0 else 1)" 2>/dev/null; then
            break
        fi
        i=$((i+1)); sleep 0.1
    done

    # Estado limpio en cada llamada. Con un contador no valdria: setup() se
    # invoca dentro de $(...), o sea en un subshell, y el incremento no vuelve
    # al padre; todas las llamadas compartirian directorio y reutilizarian la
    # configuracion guardada de la anterior.
    setup() { # setup ARGS... -> salida combinada
        env CF_API_BASE="http://127.0.0.1:$PORT" \
            XDG_STATE_HOME="$(mktemp -d "$TMP/state.XXXXXX")" \
            HOME="$TMP" NO_COLOR=1 NO_GEOIP=1 \
            sh "$ROOT/setup.sh" "$@" 2>&1 || true
    }

    out=$(setup --cf-token=GOODTOKEN --domain=fompi.net --dry-run --non-interactive)
    case "$out" in
        *"Token de Cloudflare verificado"*) ok "verifica el token" ;;
        *) bad "verifica el token" "$(printf '%s' "$out" | tail -2)" ;;
    esac
    case "$out" in
        *"*.app.fompi.net"*) ok "compone el comodin de las apps" ;;
        *) bad "compone el comodin de las apps" ;;
    esac
    case "$out" in
        *"coolify.fompi.net"*) ok "compone el dominio del panel" ;;
        *) bad "compone el dominio del panel" ;;
    esac
    # Con una sola zona no debe preguntar: la deduce por API.
    out=$(setup --cf-token=GOODTOKEN --dry-run --non-interactive)
    case "$out" in
        *"nica zona del token"*) ok "deduce la zona sin preguntar" ;;
        *) bad "deduce la zona sin preguntar" "$(printf '%s' "$out" | tail -2)" ;;
    esac
    # Email deducido del nombre de la cuenta de Cloudflare.
    case "$out" in
        *"ferran.fompi@gmail.com"*) ok "deduce el email de la cuenta CF" ;;
        *) bad "deduce el email de la cuenta CF" ;;
    esac

    # Errores: siempre rc!=0 y mensaje accionable.
    st=0; out=$(env CF_API_BASE="http://127.0.0.1:$PORT" XDG_STATE_HOME="$TMP/s1" \
        HOME="$TMP" NO_COLOR=1 sh "$ROOT/setup.sh" --cf-token=MALO --dry-run \
        --non-interactive 2>&1) || st=$?
    is "token invalido sale con rc=1" "1" "$st"
    case "$out" in
        *"no es válido"*|*"no es valido"*) ok "token invalido: mensaje claro" ;;
        *) bad "token invalido: mensaje claro" "$(printf '%s' "$out" | tail -2)" ;;
    esac

    st=0; out=$(env CF_API_BASE="http://127.0.0.1:$PORT" XDG_STATE_HOME="$TMP/s2" \
        HOME="$TMP" NO_COLOR=1 sh "$ROOT/setup.sh" --dry-run --non-interactive 2>&1) || st=$?
    is "sin token sale con rc=1" "1" "$st"
    case "$out" in
        *--cf-token*) ok "sin token: dice que flag usar" ;;
        *) bad "sin token: dice que flag usar" ;;
    esac

    st=0; env XDG_STATE_HOME="$TMP/s3" HOME="$TMP" sh "$ROOT/setup.sh" --inventada \
        >/dev/null 2>&1 || st=$?
    is "opcion desconocida sale con rc=1" "1" "$st"

    # Precedencia: lo que se pasa ahora pisa lo guardado del intento anterior.
    S="$TMP/prec"
    env CF_API_BASE="http://127.0.0.1:$PORT" XDG_STATE_HOME="$S" HOME="$TMP" NO_COLOR=1 \
        sh "$ROOT/setup.sh" --cf-token=GOODTOKEN --domain=fompi.net \
        --app-subdomain=viejo --dry-run --non-interactive >/dev/null 2>&1 || true
    out=$(env CF_API_BASE="http://127.0.0.1:$PORT" XDG_STATE_HOME="$S" HOME="$TMP" NO_COLOR=1 \
        sh "$ROOT/setup.sh" --dry-run --non-interactive 2>&1 || true)
    case "$out" in
        *"*.viejo.fompi.net"*) ok "reintento reutiliza lo guardado" ;;
        *) bad "reintento reutiliza lo guardado" ;;
    esac
    out=$(env CF_API_BASE="http://127.0.0.1:$PORT" XDG_STATE_HOME="$S" HOME="$TMP" NO_COLOR=1 \
        sh "$ROOT/setup.sh" --app-subdomain=nuevo --dry-run --non-interactive 2>&1 || true)
    case "$out" in
        *"*.nuevo.fompi.net"*) ok "los argumentos pisan lo guardado" ;;
        *) bad "los argumentos pisan lo guardado" "$(printf '%s' "$out" | grep Apps || true)" ;;
    esac

    # #3: si el asistente falla a mitad, los secretos TIENEN que seguir ahi
    # para que el reintento no vuelva a pedir el token. Sin --dry-run y sin
    # root, el paso 'hostname' falla: es un fallo a mitad de verdad.
    F="$TMP/fallo"
    st=0; env CF_API_BASE="http://127.0.0.1:$PORT" XDG_STATE_HOME="$F" \
        HOME="$TMP" NO_COLOR=1 NO_GEOIP=1 sh "$ROOT/setup.sh" \
        --cf-token=GOODTOKEN --domain=fompi.net --skip-docker --skip-coolify \
        --skip-tunnel --non-interactive >/dev/null 2>&1 || st=$?
    is "un fallo a mitad sale con rc=1" "1" "$st"
    if [ -f "$F/coolify-setup/config.env" ]; then
        ok "tras un fallo a mitad config.env sigue ahi"
    else
        bad "tras un fallo a mitad config.env sigue ahi" "el reintento pediria el token otra vez"
    fi
    if grep -q "CF_TOKEN='GOODTOKEN'" "$F/coolify-setup/config.env" 2>/dev/null; then
        ok "y conserva el token para el reintento"
    else
        bad "y conserva el token para el reintento"
    fi
    if [ -e "$F/coolify-setup/completed" ]; then
        bad "tras un fallo a mitad NO hay marca de completado"
    else
        ok "tras un fallo a mitad NO hay marca de completado"
    fi

    kill "$MOCK_PID" 2>/dev/null; MOCK_PID=''
fi
fi

# ------------------------------------------------------------------ build
if want build; then
group "Generacion del user-data y de la ISO"
if ! have python3; then
    skip "grupo entero" "hace falta python3"
else
    OUT="$TMP/out"; mkdir -p "$OUT"
    sh "$ROOT/build-usb.sh" --out="$OUT" >/dev/null 2>&1
    if [ -f "$OUT/user-data" ] && [ -f "$OUT/meta-data" ]; then
        ok "genera user-data y meta-data"
    else
        bad "genera user-data y meta-data"
    fi
    if python3 -c 'import yaml' 2>/dev/null; then
        python3 - "$OUT/user-data" "$ROOT/setup.sh" "$ROOT/cloud-init/coolify-setup.service" <<'PY' > "$TMP/bres" 2>&1
import sys, yaml
gen, setup, unit = sys.argv[1], sys.argv[2], sys.argv[3]
d = yaml.safe_load(open(gen))["autoinstall"]
files = {w["path"]: w["content"] for w in d["user-data"]["write_files"]}
assert d["network"]["ethernets"]["any-eth"]["match"]["name"] == "e*", "netplan debe usar e*"
assert "late-commands" in d, "faltan late-commands"
assert d["identity"]["password"] == "!", "la cuenta debe nacer bloqueada"
emb = files["/usr/local/sbin/coolify-setup.sh"].rstrip("\n")
assert emb == open(setup).read().rstrip("\n"), "setup.sh incrustado difiere"
emu = files["/etc/systemd/system/coolify-setup.service"].rstrip("\n")
assert emu == open(unit).read().rstrip("\n"), "la unidad incrustada difiere"
assert not any(l.startswith("Before=") for l in emu.splitlines()), \
    "la unidad no debe llevar Before= de las getty"
print("OK")
PY
        if grep -q '^OK$' "$TMP/bres"; then
            ok "YAML valido, ficheros incrustados identicos, invariantes de #1"
        else
            bad "YAML valido e invariantes de #1" "$(head -3 "$TMP/bres")"
        fi
    else
        skip "validacion YAML" "pyyaml no instalado"
    fi

    # Sin --rescue-password la cuenta queda bloqueada; con ella, hash SHA-512.
    if grep -q 'password: "!"' "$OUT/user-data"; then
        ok "sin --rescue-password la cuenta nace bloqueada"
    else
        bad "sin --rescue-password la cuenta nace bloqueada"
    fi
    if sh "$ROOT/build-usb.sh" --out="$OUT" --rescue-password=probando1234 >/dev/null 2>&1; then
        if grep -qE 'password: "\$6\$' "$OUT/user-data"; then
            ok "--rescue-password genera un hash SHA-512"
        else
            bad "--rescue-password genera un hash SHA-512"
        fi
    else
        skip "--rescue-password" "no hay herramienta de hash en este equipo"
    fi

    # Los secretos horneados no deben acabar en el arbol de trabajo por error.
    sh "$ROOT/build-usb.sh" --out="$OUT" --cf-token=SECRETO-DE-PRUEBA >/dev/null 2>&1
    if grep -q 'CF_API_TOKEN=SECRETO-DE-PRUEBA' "$OUT/user-data"; then
        ok "el token se hornea en el user-data"
    else
        bad "el token se hornea en el user-data"
    fi
    if git -C "$ROOT" check-ignore -q cloud-init/user-data 2>/dev/null; then
        ok "cloud-init/user-data esta en .gitignore"
    else
        bad "cloud-init/user-data esta en .gitignore" "podria subirse un token"
    fi

    # --- Cordura de la ISO de entrada (#8) -------------------------------
    # No hacen falta ISOs de verdad de 3 GB: se fabrican con dd las senales
    # que mira build-usb.sh. Los tres casos mueren en las comprobaciones
    # baratas, antes de llamar a xorriso, asi que esto corre igual en un
    # equipo (o un runner) que no lo tenga instalado.
    mkiso() { # mkiso FICHERO [VOLUME_ID]
        dd if=/dev/zero of="$1" bs=1024 count=1024 2>/dev/null
        if [ -n "${2:-}" ]; then
            printf 'CD001' | dd of="$1" bs=1 seek=32769 conv=notrunc 2>/dev/null
            printf '%s' "$2" | dd of="$1" bs=1 seek=32808 conv=notrunc 2>/dev/null
        fi
    }
    build_iso() { # build_iso FICHERO -> salida combinada, nunca aborta
        sh "$ROOT/build-usb.sh" --out="$OUT" --iso="$1" \
            --iso-out="$TMP/no-deberia-existir.iso" 2>&1 || true
    }

    # 1. Un fichero que no es una ISO: ni siquiera lleva la marca ISO9660.
    mkiso "$TMP/basura.iso"
    st=0; sh "$ROOT/build-usb.sh" --out="$OUT" --iso="$TMP/basura.iso" \
        --iso-out="$TMP/no-deberia-existir.iso" >/dev/null 2>&1 || st=$?
    is "un fichero que no es ISO sale con rc=1" "1" "$st"
    out=$(build_iso "$TMP/basura.iso")
    case "$out" in
        *ISO9660*) ok "un fichero que no es ISO: lo dice sin jerga de xorriso" ;;
        *) bad "un fichero que no es ISO: lo dice sin jerga de xorriso" \
               "$(printf '%s' "$out" | tail -2)" ;;
    esac

    # 2. La ISO de escritorio se llama 'Ubuntu ...', sin 'Server'. Ahi no hay
    #    subiquity y el autoinstall no se aplicaria.
    mkiso "$TMP/escritorio.iso" 'Ubuntu 24.04.4 LTS amd64'
    out=$(build_iso "$TMP/escritorio.iso")
    case "$out" in
        *Desktop*Server*|*Server*Desktop*) ok "ISO de escritorio: pide la de Server" ;;
        *) bad "ISO de escritorio: pide la de Server" "$(printf '%s' "$out" | tail -2)" ;;
    esac
    case "$out" in
        *subiquity*) ok "ISO de escritorio: explica por que no vale" ;;
        *) bad "ISO de escritorio: explica por que no vale" ;;
    esac

    # 3. Una Server de 1 MiB es una descarga a medias.
    mkiso "$TMP/truncada.iso" 'Ubuntu-Server 24.04.4 LTS amd64'
    out=$(build_iso "$TMP/truncada.iso")
    case "$out" in
        *"a medias"*) ok "descarga truncada: se detecta por el tamano" ;;
        *) bad "descarga truncada: se detecta por el tamano" "$(printf '%s' "$out" | tail -2)" ;;
    esac

    # Lo importante de #8: nada de esto llega a tocar la ISO de salida.
    if [ -e "$TMP/no-deberia-existir.iso" ]; then
        bad "una ISO invalida no destruye la salida anterior"
    else
        ok "una ISO invalida no destruye la salida anterior"
    fi

    # Verificar sin ISO que verificar es un error de uso, no un silencio.
    st=0; sh "$ROOT/build-usb.sh" --out="$OUT" --verify-iso >/dev/null 2>&1 || st=$?
    is "--verify-iso sin --iso sale con rc=1" "1" "$st"

    # El helper de hash tiene que coincidir con la herramienta del sistema.
    eval "$(sed -n '/^sha256_of() {/,/^}/p' "$ROOT/build-usb.sh")"
    ref=''
    if have sha256sum; then ref=$(sha256sum "$TMP/basura.iso" | awk '{print $1}')
    elif have shasum;  then ref=$(shasum -a 256 "$TMP/basura.iso" | awk '{print $1}')
    fi
    if [ -n "$ref" ]; then
        is "sha256_of coincide con la herramienta del sistema" "$ref" "$(sha256_of "$TMP/basura.iso")"
    else
        skip "sha256_of" "no hay sha256sum ni shasum"
    fi
fi
fi

# ----------------------------------------------------------- late-commands
if want latecommands; then
group "Bloque late-commands (regresion de #1)"
if ! python3 -c 'import yaml' 2>/dev/null; then
    skip "grupo entero" "hace falta pyyaml"
else
    OUT="$TMP/lc"; mkdir -p "$OUT"
    sh "$ROOT/build-usb.sh" --out="$OUT" >/dev/null 2>&1
    python3 -c "
import yaml,sys
d=yaml.safe_load(open('$OUT/user-data'))['autoinstall']
open('$TMP/lc.sh','w').write(d['late-commands'][0])
"
    for s in sh dash bash; do
        have "$s" || continue
        if $s -n "$TMP/lc.sh" 2>/dev/null; then ok "el bloque es $s valido"
        else bad "el bloque es $s valido"; fi
    done
    # Critico: si devuelve != 0 aborta la instalacion entera.
    st=0; (cd "$TMP" && sh "$TMP/lc.sh" >/dev/null 2>&1) || st=$?
    is "devuelve 0 aunque no encuentre /cdrom/cidata" "0" "$st"

    # Prueba funcional contra un /cdrom/cidata y un /target simulados.
    FAKE="$TMP/fake"; mkdir -p "$FAKE/cdrom/cidata" "$FAKE/target"
    cp "$ROOT/setup.sh" "$FAKE/cdrom/cidata/coolify-setup.sh"
    cp "$ROOT/cloud-init/coolify-setup.service" "$FAKE/cdrom/cidata/"
    printf 'CF_API_TOKEN=x\n' > "$FAKE/cdrom/cidata/coolify-setup.env"
    # Se reemplaza la linea entera del bucle: sustituir '/cdrom/cidata' suelto
    # tocaria tambien '/media/cdrom/cidata' y dejaria rutas absurdas.
    sed -e "s#^for d in .*; do#for d in $FAKE/cdrom/cidata; do#" \
        -e "s#/target#$FAKE/target#g" "$TMP/lc.sh" > "$TMP/lc-fake.sh"
    sh "$TMP/lc-fake.sh" >/dev/null 2>&1 || true
    if [ -x "$FAKE/target/usr/local/sbin/coolify-setup.sh" ]; then
        ok "instala el script y queda ejecutable"
    else
        bad "instala el script y queda ejecutable"
    fi
    LINK="$FAKE/target/etc/systemd/system/multi-user.target.wants/coolify-setup.service"
    if [ -L "$LINK" ]; then ok "crea el enlace de activacion"; else bad "crea el enlace de activacion"; fi
    if [ -f "$LINK" ]; then ok "el enlace resuelve a la unidad"; else bad "el enlace resuelve a la unidad"; fi
    if have stat; then
        m=$(stat -c %a "$FAKE/target/etc/coolify-setup.env" 2>/dev/null \
            || stat -f %Lp "$FAKE/target/etc/coolify-setup.env" 2>/dev/null || echo '?')
        is "el env con el token queda en 0600" "600" "$m"
    fi
fi
fi

# ------------------------------------------------------------------ total
printf '\n%s%d ok, %d fallos, %d omitidos%s\n' "$B" "$PASS" "$FAIL" "$SKIP" "$Z"
[ "$FAIL" -eq 0 ] || exit 1
