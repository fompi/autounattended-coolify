#!/bin/sh
# tests/run.sh — suite de pruebas del proyecto.
#
# Sin dependencias obligatorias mas alla de sh y python3. Lo que falte se
# omite anunciandolo, para que la suite corra igual en un portatil que en CI.
#
#   sh tests/run.sh              # todo
#   sh tests/run.sh json build   # solo esos grupos
#
# Grupos: syntax json validators timezone resolution build latecommands
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
WANTED="${*:-syntax json validators timezone resolution build latecommands}"
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
