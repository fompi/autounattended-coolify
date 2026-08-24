#!/bin/sh
# tests/run.sh — suite de pruebas del proyecto.
#
# Sin dependencias obligatorias mas alla de sh y python3. Lo que falte se
# omite anunciandolo, para que la suite corra igual en un portatil que en CI.
#
#   sh tests/run.sh              # todo
#   sh tests/run.sh json build   # solo esos grupos
#
# Grupos: syntax json validators timezone secrets installer resolution tunnel
#         build latecommands
#
# Lo que NO cubre, y hay que probar a mano en una VM: el arranque real desde
# la ISO, y la conexion real de cloudflared contra el edge de Cloudflare. Lo
# que si se cubre del tunel es el resto: la logica de espera, reintento y
# fallo del paso tunnel_service, y el nombre estable del tunel entre
# reinstalaciones, todo contra el simulador.

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
WANTED="${*:-syntax json validators timezone secrets installer resolution tunnel build latecommands}"
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
    TUNNEL_NAME='coolify-coolify.fompi.net'
    INSTALLER_USER='installer'
    INSTALLER_STATE='bloqueada, fuera de sudo y con shell /usr/sbin/nologin'
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
case "$(cat "$SUMMARY_FILE")" in
    *'Cuenta de rescate'*'fuera de sudo'*) ok "el resumen dice como quedo la cuenta de rescate" ;;
    *) bad "el resumen dice como quedo la cuenta de rescate" ;;
esac
# Sin el nombre del tunel no hay forma de saber luego cual de los de la cuenta
# es el de este equipo (#15).
case "$(cat "$SUMMARY_FILE")" in
    *'coolify-coolify.fompi.net'*) ok "el resumen dice como se llama el tunel" ;;
    *) bad "el resumen dice como se llama el tunel" ;;
esac
case "$(cat "$SUMMARY_FILE")" in
    *'tampoco con --reset'*) ok "y avisa de que --reset no borra nada en Cloudflare" ;;
    *) bad "y avisa de que --reset no borra nada en Cloudflare" ;;
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

# -------------------------------------------------------------- installer
if want installer; then
group "Cuenta de rescate 'installer' (#9)"
eval "$(sed -n '/^groups_have_admin() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^shadow_hash_is_real() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^shadow_field() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^nologin_shell() {/,/^}/p' "$ROOT/setup.sh")"

chk() { # chk descripcion fn arg esperado(0|1)
    if "$2" "$3"; then got=0; else got=1; fi
    if [ "$got" = "$4" ]; then ok "$1"; else bad "$1" "esperaba rc=$4"; fi
}
chk "grupo sudo manda"            groups_have_admin "usuario docker sudo" 0
chk "grupo wheel manda"           groups_have_admin "wheel" 0
chk "grupo admin manda"           groups_have_admin "staff admin" 0
chk "sin grupo de mando"          groups_have_admin "usuario docker users" 1
chk "lista vacia no manda"        groups_have_admin "" 1
# Regresion: 'sudoers' no es 'sudo'.
chk "sudoers no cuela por sudo"   groups_have_admin "sudoers pseudo" 1

chk "hash sha512 es utilizable"   shadow_hash_is_real '$6$sal$hash' 0
chk "hash yescrypt es utilizable" shadow_hash_is_real '$y$j9T$sal$hash' 0
chk "vacio no es credencial"      shadow_hash_is_real '' 1
chk "cuenta bloqueada con !"      shadow_hash_is_real '!' 1
chk "bloqueada con !!"            shadow_hash_is_real '!!' 1
chk "bloqueada conservando hash"  shadow_hash_is_real '!$6$sal$hash' 1
chk "deshabilitada con *"         shadow_hash_is_real '*' 1
chk "x de passwd no es hash"      shadow_hash_is_real 'x' 1

SH="$TMP/shadow"
cat > "$SH" <<'SHADOW'
root:!:19000:0:99999:7:::
admin:$6$sal$hash:19000:0:99999:7:::
installer:!:19000:0:99999:7:::
SHADOW
is "shadow_field lee el hash"        '$6$sal$hash' "$(shadow_field "$SH" admin)"
is "shadow_field ve la bloqueada"    '!'           "$(shadow_field "$SH" installer)"
is "shadow_field con usuario ausente" ''           "$(shadow_field "$SH" nadie)"
is "shadow_field sin fichero"        ''            "$(shadow_field "$TMP/no-hay" admin)"

NS=$(nologin_shell)
case "$NS" in
    /*nologin|/*false) ok "nologin_shell devuelve una shell que no deja entrar" ;;
    *) bad "nologin_shell devuelve una shell que no deja entrar" "$NS" ;;
esac

# El paso tiene que ser el ultimo: mientras algo pueda fallar, 'installer' es
# la unica via de entrada garantizada.
last=$(grep -n '^run_step ' "$ROOT/setup.sh" | tail -n1)
case "$last" in
    *retire_installer*) ok "retire_installer es el ultimo run_step" ;;
    *) bad "retire_installer es el ultimo run_step" "el ultimo es: $last" ;;
esac
l_tun=$(grep -n '^run_step tunnel_service' "$ROOT/setup.sh" | cut -d: -f1 | head -n1)
l_ret=$(grep -n '^run_step retire_installer' "$ROOT/setup.sh" | cut -d: -f1 | head -n1)
if [ -n "$l_tun" ] && [ -n "$l_ret" ] && [ "$l_tun" -lt "$l_ret" ]; then
    ok "va despues de tunnel_service"
else
    bad "va despues de tunnel_service" "tunnel=${l_tun:-?} retire=${l_ret:-?}"
fi

# Y NO puede abortar la instalacion: si aborta, el usuario se queda sin el
# fichero de credenciales, que es mucho peor que una cuenta de rescate viva.
sed -n '/^do_retire_installer() {/,/^}/p' "$ROOT/setup.sh" > "$TMP/retire.sh"
if [ -s "$TMP/retire.sh" ]; then ok "do_retire_installer se puede extraer"
else bad "do_retire_installer se puede extraer"; fi
n=$(grep -cE '(^|[^_[:alnum:]])die ' "$TMP/retire.sh" || true)
is "no llama a die" "0" "$n"
n=$(grep -cE '^[[:space:]]*return [1-9]' "$TMP/retire.sh" || true)
is "todos los return son 0" "0" "$n"
# La shell nologin es imprescindible: 'usermod -L' no impide entrar por clave.
if grep -q 'usermod -s' "$TMP/retire.sh"; then
    ok "ademas de bloquear, cambia la shell a nologin"
else
    bad "ademas de bloquear, cambia la shell a nologin" "usermod -L no cierra el SSH por clave"
fi

for f in --keep-rescue --purge-installer --installer-user; do
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

# ----------------------------------------------------------------- tunel
if want tunnel; then
group "Tunel: conectado de verdad (#6) y nombre estable (#15)"
if ! have python3; then
    skip "grupo entero" "hace falta python3 para el simulador"
else
    # mock_up PUERTO [args...] — arranca el simulador y espera a que escuche.
    mock_up() {
        _mp=$1; shift
        python3 "$HERE/cf-mock.py" "$_mp" "$@" >>"$TMP/mock-tunnel.log" 2>&1 &
        MOCK_PID=$!
        _i=0
        while [ $_i -lt 100 ]; do
            if python3 -c "import socket,sys
s = socket.socket(); s.settimeout(0.2)
sys.exit(0 if s.connect_ex(('127.0.0.1', $_mp)) == 0 else 1)" 2>/dev/null; then
                return 0
            fi
            _i=$((_i+1)); sleep 0.1
        done
        return 1
    }
    mock_down() {
        [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
        MOCK_PID=''
    }
    # api METODO RUTA [CUERPO] -> cuerpo por stdout. Para preparar y comprobar
    # el estado del simulador sin pasar por setup.sh.
    api() {
        python3 - "$1" "http://127.0.0.1:$PORT$2" "${3:-}" <<'PYEOF'
import sys, urllib.request, urllib.error
m, url, body = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request(url, data=body.encode() if body else None, method=m,
                             headers={"Authorization": "Bearer GOODTOKEN",
                                      "Content-Type": "application/json"})
try:
    sys.stdout.write(urllib.request.urlopen(req, timeout=10).read().decode())
except urllib.error.HTTPError as e:
    sys.stdout.write(e.read().decode())
PYEOF
    }
    jget() { python3 -c "import json,sys;d=json.load(sys.stdin)$1;print(d)"; }

    # Las funciones de verificacion, sueltas: son puras salvo por la llamada
    # HTTP, y asi se prueban de verdad contra el simulador en vez de comprobar
    # que el texto del script menciona una URL.
    load_tunnel_fns() {
        eval "$(awk '/^JSON_PY=.$/,/^.$/' "$ROOT/setup.sh")"
        eval "$(sed -n '/^json_get() {/,/^}/p' "$ROOT/setup.sh")"
        eval "$(sed -n '/^cf_api() {/,/^}/p' "$ROOT/setup.sh")"
        eval "$(sed -n '/^tunnel_status() {/,/^}/p' "$ROOT/setup.sh")"
        eval "$(sed -n '/^wait_tunnel_healthy() {/,/^}/p' "$ROOT/setup.sh")"
        eval "$(sed -n '/^tcp_probe() {/,/^}/p' "$ROOT/setup.sh")"
        setup_json() { :; }
    }
    load_tunnel_fns
    # Consumidas por las funciones cargadas con eval, que el analizador no ve.
    # shellcheck disable=SC2034
    PY=python3
    # shellcheck disable=SC2034
    JSON_MODE=py
    # shellcheck disable=SC2034
    UA=pruebas
    # shellcheck disable=SC2034
    CF_TOKEN=GOODTOKEN
    # shellcheck disable=SC2034
    ACCOUNT_ID=acct-1
    # shellcheck disable=SC2034
    HTTP=python3
    # shellcheck disable=SC2034
    have curl && HTTP=curl

    # Un sondeo unico con suerte no prueba nada: hace falta que el tunel tarde
    # en conectar y que la espera aguante. flaky:3 = tres 'inactive' y luego si.
    PORT=8801
    if ! mock_up "$PORT" --tunnel-status flaky:3; then
        bad "el simulador arranca (flaky)" "no llego a escuchar en $PORT"
    else
        CF_API="http://127.0.0.1:$PORT"
        TUNNEL_ID=$(api POST /accounts/acct-1/cfd_tunnel '{"name":"coolify-x"}' | jget '["result"]["id"]')
        TUNNEL_HEALTH_TIMEOUT=6; TUNNEL_HEALTH_INTERVAL=1
        st=0; wait_tunnel_healthy || st=$?
        is "con reintentos acaba viendolo conectado" "0" "$st"
        is "y se queda con el estado bueno" "healthy" "$TUNNEL_HEALTH"
        n=$(api GET /__state | jget '["result"]["status_queries"]')
        if [ "$n" -ge 4 ]; then
            ok "consulto $n veces: hubo reintentos de verdad"
        else
            bad "hubo reintentos de verdad" "solo $n consultas"
        fi
        mock_down
    fi

    # Token que no vale: el tunel nunca conecta. El paso tiene que FALLAR, y
    # hacerlo dentro del tiempo maximo, no colgarse.
    PORT=8802
    if ! mock_up "$PORT" --tunnel-status inactive; then
        bad "el simulador arranca (inactive)" "no llego a escuchar en $PORT"
    else
        CF_API="http://127.0.0.1:$PORT"
        TUNNEL_ID=$(api POST /accounts/acct-1/cfd_tunnel '{"name":"coolify-x"}' | jget '["result"]["id"]')
        TUNNEL_HEALTH_TIMEOUT=2; TUNNEL_HEALTH_INTERVAL=1
        t0=$(date +%s)
        st=0; wait_tunnel_healthy || st=$?
        t1=$(date +%s)
        is "si nunca conecta, el paso falla" "1" "$st"
        is "y no da por bueno el 'inactive'" "inactive" "$TUNNEL_HEALTH"
        if [ $((t1 - t0)) -le 20 ]; then
            ok "respeta el tiempo maximo configurado ($((t1 - t0))s)"
        else
            bad "respeta el tiempo maximo configurado" "tardo $((t1 - t0))s con TUNNEL_HEALTH_TIMEOUT=2"
        fi
        # tcp_probe distingue un puerto que escucha de uno que no: es lo que
        # separa 'cortafuegos de salida' de 'token invalido' en el diagnostico.
        st=0; tcp_probe 127.0.0.1 "$PORT" || st=$?
        is "tcp_probe ve el puerto abierto" "0" "$st"
        mock_down
        st=0; tcp_probe 127.0.0.1 "$PORT" || st=$?
        is "tcp_probe ve el puerto cerrado" "1" "$st"
    fi

    # 'degraded' conecta y pasa trafico: vale, pero hay que avisar.
    PORT=8803
    if ! mock_up "$PORT" --tunnel-status degraded; then
        bad "el simulador arranca (degraded)" "no llego a escuchar en $PORT"
    else
        CF_API="http://127.0.0.1:$PORT"
        TUNNEL_ID=$(api POST /accounts/acct-1/cfd_tunnel '{"name":"coolify-x"}' | jget '["result"]["id"]')
        TUNNEL_HEALTH_TIMEOUT=2; TUNNEL_HEALTH_INTERVAL=1
        st=0; wait_tunnel_healthy || st=$?
        is "'degraded' se acepta" "0" "$st"
        is "pero queda registrado como tal" "degraded" "$TUNNEL_HEALTH"
        mock_down
    fi

    # Si no se puede ni preguntar, se avisa; abortar aqui seria inventarse un
    # tercer modo de fallo tardio por no haber podido comprobar nada.
    # shellcheck disable=SC2034
    CF_API="http://127.0.0.1:8804"
    # shellcheck disable=SC2034
    TUNNEL_ID=no-existe
    # shellcheck disable=SC2034
    TUNNEL_HEALTH_TIMEOUT=0
    # shellcheck disable=SC2034
    TUNNEL_HEALTH_INTERVAL=1
    st=0; wait_tunnel_healthy || st=$?
    is "sin API que responda: ni bien ni fallo, indeterminado" "2" "$st"

    # Invariantes del paso, sobre el texto: lo que no se puede ejecutar aqui.
    sed -n '/^do_tunnel_service() {/,/^}/p' "$ROOT/setup.sh" > "$TMP/svc.sh"
    if grep -q 'wait_tunnel_healthy' "$TMP/svc.sh"; then
        ok "el paso no se conforma con 'systemctl is-active'"
    else
        bad "el paso no se conforma con 'systemctl is-active'" "no llama a wait_tunnel_healthy"
    fi
    if grep -q 'sleep 5' "$TMP/svc.sh"; then
        bad "ya no hay 'sleep 5 y a ver que dice is-active'" "sigue el sleep a ciegas"
    else
        ok "ya no hay 'sleep 5 y a ver que dice is-active'"
    fi
    # El segundo falso positivo: un cloudflared vivo del intento anterior, con
    # el token de OTRO tunel, no puede darse por bueno.
    if grep -q 'cloudflared_runs_our_tunnel' "$TMP/svc.sh"; then
        ok "la rama 'ya esta corriendo' comprueba de que tunel es"
    else
        bad "la rama 'ya esta corriendo' comprueba de que tunel es"
    fi
    sed -n '/^cloudflared_runs_our_tunnel() {/,/^}/p' "$ROOT/setup.sh" > "$TMP/runs.sh"
    if grep -q 'TUNNEL_TOKEN' "$TMP/runs.sh"; then
        ok "y lo comprueba por el token instalado en la unidad"
    else
        bad "y lo comprueba por el token instalado en la unidad"
    fi
    # Tres causas, tres soluciones. Sin distinguirlas el usuario culpa al token.
    sed -n '/^tunnel_diagnose() {/,/^}/p' "$ROOT/setup.sh" > "$TMP/diag.sh"
    for pat in 'salida a internet' '7844' 'token del'; do
        if grep -q "$pat" "$TMP/diag.sh"; then
            ok "el diagnostico distingue '$pat'"
        else
            bad "el diagnostico distingue '$pat'"
        fi
    done
    case "$(sh "$ROOT/setup.sh" --help 2>&1)" in
        *TUNNEL_HEALTH_TIMEOUT*) ok "TUNNEL_HEALTH_TIMEOUT aparece en la ayuda" ;;
        *) bad "TUNNEL_HEALTH_TIMEOUT aparece en la ayuda" ;;
    esac

    # ---- #15: el nombre del tunel no puede depender del hostname ----------
    eval "$(sed -n '/^tunnel_name() {/,/^}/p' "$ROOT/setup.sh")"
    is "el nombre sale del FQDN del panel" "coolify-coolify.fompi.net" \
        "$(tunnel_name coolify.fompi.net)"
    is "no depende del hostname" "$(tunnel_name coolify.fompi.net)" \
        "$(tunnel_name coolify.fompi.net)"
    is "en minusculas" "coolify-panel.fompi.net" "$(tunnel_name PANEL.Fompi.NET)"
    largo=$(tunnel_name "$(printf 'abcdefghij%.0s' 1 2 3 4 5 6 7 8).net")
    is "recortado al limite de Cloudflare" "63" "${#largo}"
    case "$(tunnel_name 'raro/$ nombre.net')" in
        *' '*|*'/'*|*'$'*) bad "descarta los caracteres que no valen" ;;
        *) ok "descarta los caracteres que no valen" ;;
    esac
    case "$(tunnel_name coolify.fompi.net)" in
        coolify-*) ok "lleva prefijo reconocible" ;;
        *) bad "lleva prefijo reconocible" ;;
    esac

    # Llegar al paso del tunel sin ser root: se premarcan los pasos que tocan
    # el sistema (antes y despues) y se deja correr el resto de verdad. Es mas
    # honesto que probar la funcion suelta, porque se ejerce el script entero:
    # resolucion, creacion del tunel, ingress y DNS contra el simulador.
    HOMEDIR="$TMP/home"; mkdir -p "$HOMEDIR"
    run_hasta_tunel() { # run_hasta_tunel DIRESTADO ARGS...
        _sd=$1; shift
        mkdir -p "$_sd/coolify-setup"
        for _st in wifi hostname timezone admin_user docker coolify \
                   coolify_domain coolify_register cloudflared_bin \
                   tunnel_service retire_installer; do
            : > "$_sd/coolify-setup/step.$_st"
        done
        env CF_API_BASE="http://127.0.0.1:$PORT" XDG_STATE_HOME="$_sd" \
            HOME="$HOMEDIR" NO_COLOR=1 NO_GEOIP=1 \
            sh "$ROOT/setup.sh" "$@" 2>&1 || true
    }
    n_tuneles() { api GET /accounts/acct-1/cfd_tunnel | jget '["result_info"]["count"]'; }
    nombres_tuneles() { api GET /accounts/acct-1/cfd_tunnel \
        | python3 -c 'import json,sys;print(",".join(sorted(t["name"] for t in json.load(sys.stdin)["result"])))'; }

    PORT=8805
    if ! mock_up "$PORT"; then
        bad "el simulador arranca (#15)" "no llego a escuchar en $PORT"
    else
        # El listado sin filtro tiene que devolver lo que hay, no una lista
        # vacia: es como se comprueba que no quedan tuneles huerfanos.
        is "el simulador parte sin tuneles" "0" "$(n_tuneles)"

        out=$(run_hasta_tunel "$TMP/i1" --cf-token=GOODTOKEN --domain=fompi.net \
            --hostname=primera --non-interactive --keep-secrets)
        is "primera instalacion: un tunel" "1" "$(n_tuneles)"
        is "con el nombre derivado del FQDN" "coolify-coolify.fompi.net" "$(nombres_tuneles)"
        case "$out" in
            *"Túnel creado"*) ok "la primera lo crea" ;;
            *) bad "la primera lo crea" "$(printf '%s' "$out" | tail -3)" ;;
        esac
        if grep -q "TUNNEL_NAME='coolify-coolify.fompi.net'" "$TMP/i1/coolify-setup/tunnel.env"; then
            ok "el nombre queda anotado en tunnel.env"
        else
            bad "el nombre queda anotado en tunnel.env" \
                "$(sed 's/=.*/=.../' "$TMP/i1/coolify-setup/tunnel.env" 2>/dev/null)"
        fi

        # Lo de #15: reinstalar el mismo despliegue con otro hostname. Antes
        # esto dejaba el tunel viejo huerfano en la cuenta.
        out=$(run_hasta_tunel "$TMP/i2" --cf-token=GOODTOKEN --domain=fompi.net \
            --hostname=segunda --non-interactive --keep-secrets)
        is "cambiar el hostname NO crea un tunel nuevo" "1" "$(n_tuneles)"
        is "y sigue siendo el mismo" "coolify-coolify.fompi.net" "$(nombres_tuneles)"
        case "$out" in
            *"Reutilizando el túnel existente"*) ok "lo dice: reutiliza el existente" ;;
            *) bad "lo dice: reutiliza el existente" "$(printf '%s' "$out" | tail -3)" ;;
        esac
        mock_down
    fi

    # Compatibilidad hacia atras: una instalacion anterior a #15 tiene el tunel
    # con el nombre viejo. Hay que reutilizarlo, no crear otro al lado: los
    # CNAME en uso apuntan a ese.
    PORT=8806
    if ! mock_up "$PORT"; then
        bad "el simulador arranca (heredado)" "no llego a escuchar en $PORT"
    else
        api POST /accounts/acct-1/cfd_tunnel '{"name":"coolify-vieja"}' >/dev/null
        is "el simulador tiene el tunel heredado" "1" "$(n_tuneles)"
        out=$(run_hasta_tunel "$TMP/i3" --cf-token=GOODTOKEN --domain=fompi.net \
            --hostname=vieja --non-interactive --keep-secrets)
        is "no se crea uno al lado del heredado" "1" "$(n_tuneles)"
        is "se conserva el nombre heredado" "coolify-vieja" "$(nombres_tuneles)"
        case "$out" in
            *"heredado"*) ok "lo dice: reutiliza el heredado" ;;
            *) bad "lo dice: reutiliza el heredado" "$(printf '%s' "$out" | tail -3)" ;;
        esac
        if grep -q "TUNNEL_NAME='coolify-vieja'" "$TMP/i3/coolify-setup/tunnel.env"; then
            ok "y anota el nombre que se usa de verdad"
        else
            bad "y anota el nombre que se usa de verdad"
        fi
        mock_down
    fi

    # --reset borra estado local; que no se entienda que limpia Cloudflare.
    ayuda=$(sh "$ROOT/setup.sh" --help 2>&1)
    case "$ayuda" in
        *'--reset'*'No toca'*'Cloudflare'*) ok "la ayuda de --reset dice que no toca Cloudflare" ;;
        *) bad "la ayuda de --reset dice que no toca Cloudflare" ;;
    esac
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
