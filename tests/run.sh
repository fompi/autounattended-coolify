#!/bin/sh
# tests/run.sh — suite de pruebas del proyecto.
#
# Sin dependencias obligatorias mas alla de sh y python3. Lo que falte se
# omite anunciandolo, para que la suite corra igual en un portatil que en CI.
#
#   sh tests/run.sh              # todo
#   sh tests/run.sh json build   # solo esos grupos
#
# Grupos: syntax json validators timezone secrets installer registro cortafuegos mantenimiento descargas version resolution tunnel build latecommands
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
WANTED="${*:-syntax json validators timezone secrets installer registro cortafuegos mantenimiento descargas version resolution tunnel build latecommands}"
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
eval "$(sed -n '/^state_set() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^state_get() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^comp_version() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^version_table() {/,/^}/p' "$ROOT/setup.sh")"
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
    VERSION='1.0-prueba'
    VERSION_SOURCE='horneada al construir'
    CLOUDFLARED_VERSION='2026.8.2'
    JQ_VERSION='1.7.1'
    CLOUDFLARED_BIN=''
    VERSION_FILE="$SEC/coolify-setup.version"
    SETUP_ENV_FILE="$SEC/etc-env"
    SUMMARY_FILE="$SEC/resumen.txt"
    CREDS_FILE="$SEC/credenciales.txt"
    CONFIG_FILE="$SEC/config.env"
    TUNNEL_FILE="$SEC/tunnel.env"
    STATE_DIR="$SEC/state"
    FIREWALL_UNIT='/etc/systemd/system/coolify-firewall.service'
    mkdir -p "$STATE_DIR"
}
fake_config
state_set coolify_register registrado

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

# ---------------------------------------------------------------- registro
if want registro; then
group "Registro del primer usuario de Coolify (#7)"
eval "$(sed -n '/^state_set() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^state_get() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^register_form_offered() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^do_coolify_register() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^write_summaries() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^comp_version() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^version_table() {/,/^}/p' "$ROOT/setup.sh")"
note() { :; }
warn() { :; }
_ts() { echo '2026-01-01 00:00:00'; }
svc_state() { echo activo; }

# El formulario de registro y el de login. Los DOS llevan name="_token": ese
# era justo el error, dar por bueno cualquier pagina que lo tuviera.
FORM_REG='<form action="/register" method="POST"><input name="_token" value="TOK123"><input name="email"><input name="password"><input name="password_confirmation"></form>'
FORM_LOGIN='<form action="/login" method="POST"><input name="_token" value="TOK999"><input name="email"><input name="password"></form>'
FORM_REG_ERR='<div>El email ya esta en uso</div>'"$FORM_REG"

chk_form() { # chk_form descripcion html esperado(0|1)
    if register_form_offered "$2"; then got=0; else got=1; fi
    if [ "$got" = "$3" ]; then ok "$1"; else bad "$1" "esperaba rc=$3"; fi
}
chk_form "reconoce el formulario de registro"     "$FORM_REG"       0
chk_form "el login NO cuela como registro"        "$FORM_LOGIN"     1
chk_form "una respuesta vacia no es formulario"   ""                1
chk_form "un redirect sin cuerpo tampoco"         '<html></html>'   1
chk_form "el formulario con errores sigue siendolo" "$FORM_REG_ERR" 0

# --- do_coolify_register contra un curl de mentira ------------------------
# Se simula la conversacion entera: GET /register, POST, y el GET de
# comprobacion. Asi se prueba la deteccion de exito de verdad, que es lo que
# denuncia #7, y no que el texto del script mencione una URL.
REGD="$TMP/reg"
curl() {
    _out=''; _prev=''
    for _a in "$@"; do
        [ "$_prev" = "-o" ] && _out=$_a
        _prev=$_a
    done
    _n=$(cat "$REGD/n" 2>/dev/null || echo 0); _n=$((_n+1)); printf '%s\n' "$_n" > "$REGD/n"
    if [ -n "$_out" ]; then
        cat "$REGD/resp.$_n" > "$_out" 2>/dev/null || :
        cat "$REGD/code" 2>/dev/null || printf '200'
    else
        cat "$REGD/resp.$_n" 2>/dev/null || :
    fi
    return 0
}
# Consumidas por do_coolify_register, cargada con eval: el analizador no lo ve.
# shellcheck disable=SC2034
UA='pruebas'
# shellcheck disable=SC2034
ADMIN_USER='admin'
# shellcheck disable=SC2034
COOLIFY_EMAIL='a@b.com'
# shellcheck disable=SC2034
COOLIFY_PASSWORD='CLAVECOOLIFY456'
# shellcheck disable=SC2034
HTTP='curl'

# reg_run CODIGO_POST HTML_1 HTML_3 -> deja el estado en $STATE_DIR
reg_run() {
    rm -rf "$REGD"; mkdir -p "$REGD"
    printf '%s' "$1" > "$REGD/code"
    printf '%s' "$2" > "$REGD/resp.1"
    printf '%s' "$3" > "$REGD/resp.3"
    rm -f "$STATE_DIR/state.coolify_register"
    # En subshell y con 'ok' anulada: do_coolify_register llama a ok() y aqui
    # esa funcion es el contador de pruebas. El estado viaja por disco.
    ( ok() { :; }; do_coolify_register ) >/dev/null 2>&1
}
STATE_DIR="$TMP/reg-state"; mkdir -p "$STATE_DIR"
WORK_DIR="$TMP/reg-work";   mkdir -p "$WORK_DIR"
SKIP_COOLIFY=''
SKIP_COOLIFY_REGISTER=''

# El caso que denuncia #7: 200 con el formulario devuelto y errores dentro.
reg_run 200 "$FORM_REG" "$FORM_REG_ERR"
is "un 200 con el formulario devuelto NO es exito" "pendiente" "$(state_get coolify_register)"

# Exito de verdad: /register deja de ofrecer formulario.
reg_run 200 "$FORM_REG" "$FORM_LOGIN"
is "un 200 con /register ya cerrado si es exito" "registrado" "$(state_get coolify_register)"

# 302 con el formulario todavia en pie: tampoco vale.
reg_run 302 "$FORM_REG" "$FORM_REG"
is "ni un 302 si el formulario sigue ahi" "pendiente" "$(state_get coolify_register)"

# Ya habia usuario: ni se intenta, y se distingue de "pendiente".
reg_run 200 "$FORM_LOGIN" "$FORM_LOGIN"
is "si ya hay usuario lo dice, no lo confunde con pendiente" "ya-existia" "$(state_get coolify_register)"

# Sin poder releer /register no se afirma nada.
reg_run 200 "$FORM_REG" ""
is "sin comprobacion posible, pendiente" "pendiente" "$(state_get coolify_register)"

SKIP_COOLIFY_REGISTER=1
reg_run 200 "$FORM_REG" "$FORM_LOGIN"
is "--skip-coolify-register no registra nada" "omitido" "$(state_get coolify_register)"
# shellcheck disable=SC2034
SKIP_COOLIFY_REGISTER=''
unset -f curl

# --- el resumen distingue los tres estados (mas el omitido) ---------------
REGS="$TMP/reg-sum"; mkdir -p "$REGS"
# Consumidas por write_summaries, cargada con eval.
# shellcheck disable=SC2034
sum_config() {
    NEW_HOSTNAME='maquina'; TIMEZONE='Europe/Madrid'; TIMEZONE_SOURCE='sistema'
    ADMIN_USER='admin'; ADMIN_PASSWORD='CLAVEADMIN123'; SSH_KEY=''
    COOLIFY_FQDN='coolify.fompi.net'; COOLIFY_EMAIL='a@b.com'
    COOLIFY_PASSWORD='CLAVECOOLIFY456'; SKIP_COOLIFY=''
    APP_SUBDOMAIN='app'; ROOT_DOMAIN='fompi.net'; APP_WILDCARD='*.app.fompi.net'
    TUNNEL_ID='tid'; TUNNEL_NAME='coolify-coolify.fompi.net'
    INSTALLER_USER='installer'; INSTALLER_STATE='bloqueada'
    LOG_FILE="$REGS/log"; IS_ROOT=''; KEEP_SECRETS=''
    VERSION='1.0-prueba'; VERSION_SOURCE='literal'; CLOUDFLARED_VERSION='2026.8.2'
    JQ_VERSION='1.7.1'; CLOUDFLARED_BIN=''
    VERSION_FILE="$REGS/version"; SETUP_ENV_FILE="$REGS/etc-env"
    SUMMARY_FILE="$REGS/resumen.txt"; CREDS_FILE="$REGS/credenciales.txt"
    CONFIG_FILE="$REGS/config.env"; TUNNEL_FILE="$REGS/tunnel.env"
    FIREWALL_UNIT='/etc/systemd/system/coolify-firewall.service'
}
sum_config

sum_says() { # sum_says estado patron descripcion
    state_set coolify_register "$1"
    write_summaries
    case "$(cat "$SUMMARY_FILE")" in
        *"$2"*) ok "$3" ;;
        *) bad "$3" "$(grep -n 'Estado' "$SUMMARY_FILE" | head -3)" ;;
    esac
}
sum_says registrado 'usuario registrado y comprobado' "el resumen dice 'registrado'"
sum_says ya-existia 'YA EXISTIA un usuario'           "el resumen dice 'ya existia'"
sum_says pendiente  'PENDIENTE'                       "el resumen dice 'pendiente'"
sum_says omitido    'omitido (--skip-coolify-register)' "el resumen dice 'omitido'"

# Regresion de la trampa de #7: en un reintento run_step NO reejecuta el paso,
# asi que cualquier variable en memoria esta vacia. Si el resumen se fiara de
# ella, diria "PENDIENTE" de un usuario que si se registro.
state_set coolify_register registrado
COOLIFY_REGISTERED=''   # la variable de antes, deliberadamente vacia
write_summaries
case "$(cat "$SUMMARY_FILE")" in
    *PENDIENTE*) bad "en un reintento el resumen no miente" "dice PENDIENTE de un usuario registrado" ;;
    *'usuario registrado y comprobado'*) ok "en un reintento el resumen no miente" ;;
    *) bad "en un reintento el resumen no miente" "estado inesperado" ;;
esac
unset COOLIFY_REGISTERED

# El estado tiene que sobrevivir al proceso: es lo unico que run_step no repite.
if [ -f "$STATE_DIR/state.coolify_register" ]; then
    ok "el estado del registro queda en disco, no en una variable"
else
    bad "el estado del registro queda en disco, no en una variable"
fi

# Guardian: que no vuelva el "cualquier 2xx/3xx es exito".
if grep -nE '^\s*302\|200\|303\)' "$ROOT/setup.sh" > "$TMP/hit" 2>/dev/null; then
    bad "el exito ya no se decide por el codigo HTTP" "$(cat "$TMP/hit")"
else
    ok "el exito ya no se decide por el codigo HTTP"
fi
case "$(sh "$ROOT/setup.sh" --help 2>&1)" in
    *--skip-coolify-register*) ok "--skip-coolify-register aparece en la ayuda" ;;
    *) bad "--skip-coolify-register aparece en la ayuda" ;;
esac
fi

# ------------------------------------------------------------- cortafuegos
if want cortafuegos; then
group "Cortafuegos: ufw y la cadena DOCKER-USER (#4)"
eval "$(sed -n '/^state_set() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^state_get() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^valid_cidr() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^iface_from_ip_route() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^iface_from_proc_route() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^ssh_client_ip() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^ufw_plan() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^docker_user_plan() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^firewall_script() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^firewall_unit() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^do_firewall() {/,/^}/p' "$ROOT/setup.sh")"
note() { :; }
warn() { :; }
err()  { :; }
info() { :; }
_logfile() { :; }
need_root() { return 0; }

FW="$TMP/fw"; mkdir -p "$FW"
# Consumidas por las funciones cargadas con eval, que el analizador no ve.
# shellcheck disable=SC2034
LAN_CIDRS='10.0.0.0/8 172.16.0.0/12 192.168.0.0/16'
SSH_FROM=''; ALLOW_LAN=''; NO_FIREWALL=''

# --- interfaz externa -----------------------------------------------------
IPR='default via 192.168.1.1 dev enp3s0 proto dhcp src 192.168.1.50 metric 100'
is "saca la interfaz de 'ip route'" "enp3s0" "$(iface_from_ip_route "$IPR")"
is "sin ruta por defecto, nada"     ""       "$(iface_from_ip_route '10.0.0.0/8 dev docker0 scope link')"
is "sin salida de 'ip route', nada" ""       "$(iface_from_ip_route '')"
printf 'Iface\tDestination\tGateway\tFlags\n' > "$FW/route"
printf 'docker0\t000011AC\t00000000\t0001\n' >> "$FW/route"
printf 'eth0\t00000000\t0101A8C0\t0003\n'    >> "$FW/route"
is "y tambien de /proc/net/route" "eth0" "$(iface_from_proc_route "$FW/route")"
is "un /proc/net/route que no existe no revienta" "" "$(iface_from_proc_route "$FW/no-existe")"

# --- ufw_plan -------------------------------------------------------------
PLAN=$(ufw_plan)
case "$PLAN" in *'ufw default deny incoming'*) ok "deniega la entrada por defecto" ;;
    *) bad "deniega la entrada por defecto" "$PLAN" ;; esac
case "$PLAN" in *'ufw default allow outgoing'*) ok "y deja salir" ;;
    *) bad "y deja salir" ;; esac
case "$PLAN" in *'ufw allow 22/tcp'*) ok "abre el 22" ;;
    *) bad "abre el 22" "$PLAN" ;; esac
# Lo esencial de #4: el tunel SALE hacia Cloudflare, no recibe. Abrir 80 o 8000
# solo sirve para que la LAN se salte el tunel.
case "$PLAN" in *8000*) bad "8000 NO se abre sin pedirlo" "$PLAN" ;;
    *) ok "8000 NO se abre sin pedirlo" ;; esac
case "$PLAN" in *'port 80'*) bad "80 NO se abre sin pedirlo" "$PLAN" ;;
    *) ok "80 NO se abre sin pedirlo" ;; esac
# 'ufw --force reset' tira las conexiones abiertas, la del operador incluida.
if grep -nE '^[[:space:]]*[^#[:space:]].*--force reset' "$ROOT/setup.sh" > "$TMP/hit" 2>/dev/null; then
    bad "en ningun sitio se hace 'ufw --force reset'" "$(cat "$TMP/hit")"
else
    ok "en ningun sitio se hace 'ufw --force reset'"
fi

# --allow-lan: entonces si, y para las tres redes privadas.
ALLOW_LAN=1
PLAN_LAN=$(ufw_plan)
n=$(printf '%s\n' "$PLAN_LAN" | grep -c 'port 8000' || true)
is "--allow-lan abre 8000 a las tres redes privadas" "3" "$n"
n=$(printf '%s\n' "$PLAN_LAN" | grep -c 'port 80 ' || true)
is "y 80 igual" "3" "$n"
ALLOW_LAN=''

# --ssh-from: la IP desde la que se esta ejecutando esto va SIEMPRE. Si no, el
# operador se autoexpulsa en el mismo comando desde el que esta conectado.
SSH_FROM='192.168.1.0/24'
PLAN_SSH=$(SSH_CONNECTION='10.9.9.9 51234 10.0.0.5 22' ufw_plan)
case "$PLAN_SSH" in *'from 192.168.1.0/24 to any port 22'*) ok "--ssh-from acota el 22" ;;
    *) bad "--ssh-from acota el 22" "$PLAN_SSH" ;; esac
case "$PLAN_SSH" in *'from 10.9.9.9 to any port 22'*) ok "y anade la IP de la sesion en curso" ;;
    *) bad "y anade la IP de la sesion en curso" "$PLAN_SSH" ;; esac
case "$PLAN_SSH" in *'ufw allow 22/tcp'*) bad "con --ssh-from no queda el 22 abierto a todos" ;;
    *) ok "con --ssh-from no queda el 22 abierto a todos" ;; esac
# Tambien vale SSH_CLIENT, que es lo que hay en shells mas viejas.
PLAN_SSH2=$(SSH_CLIENT='10.8.8.8 51234 22' ufw_plan)
case "$PLAN_SSH2" in *'from 10.8.8.8 to any port 22'*) ok "SSH_CLIENT sirve igual que SSH_CONNECTION" ;;
    *) bad "SSH_CLIENT sirve igual que SSH_CONNECTION" "$PLAN_SSH2" ;; esac
# Basura en SSH_CONNECTION no puede acabar dentro de una regla.
is "una IP de mentira no se cuela en la regla" "" "$(SSH_CONNECTION='pepe; rm -rf /' ssh_client_ip)"
# shellcheck disable=SC2034
SSH_FROM=''

# --- DOCKER-USER ----------------------------------------------------------
DPLAN=$(docker_user_plan eth0)
is "la cadena se vacia antes de rehacerla" "iptables -F DOCKER-USER" \
   "$(printf '%s\n' "$DPLAN" | head -n1)"
# Sin esto cae el trafico de vuelta de TODO lo que sale del equipo: Coolify no
# podria ni descargar una imagen.
l_est=$(printf '%s\n' "$DPLAN" | grep -n 'ESTABLISHED,RELATED' | cut -d: -f1 | head -n1)
l_drop=$(printf '%s\n' "$DPLAN" | grep -n -- '-j DROP' | cut -d: -f1 | head -n1)
if [ -n "$l_est" ] && [ -n "$l_drop" ] && [ "$l_est" -lt "$l_drop" ]; then
    ok "ESTABLISHED,RELATED va ANTES del DROP"
else
    bad "ESTABLISHED,RELATED va ANTES del DROP" "established=${l_est:-?} drop=${l_drop:-?}"
fi
# Un DROP sin '-i' tira tambien lo que va de los contenedores hacia internet.
sin_i=$(printf '%s\n' "$DPLAN" | grep -- '-j DROP' | grep -cv -- '-i eth0' || true)
is "ninguna regla DROP se queda sin '-i'" "0" "$sin_i"
n=$(printf '%s\n' "$DPLAN" | grep -c -- '-j DROP' || true)
is "y hay un DROP, no cero" "1" "$n"
case "$DPLAN" in *'-i lo -j RETURN'*) ok "el loopback se deja pasar" ;;
    *) bad "el loopback se deja pasar" "$DPLAN" ;; esac
case "$DPLAN" in *8000*) bad "sin --allow-lan no se abre 8000 a la LAN" "$DPLAN" ;;
    *) ok "sin --allow-lan no se abre 8000 a la LAN" ;; esac

ALLOW_LAN=1
DPLAN_LAN=$(docker_user_plan eth0)
l_lan=$(printf '%s\n' "$DPLAN_LAN" | grep -n 'dport 8000' | cut -d: -f1 | head -n1)
l_drop=$(printf '%s\n' "$DPLAN_LAN" | grep -n -- '-j DROP' | cut -d: -f1 | head -n1)
if [ -n "$l_lan" ] && [ "$l_lan" -lt "$l_drop" ]; then
    ok "con --allow-lan los RETURN de la LAN van antes del DROP"
else
    bad "con --allow-lan los RETURN de la LAN van antes del DROP" "lan=${l_lan:-?} drop=${l_drop:-?}"
fi
sin_i=$(printf '%s\n' "$DPLAN_LAN" | grep -- '-j DROP' | grep -cv -- '-i eth0' || true)
is "y el DROP sigue con su '-i'" "0" "$sin_i"
# shellcheck disable=SC2034
ALLOW_LAN=''

# --- script y unidad ------------------------------------------------------
FIREWALL_SCRIPT="$FW/coolify-firewall-docker"
FIREWALL_UNIT="$FW/coolify-firewall.service"
firewall_script eth0 > "$FW/fw.sh"
for sh_ in sh dash bash; do
    have "$sh_" || continue
    if $sh_ -n "$FW/fw.sh" 2>/dev/null; then ok "el script de reglas es $sh_ valido"
    else bad "el script de reglas es $sh_ valido"; fi
done
case "$(cat "$FW/fw.sh")" in
    *'iptables -N DOCKER-USER'*) ok "crea la cadena si no esta" ;;
    *) bad "crea la cadena si no esta" ;;
esac
UNIT=$(firewall_unit)
for pat in 'After=docker.service' 'Requires=docker.service' 'PartOf=docker.service' \
           'Type=oneshot'; do
    case "$UNIT" in *"$pat"*) ok "la unidad lleva $pat" ;;
        *) bad "la unidad lleva $pat" "$UNIT" ;; esac
done
case "$UNIT" in *"ExecStart=$FIREWALL_SCRIPT"*) ok "y apunta al script de reglas" ;;
    *) bad "y apunta al script de reglas" "$UNIT" ;; esac

# --- do_firewall con ufw e iptables de mentira ----------------------------
# El riesgo de #4 es cortarse el SSH a uno mismo. Se comprueba ejecutando el
# paso entero con ordenes simuladas y mirando lo que habria ejecutado.
FWLOG="$FW/ordenes.log"
# shellcheck disable=SC2034
LOG_FILE="$FW/fw-run.log"
# shellcheck disable=SC2034
OS_N=linux
# shellcheck disable=SC2034
HAS_SYSTEMD=1
WORK_DIR="$FW/work"; mkdir -p "$WORK_DIR"
STATE_DIR="$FW/state"; mkdir -p "$STATE_DIR"
fw_run() {
    : > "$FWLOG"
    ( ok() { :; }
      have() { return 0; }
      ufw() {
          printf 'ufw %s\n' "$*" >> "$FWLOG"
          if [ -n "${UFW_FAIL:-}" ] && [ "$1" = allow ]; then return 1; fi
          return 0
      }
      iptables() { printf 'iptables %s\n' "$*" >> "$FWLOG"; return 0; }
      systemctl() { printf 'systemctl %s\n' "$*" >> "$FWLOG"; return 0; }
      firewall_ext_iface() { printf '%s' "${FAKE_IFACE-eth0}"; }
      do_firewall ) >/dev/null 2>&1
}

rm -f "$FIREWALL_SCRIPT" "$FIREWALL_UNIT"
st=0; fw_run || st=$?
is "el paso completo sale bien" "0" "$st"
l_allow=$(grep -n 'ufw allow' "$FWLOG" | cut -d: -f1 | tail -n1)
l_enable=$(grep -n 'ufw --force enable' "$FWLOG" | cut -d: -f1 | head -n1)
if [ -n "$l_allow" ] && [ -n "$l_enable" ] && [ "$l_allow" -lt "$l_enable" ]; then
    ok "el 'allow 22' se aplica ANTES del 'enable'"
else
    bad "el 'allow 22' se aplica ANTES del 'enable'" "allow=${l_allow:-?} enable=${l_enable:-?}"
fi
if [ -f "$FIREWALL_SCRIPT" ] && [ -f "$FIREWALL_UNIT" ]; then
    ok "deja el script y la unidad que reponen DOCKER-USER"
else
    bad "deja el script y la unidad que reponen DOCKER-USER"
fi
case "$(state_get firewall)" in *activo*) ok "y el resumen lo puede contar" ;;
    *) bad "y el resumen lo puede contar" "[$(state_get firewall)]" ;; esac

# Si un 'ufw allow' falla, NO se activa nada: un 'deny incoming' sin la regla de
# SSH deja fuera a quien esta ejecutando esto, y ya no hay vuelta atras.
UFW_FAIL=1
st=0; fw_run || st=$?
is "si un 'allow' falla, el paso falla" "1" "$st"
if grep -q 'enable' "$FWLOG"; then
    bad "y sobre todo NO activa el cortafuegos" "$(cat "$FWLOG")"
else
    ok "y sobre todo NO activa el cortafuegos"
fi
UFW_FAIL=''

# Sin interfaz externa se FALLA. La alternativa seria un DROP sin '-i', que
# corta a los contenedores la salida a internet.
rm -f "$FIREWALL_SCRIPT" "$FIREWALL_UNIT"
FAKE_IFACE=''
st=0; fw_run || st=$?
is "sin saber la interfaz externa, el paso falla" "1" "$st"
if grep -q 'DROP' "$FWLOG"; then
    bad "y no instala ninguna regla DROP" "$(cat "$FWLOG")"
else
    ok "y no instala ninguna regla DROP"
fi
if [ -e "$FIREWALL_SCRIPT" ]; then bad "ni deja el script escrito"; else ok "ni deja el script escrito"; fi
unset FAKE_IFACE

# --no-firewall: no se toca nada, pero el resumen lo dice bien claro.
NO_FIREWALL=1
st=0; fw_run || st=$?
is "--no-firewall no falla" "0" "$st"
is "y no ejecuta ni una orden" "" "$(cat "$FWLOG")"
case "$(state_get firewall)" in *DESACTIVADO*) ok "y el resumen avisa de que no hay cortafuegos" ;;
    *) bad "y el resumen avisa de que no hay cortafuegos" "[$(state_get firewall)]" ;; esac
# shellcheck disable=SC2034
NO_FIREWALL=''

# --- orden de los pasos ---------------------------------------------------
# docker_config ANTES que firewall porque escribir daemon.json obliga a
# reiniciar dockerd, y dockerd VACIA y recrea DOCKER-USER al arrancar: al reves
# las reglas desaparecerian sin decir nada y el cortafuegos quedaria de adorno.
l_docker=$(grep -n '^run_step docker "' "$ROOT/setup.sh" | cut -d: -f1 | head -n1)
l_dcfg=$(grep -n '^run_step docker_config ' "$ROOT/setup.sh" | cut -d: -f1 | head -n1)
l_fw=$(grep -n '^run_step firewall ' "$ROOT/setup.sh" | cut -d: -f1 | head -n1)
l_coolify=$(grep -n '^run_step coolify "' "$ROOT/setup.sh" | cut -d: -f1 | head -n1)
if [ "$l_docker" -lt "$l_dcfg" ] && [ "$l_dcfg" -lt "$l_fw" ] && [ "$l_fw" -lt "$l_coolify" ]; then
    ok "orden docker -> docker_config -> firewall -> coolify"
else
    bad "orden docker -> docker_config -> firewall -> coolify" \
        "docker=$l_docker docker_config=$l_dcfg firewall=$l_fw coolify=$l_coolify"
fi

for f in --no-firewall --ssh-from --allow-lan; do
    case "$(sh "$ROOT/setup.sh" --help 2>&1)" in
        *"$f"*) ok "$f aparece en la ayuda" ;;
        *) bad "$f aparece en la ayuda" ;;
    esac
done
fi

# ----------------------------------------------------------- mantenimiento
if want mantenimiento; then
group "Mantenimiento: logs de Docker y parches de seguridad (#11)"
eval "$(sed -n '/^state_set() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^state_get() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^valid_auto_reboot() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^docker_daemon_json() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^unattended_conf() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^do_docker_config() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^do_updates() {/,/^}/p' "$ROOT/setup.sh")"
note() { :; }
warn() { :; }
err()  { :; }
info() { :; }
need_root() { return 0; }

MNT="$TMP/mnt"; mkdir -p "$MNT"
STATE_DIR="$MNT/state"; mkdir -p "$STATE_DIR"

# --- daemon.json ----------------------------------------------------------
if have python3; then
    if docker_daemon_json | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        ok "daemon.json es JSON valido"
    else
        bad "daemon.json es JSON valido" "$(docker_daemon_json)"
    fi
    v=$(docker_daemon_json | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d["log-driver"], d["log-opts"]["max-size"], d["log-opts"]["max-file"])' 2>/dev/null || echo ERROR)
    is "con json-file, 10m y 3 ficheros" "json-file 10m 3" "$v"
else
    skip "daemon.json es JSON valido" "hace falta python3"
fi

# --- do_docker_config -----------------------------------------------------
# Se ejecuta en subshell con 'ok' y 'have' anuladas: 'ok' aqui es el contador
# de pruebas, y 'have docker' dispararia un 'docker info' de verdad. El estado
# viaja por disco, asi que el subshell no estorba.
dcfg() { ( ok() { :; }; have() { return 1; }; do_docker_config ) >/dev/null 2>&1; }
# Consumidas por do_docker_config, cargada con eval: el analizador no lo ve.
# shellcheck disable=SC2034
SKIP_DOCKER=''
# shellcheck disable=SC2034
HAS_SYSTEMD=''
DOCKER_DAEMON_JSON="$MNT/etc/docker/daemon.json"

rm -f "$STATE_DIR/state.docker_logs"
st=0; dcfg || st=$?
is "escribe daemon.json si no habia" "0" "$st"
if [ -f "$DOCKER_DAEMON_JSON" ]; then ok "el fichero queda escrito"; else bad "el fichero queda escrito"; fi
case "$(state_get docker_logs)" in
    *'max-size 10m'*) ok "y el resumen lo puede contar" ;;
    *) bad "y el resumen lo puede contar" "[$(state_get docker_logs)]" ;;
esac

# Idempotente: el mismo fichero otra vez no es "ya habia uno ajeno".
dcfg
case "$(state_get docker_logs)" in
    *'max-size 10m'*) ok "reejecutar sobre el nuestro no lo da por ajeno" ;;
    *) bad "reejecutar sobre el nuestro no lo da por ajeno" "[$(state_get docker_logs)]" ;;
esac

# Un daemon.json ajeno NO se fusiona a ciegas: se avisa y se deja intacto.
printf '{ "insecure-registries": ["10.0.0.1:5000"] }\n' > "$DOCKER_DAEMON_JSON"
antes=$(cat "$DOCKER_DAEMON_JSON")
dcfg
is "un daemon.json ajeno se deja intacto" "$antes" "$(cat "$DOCKER_DAEMON_JSON")"
case "$(state_get docker_logs)" in
    *'SIN TOCAR'*) ok "y el resumen dice que hay que hacerlo a mano" ;;
    *) bad "y el resumen dice que hay que hacerlo a mano" "[$(state_get docker_logs)]" ;;
esac

# --- politica de reinicio -------------------------------------------------
chk_reboot() { # chk_reboot valor esperado(0|1)
    if valid_auto_reboot "$1"; then got=0; else got=1; fi
    if [ "$got" = "$2" ]; then ok "--auto-reboot=$1 $([ "$2" = 0 ] && echo vale || echo 'no vale')"
    else bad "--auto-reboot=$1" "esperaba rc=$2"; fi
}
chk_reboot no    0
chk_reboot 03:30 0
chk_reboot 00:00 0
chk_reboot 23:59 0
chk_reboot 24:00 1
chk_reboot 3:30  1
chk_reboot si    1
chk_reboot ''    1

# --- unattended_conf ------------------------------------------------------
CONF_NO=$(unattended_conf no)
CONF_HR=$(unattended_conf 03:30)
case "$CONF_NO" in
    *'Automatic-Reboot "false"'*) ok "por defecto no reinicia solo" ;;
    *) bad "por defecto no reinicia solo" ;;
esac
case "$CONF_NO" in
    *Automatic-Reboot-Time*) bad "sin hora de reinicio cuando es 'no'" ;;
    *) ok "sin hora de reinicio cuando es 'no'" ;;
esac
case "$CONF_HR" in
    *'Automatic-Reboot "true"'*'Automatic-Reboot-Time "03:30"'*) ok "con hora, reinicia a esa hora" ;;
    *) bad "con hora, reinicia a esa hora" "$CONF_HR" ;;
esac
# Solo seguridad: ni -updates ni -backports pueden colarse.
case "$CONF_NO" in
    *-updates*|*-backports*|*-proposed*) bad "solo entran origenes de seguridad" "$CONF_NO" ;;
    *) ok "solo entran origenes de seguridad" ;;
esac
case "$CONF_NO" in
    *'#clear Unattended-Upgrade::Allowed-Origins;'*) ok "vacia la lista antes, no la amplia" ;;
    *) bad "vacia la lista antes, no la amplia" ;;
esac
case "$CONF_NO" in
    *'APT::Periodic::Unattended-Upgrade "1";'*) ok "y el temporizador queda activado" ;;
    *) bad "y el temporizador queda activado" ;;
esac

# --no-unattended-upgrades no toca nada.
UNATTENDED_CONF="$MNT/etc/apt/apt.conf.d/51coolify-unattended"
# shellcheck disable=SC2034
AUTO_REBOOT=no
NO_UNATTENDED=1
( ok() { :; }; do_updates ) >/dev/null 2>&1
if [ -e "$UNATTENDED_CONF" ]; then bad "--no-unattended-upgrades no escribe nada"
else ok "--no-unattended-upgrades no escribe nada"; fi
is "y lo dice en el resumen" "omitido (--no-unattended-upgrades)" "$(state_get updates)"
# shellcheck disable=SC2034
NO_UNATTENDED=''

# --- orden de los pasos ---------------------------------------------------
# apt-get es lo unico de todo el script que puede pelearse por el lock de dpkg:
# tiene que quedar DESPUES de que Docker y Coolify hayan terminado con el.
l_docker=$(grep -n '^run_step docker "' "$ROOT/setup.sh" | cut -d: -f1 | head -n1)
l_dcfg=$(grep -n '^run_step docker_config ' "$ROOT/setup.sh" | cut -d: -f1 | head -n1)
l_coolify=$(grep -n '^run_step coolify "' "$ROOT/setup.sh" | cut -d: -f1 | head -n1)
l_tsvc=$(grep -n '^run_step tunnel_service ' "$ROOT/setup.sh" | cut -d: -f1 | head -n1)
l_upd=$(grep -n '^run_step updates ' "$ROOT/setup.sh" | cut -d: -f1 | head -n1)
if [ "$l_docker" -lt "$l_dcfg" ] && [ "$l_dcfg" -lt "$l_coolify" ]; then
    ok "daemon.json se escribe entre Docker y Coolify"
else
    bad "daemon.json se escribe entre Docker y Coolify" \
        "docker=$l_docker docker_config=$l_dcfg coolify=$l_coolify"
fi
if [ "$l_tsvc" -lt "$l_upd" ]; then
    ok "los parches van despues del tunel, no antes"
else
    bad "los parches van despues del tunel, no antes" "tunnel_service=$l_tsvc updates=$l_upd"
fi
# Se cuentan las INVOCACIONES, no las menciones: un err/warn que le dice al
# usuario que instale algo con apt-get no compite por ningun lock.
malo=''
for n in $(grep -n 'apt-get' "$ROOT/setup.sh" \
           | grep -vE '^[0-9]+:[[:space:]]*(err|warn|note|info|#)' | cut -d: -f1); do
    [ "$n" -gt "$l_tsvc" ] || malo="$malo $n"
done
if [ -z "$malo" ]; then
    ok "ningun apt-get antes de que Docker y Coolify suelten el lock de dpkg"
else
    bad "ningun apt-get antes de que Docker y Coolify suelten el lock de dpkg" "lineas:$malo"
fi

for f in --auto-reboot --no-unattended-upgrades; do
    case "$(sh "$ROOT/setup.sh" --help 2>&1)" in
        *"$f"*) ok "$f aparece en la ayuda" ;;
        *) bad "$f aparece en la ayuda" ;;
    esac
done
fi

# --------------------------------------------------------------- descargas
if want descargas; then
group "Descargas fijadas y verificadas (#5, #2)"

# Guardian de regresion de #5: 'latest' no puede volver. Con 'latest' dos
# equipos hechos con la misma ISO acaban con binarios distintos, y ademas no
# hay hash posible que comprobar.
if grep -q 'releases/latest/download' "$ROOT/setup.sh"; then
    bad "setup.sh no descarga de 'releases/latest'" \
        "$(grep -n 'releases/latest/download' "$ROOT/setup.sh" | head -2)"
else
    ok "setup.sh no descarga de 'releases/latest'"
fi
if grep -q 'releases/download/\$CLOUDFLARED_VERSION/' "$ROOT/setup.sh"; then
    ok "cloudflared se descarga de una version concreta"
else
    bad "cloudflared se descarga de una version concreta"
fi
case "$(sh "$ROOT/setup.sh" --help 2>&1)" in
    *--cloudflared-version*) ok "--cloudflared-version aparece en la ayuda" ;;
    *) bad "--cloudflared-version aparece en la ayuda" ;;
esac
# Sin guarda de sistema operativo, en macOS se componia
# 'cloudflared-darwin-amd64', que no existe como asset, y moria con un 404.
sed -n '/^do_cloudflared_bin() {/,/^}/p' "$ROOT/setup.sh" > "$TMP/cfbin.sh"
if grep -q 'OS_N" != linux' "$TMP/cfbin.sh"; then
    ok "do_cloudflared_bin tiene guarda de sistema operativo"
else
    bad "do_cloudflared_bin tiene guarda de sistema operativo" "en macOS moriria con un 404"
fi

# --- verificacion de integridad (#2) -------------------------------------
# Las funciones se cargan en este shell con eval, como en los demas grupos.
eval "$(sed -n '/^sha256_of() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^verify_sha256() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^known_sha256() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^verify_artifact() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^warn_unverified() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^fetch_artifact() {/,/^}/p' "$ROOT/setup.sh")"

D="$TMP/dl"; mkdir -p "$D"
VLOG="$D/diag"
: > "$VLOG"
# Diagnostico capturado: asi se puede comprobar que el aviso se emite de verdad
# y no solo que la funcion devuelve 0.
_logfile() { printf 'LOG: %s\n' "$*" >> "$VLOG"; }
err()  { printf 'ERR: %s\n' "$*" >> "$VLOG"; }
warn() { printf 'WARN: %s\n' "$*" >> "$VLOG"; }
note() { printf 'NOTE: %s\n' "$*" >> "$VLOG"; }
info() { printf 'INFO: %s\n' "$*" >> "$VLOG"; }
have_real() { command -v "$1" >/dev/null 2>&1; }
have() { have_real "$1"; }

# SHA-256 del fichero vacio. Es una constante publica y conocida: sirve de
# vector de prueba sin tener que calcularla con la misma herramienta que se
# esta probando, que seria circular.
EMPTY_SHA=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
: > "$D/vacio"

n=0
for tool in sha256sum shasum openssl; do
    have_real "$tool" || continue
    # Se fuerza un backend concreto haciendo que 'have' solo reconozca ese.
    eval "have() { [ \"\$1\" = $tool ] && have_real $tool; }"
    is "sha256_of via $tool" "$EMPTY_SHA" "$(sha256_of "$D/vacio")"
    n=$((n+1))
done
have() { have_real "$1"; }
if [ "$n" -gt 0 ]; then
    ok "hay al menos una herramienta de hash ($n probada(s))"
else
    bad "hay al menos una herramienta de hash" "ni sha256sum ni shasum ni openssl"
fi

# Hash correcto: rc=0 y el fichero sigue ahi.
st=0; verify_sha256 "$D/vacio" "$EMPTY_SHA" || st=$?
is "hash correcto devuelve 0" "0" "$st"
if [ -f "$D/vacio" ]; then ok "hash correcto conserva el fichero"
else bad "hash correcto conserva el fichero"; fi

# Hash que no cuadra: rc!=0 y el fichero DESAPARECE. Dejarlo seria dejar puesta
# la trampa para el paso siguiente, que es justo lo que se quiere evitar.
printf 'binario falsificado\n' > "$D/malo"
: > "$VLOG"
st=0; verify_sha256 "$D/malo" "$EMPTY_SHA" || st=$?
is "hash que no cuadra devuelve !=0" "1" "$st"
if [ -e "$D/malo" ]; then bad "un hash que no cuadra borra el fichero" "quedo instalado"
else ok "un hash que no cuadra borra el fichero"; fi
if grep -q 'ERR: .*esperado' "$VLOG" && grep -q 'ERR: .*obtenido' "$VLOG"; then
    ok "y dice el esperado y el obtenido"
else
    bad "y dice el esperado y el obtenido" "$(head -3 "$VLOG")"
fi

# Sin NINGUNA herramienta de hash tiene que fallar, no continuar a ciegas.
# Se simula redefiniendo 'have', no vaciando el PATH: vaciarlo rompe tambien
# el rm de la propia funcion en shells sin builtin.
printf 'contenido\n' > "$D/sinhash"
: > "$VLOG"
have() { return 1; }
st=0; verify_sha256 "$D/sinhash" "$EMPTY_SHA" || st=$?
have() { have_real "$1"; }
is "sin herramienta de hash falla" "1" "$st"
if [ -e "$D/sinhash" ]; then bad "sin herramienta de hash tampoco deja el fichero"
else ok "sin herramienta de hash tampoco deja el fichero"; fi
if grep -q 'No se continúa sin verificar' "$VLOG"; then
    ok "y lo dice en vez de callarse"
else
    bad "y lo dice en vez de callarse" "$(head -3 "$VLOG")"
fi

# La tabla tiene que cubrir lo que el script descarga por defecto, en las dos
# arquitecturas. Un hueco aqui significa una instalacion que aborta.
for k in cloudflared-2026.8.2-linux-amd64 cloudflared-2026.8.2-linux-arm64 \
         jq-1.7.1-jq-linux-amd64 jq-1.7.1-jq-linux-arm64 \
         jq-1.7.1-jq-macos-amd64 jq-1.7.1-jq-macos-arm64; do
    h=$(known_sha256 "$k" 2>/dev/null || true)
    case "$h" in
        ????????????????????????????????????????????????????????????????)
            ok "hay hash conocido para $k" ;;
        *)  bad "hay hash conocido para $k" "obtenido [$h]" ;;
    esac
done
st=0; known_sha256 cloudflared-9999.1.1-linux-amd64 >/dev/null || st=$?
is "una version desconocida no inventa hash" "1" "$st"

# El pin de la linea de comandos manda sobre la tabla: es lo que permite pedir
# una version que este script no conoce sin renunciar a verificar.
: > "$D/pin"
st=0; verify_artifact "$D/pin" cloudflared-9999.1.1-linux-amd64 "$EMPTY_SHA" || st=$?
is "el pin a mano permite una version desconocida" "0" "$st"
: > "$D/nopin"
: > "$VLOG"
st=0; verify_artifact "$D/nopin" cloudflared-9999.1.1-linux-amd64 '' || st=$?
is "sin pin ni tabla, aborta" "1" "$st"
if [ -e "$D/nopin" ]; then bad "sin pin ni tabla no deja el fichero"
else ok "sin pin ni tabla no deja el fichero"; fi

# Docker y Coolify no tienen artefacto verificable: lo minimo es decirlo, por
# pantalla y en el log. Antes no se decia nada en ninguno de los dos sitios.
: > "$VLOG"
warn_unverified Docker https://get.docker.com --pin-docker
if grep -q 'WARN: SIN VERIFICAR' "$VLOG" && grep -q 'pin-docker' "$VLOG"; then
    ok "sin pin se avisa y se dice como fijarlo"
else
    bad "sin pin se avisa y se dice como fijarlo" "$(head -3 "$VLOG")"
fi
sed -n '/^do_docker() {/,/^}/p' "$ROOT/setup.sh" > "$TMP/dodocker.sh"
sed -n '/^do_coolify() {/,/^}/p' "$ROOT/setup.sh" > "$TMP/docoolify.sh"
for f in dodocker docoolify; do
    if grep -q 'warn_unverified' "$TMP/$f.sh" && grep -q 'verify_sha256' "$TMP/$f.sh"; then
        ok "$f: pin si lo hay, aviso si no"
    else
        bad "$f: pin si lo hay, aviso si no"
    fi
done

# --offline-dir: coge el artefacto del directorio y no toca la red.
OFF="$D/offline"; mkdir -p "$OFF"
printf 'soy el instalador\n' > "$OFF/get-docker.sh"
OFFLINE_DIR="$OFF"
fetch_file() { bad "fetch_artifact ha ido a la red con --offline-dir puesto"; return 1; }
st=0; fetch_artifact https://get.docker.com "$D/traido" get-docker.sh || st=$?
is "--offline-dir trae el artefacto sin red" "0" "$st"
is "y con el contenido correcto" "soy el instalador" "$(cat "$D/traido" 2>/dev/null || true)"
: > "$VLOG"
st=0; fetch_artifact https://get.docker.com "$D/nada" jq-linux-amd64 || st=$?
is "--offline-dir sin el fichero falla" "1" "$st"
if grep -q "no contiene 'jq-linux-amd64'" "$VLOG"; then
    ok "y dice exactamente que fichero falta"
else
    bad "y dice exactamente que fichero falta" "$(head -3 "$VLOG")"
fi
# La consume fetch_artifact, cargada con eval: el analizador no puede verlo.
# shellcheck disable=SC2034
OFFLINE_DIR=''

for f in --pin-docker --pin-coolify --pin-cloudflared --offline-dir; do
    case "$(sh "$ROOT/setup.sh" --help 2>&1)" in
        *"$f"*) ok "$f aparece en la ayuda" ;;
        *) bad "$f aparece en la ayuda" ;;
    esac
done
fi

# ---------------------------------------------------------------- versionado
if want version; then
group "Versionado (#13)"

# --version en AMBOS scripts. Antes no existia en ninguno: la unica aparicion
# de la cadena en todo el arbol era el '--version' de cloudflared.
st=0; out=$(sh "$ROOT/setup.sh" --version 2>&1) || st=$?
is "setup.sh --version sale con 0" "0" "$st"
case "$out" in
    'setup.sh '[0-9]*) ok "setup.sh --version imprime una version" ;;
    *) bad "setup.sh --version imprime una version" "[$out]" ;;
esac
st=0; out=$(sh "$ROOT/build-usb.sh" --version 2>&1) || st=$?
is "build-usb.sh --version sale con 0" "0" "$st"
if have git && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    is "build-usb.sh --version coincide con git describe" \
        "build-usb.sh $(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null)" "$out"
else
    is "build-usb.sh --version fuera de un repo lo dice" "build-usb.sh sin-git" "$out"
fi

# La version viaja por el entorno, no por un marcador dentro de setup.sh:
# build-usb.sh exige que el script incrustado sea identico byte a byte al
# original, y un marcador sustituido romperia ese invariante.
out=$(env SETUP_VERSION=9.9.9-prueba sh "$ROOT/setup.sh" --version 2>&1 || true)
case "$out" in
    *9.9.9-prueba*) ok "SETUP_VERSION del entorno manda sobre el literal" ;;
    *) bad "SETUP_VERSION del entorno manda sobre el literal" "[$out]" ;;
esac
if grep -qE '^__[A-Z_]*VERSION[A-Z_]*__$' "$ROOT/setup.sh"; then
    bad "setup.sh no lleva marcador de version que sustituir" \
        "romperia la igualdad byte a byte con el incrustado"
else
    ok "setup.sh no lleva marcador de version que sustituir"
fi
if grep -q 'SETUP_VERSION' "$ROOT/cloud-init/user-data.tpl"; then
    bad "la plantilla no hornea la version a mano" "debe salir de env_lines"
else
    ok "la plantilla no hornea la version a mano"
fi

# El resumen y /etc/coolify-setup.version. Se reusa el mismo aparejo del grupo
# de secretos: write_summaries cargada con eval.
eval "$(sed -n '/^comp_version() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^version_table() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^write_summaries() {/,/^}/p' "$ROOT/setup.sh")"
have() { command -v "$1" >/dev/null 2>&1; }
_ts() { echo '2026-01-01 00:00:00'; }
svc_state() { echo activo; }
# Las consumen las funciones cargadas con eval: el analizador no puede verlo.
# shellcheck disable=SC2034
setup_version_fixture() {
    VER="$TMP/ver"; mkdir -p "$VER"
    VERSION='1.2.3-abc'
    VERSION_SOURCE='horneada al construir'
    CLOUDFLARED_VERSION='2026.8.2'
    JQ_VERSION='1.7.1'
    CLOUDFLARED_BIN=''
    NEW_HOSTNAME='maquina'; TIMEZONE='Europe/Madrid'; TIMEZONE_SOURCE='sistema'
    ADMIN_USER='admin'; ADMIN_PASSWORD='CLAVEADMIN123'; SSH_KEY=''
    COOLIFY_FQDN='coolify.fompi.net'; COOLIFY_EMAIL='a@b.com'
    COOLIFY_PASSWORD='CLAVECOOLIFY456'; COOLIFY_REGISTERED=1; SKIP_COOLIFY=''
    APP_SUBDOMAIN='app'; ROOT_DOMAIN='fompi.net'; APP_WILDCARD='*.app.fompi.net'
    TUNNEL_ID='tid'; INSTALLER_USER='installer'
    INSTALLER_STATE='bloqueada, fuera de sudo y con shell /usr/sbin/nologin'
    LOG_FILE="$VER/log"; IS_ROOT=''; KEEP_SECRETS=''
    SETUP_ENV_FILE="$VER/etc-env"
    SUMMARY_FILE="$VER/resumen.txt"; CREDS_FILE="$VER/credenciales.txt"
    CONFIG_FILE="$VER/config.env"; TUNNEL_FILE="$VER/tunnel.env"
    VERSION_FILE="$VER/coolify-setup.version"
}
setup_version_fixture
write_summaries
case "$(cat "$SUMMARY_FILE")" in
    *VERSIONES*'1.2.3-abc'*) ok "el resumen lleva la tabla de versiones" ;;
    *) bad "el resumen lleva la tabla de versiones" ;;
esac
for k in Docker Coolify cloudflared 'Sistema base'; do
    case "$(cat "$SUMMARY_FILE")" in
        *"$k"*) ok "la tabla nombra $k" ;;
        *) bad "la tabla nombra $k" ;;
    esac
done
if [ -f "$VERSION_FILE" ]; then ok "se escribe el fichero de versiones"
else bad "se escribe el fichero de versiones"; fi
is "y dice la version del proyecto" "1.2.3-abc" \
    "$(sed -n 's/^proyecto=//p' "$VERSION_FILE" 2>/dev/null || true)"
# Ninguna fila puede quedar vacia: en blanco no se distingue "no instalado" de
# "no lo supimos averiguar", que es justo lo que importa al depurar.
n=$(grep -cE '^[a-z_]+=$' "$VERSION_FILE" 2>/dev/null || true)
is "ninguna fila del fichero queda vacia" "0" "$n"
# 0644: no lleva secretos y su gracia es poder leerlo sin ser root.
if have stat; then
    m=$(stat -c %a "$VERSION_FILE" 2>/dev/null || stat -f %Lp "$VERSION_FILE" 2>/dev/null || echo '?')
    is "el fichero de versiones queda en 0644" "644" "$m"
fi
if grep -q 'CLAVEADMIN123\|CLAVECOOLIFY456' "$VERSION_FILE"; then
    bad "el fichero de versiones no lleva contrasenas" "y es 0644"
else
    ok "el fichero de versiones no lleva contrasenas"
fi

# La trampa de #13: build-usb.sh generaba el EnvironmentFile en DOS sitios (el
# bloque write_files y el /cidata de la ISO). Ahora sale de env_lines, y tiene
# que usarse en los dos.
is "env_lines se define una sola vez" "1" \
    "$(grep -c '^env_lines() {' "$ROOT/build-usb.sh" || true)"
if grep -q 'env_lines | sed' "$ROOT/build-usb.sh"; then
    ok "el bloque write_files sale de env_lines"
else
    bad "el bloque write_files sale de env_lines"
fi
if grep -q 'env_lines > "$TMP/cidata/coolify-setup.env"' "$ROOT/build-usb.sh"; then
    ok "el /cidata de la ISO sale del mismo env_lines"
else
    bad "el /cidata de la ISO sale del mismo env_lines" \
        "es el camino que de verdad funciona: late-commands copia de ahi"
fi
n=$(grep -c 'CF_API_TOKEN=%s' "$ROOT/build-usb.sh" || true)
is "el token se escribe en un solo sitio" "1" "$n"
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

    # #5: el pin de cloudflared tiene que sobrevivir al reintento; si no, un
    # segundo intento instalaria otra version y adios reproducibilidad.
    V="$TMP/cfver"
    env CF_API_BASE="http://127.0.0.1:$PORT" XDG_STATE_HOME="$V" HOME="$TMP" NO_COLOR=1 \
        sh "$ROOT/setup.sh" --cf-token=GOODTOKEN --domain=fompi.net \
        --cloudflared-version=2020.1.1 --dry-run --non-interactive >/dev/null 2>&1 || true
    if grep -q "CLOUDFLARED_VERSION='2020.1.1'" "$V/coolify-setup/config.env" 2>/dev/null; then
        ok "--cloudflared-version se guarda para el reintento"
    else
        bad "--cloudflared-version se guarda para el reintento" \
            "$(grep -c . "$V/coolify-setup/config.env" 2>/dev/null || echo 'sin config.env')"
    fi

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
        for _st in wifi hostname timezone admin_user docker docker_config \
                   firewall coolify coolify_domain coolify_register \
                   cloudflared_bin tunnel_service updates retire_installer; do
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

    # #13: build-usb.sh generaba el EnvironmentFile en dos sitios y este -el de
    # /cidata, que es el que late-commands copia y por tanto el que de verdad
    # funciona- era el que se quedaba sin la version si solo se tocaba el otro.
    # Se genera aqui con el MISMO env_lines del script, no con una copia.
    # Las consumen project_version y env_lines, cargadas con eval: el
    # analizador no puede verlo, de ahi la directiva.
    # shellcheck disable=SC2034
    HERE_B="$ROOT"
    eval "$(sed -n '/^project_version() {/,/^}/p' "$ROOT/build-usb.sh" | sed 's/\$HERE/$HERE_B/g')"
    BUILD_VERSION=$(project_version)
    # shellcheck disable=SC2034
    CF_TOKEN=''
    # shellcheck disable=SC2034
    PASSTHRU=''
    eval "$(sed -n '/^env_lines() {/,/^}/p' "$ROOT/build-usb.sh")"

    FK2="$TMP/fake2"; mkdir -p "$FK2/cdrom/cidata" "$FK2/target"
    cp "$ROOT/setup.sh" "$FK2/cdrom/cidata/coolify-setup.sh"
    cp "$ROOT/cloud-init/coolify-setup.service" "$FK2/cdrom/cidata/"
    env_lines > "$FK2/cdrom/cidata/coolify-setup.env"
    if grep -q '^SETUP_VERSION=' "$FK2/cdrom/cidata/coolify-setup.env"; then
        ok "el env del /cidata lleva SETUP_VERSION sin token de por medio"
    else
        bad "el env del /cidata lleva SETUP_VERSION sin token de por medio" \
            "$(cat "$FK2/cdrom/cidata/coolify-setup.env")"
    fi
    sed -e "s#^for d in .*; do#for d in $FK2/cdrom/cidata; do#" \
        -e "s#/target#$FK2/target#g" "$TMP/lc.sh" > "$TMP/lc-fake2.sh"
    sh "$TMP/lc-fake2.sh" >/dev/null 2>&1 || true
    if grep -q "^SETUP_VERSION=$BUILD_VERSION\$" "$FK2/target/etc/coolify-setup.env" 2>/dev/null; then
        ok "la version llega a /etc/coolify-setup.env por late-commands"
    else
        bad "la version llega a /etc/coolify-setup.env por late-commands" \
            "el camino que de verdad funciona se quedaria sin version"
    fi
    # Y el asistente tiene que cogerla de ahi: es lo que hace util todo esto.
    out=$(env SETUP_VERSION="$BUILD_VERSION" sh "$ROOT/setup.sh" --version 2>&1 || true)
    case "$out" in
        *"$BUILD_VERSION"*) ok "y setup.sh la lee del EnvironmentFile" ;;
        *) bad "y setup.sh la lee del EnvironmentFile" "[$out]" ;;
    esac
fi
fi

# ------------------------------------------------------------------ total
printf '\n%s%d ok, %d fallos, %d omitidos%s\n' "$B" "$PASS" "$FAIL" "$SKIP" "$Z"
[ "$FAIL" -eq 0 ] || exit 1
