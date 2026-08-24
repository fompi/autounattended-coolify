# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> El repositorio está íntegramente en español: comentarios, mensajes de usuario,
> documentación y commits. Mantén ese idioma en todo lo que escribas aquí.

## Comandos

```bash
make test          # suite completa (tests/run.sh)
make lint          # shellcheck -s sh -S warning + `$s -n` en sh/dash/bash
make build         # genera cloud-init/user-data y meta-data
make iso ISO=ubuntu-24.04.4-live-server-amd64.iso [OUT=salida.iso]
make clean

sh tests/run.sh json build          # solo esos grupos
sh tests/run.sh resolution          # un grupo suelto
NO_COLOR=1 sh tests/run.sh          # sin ANSI (como en CI)
```

Grupos de pruebas: `syntax json validators resolution build latecommands`.

La suite **omite** un grupo si le falta una herramienta (`jq`, `python3`,
`pyyaml`, `shellcheck`, `stat`) y lo anuncia. En CI eso es un fallo: el job
`test` hace `grep -q ' skip '` sobre la salida y rompe el build. Si añades una
dependencia a la suite, añádela también al `apt-get install` del workflow.

## Arquitectura

Tres artefactos y dos caminos de instalación. Entenderlos juntos es lo que
requiere leer varios ficheros.

**`setup.sh`** (~1200 líneas, POSIX sh, autónomo) es todo el trabajo. Corre
igual desde el USB, por SSH o canalizado (`curl | sh`). Estructura en tres fases:

1. **Resolución** — deriva toda la configuración. Precedencia estricta:
   argumentos > config guardada (`$STATE_DIR/config`) > derivado/API >
   preguntar. El único dato irreducible es el API Token de Cloudflare; el
   dominio sale de `GET /zones`, el hostname del dominio, el email del nombre
   de la cuenta CF, la zona horaria de geolocalizar la IP. Termina en
   `save_config` + confirmación.
2. **Ejecución** — 13 pasos vía `run_step NOMBRE DESC funcion`, en orden:
   `wifi hostname timezone admin_user docker coolify coolify_domain
   coolify_register cloudflared_bin tunnel_create tunnel_ingress dns
   tunnel_service`. Cada uno deja `$STATE_DIR/step.<nombre>` al terminar y se
   omite en el reintento. Un paso que falla aborta con instrucciones de
   reintento; **no** se limpia lo hecho.
3. **Resumen** — `/root/instalacion-resumen.txt` (0600), borra el config con
   secretos, se autodesactiva del systemd.

**`build-usb.sh`** ensambla `cloud-init/user-data.tpl` sustituyendo marcadores
(`__SETUP_SH__`, `__UNIT_FILE__`, `__ENV_FILE__`, `__KEYBOARD__`,
`__INSTALLER_PW_HASH__`) con awk, indentando `setup.sh` y la unidad systemd a 10
espacios para caber en el escalar literal de YAML. Verifica el resultado
(YAML válido + script incrustado idéntico byte a byte) y, con `--iso`,
reempaqueta la ISO con xorriso metiendo `/cidata` dentro y `autoinstall` en la
línea de comandos del kernel.

**Los dos caminos de instalación del asistente** conviven a propósito:

- `late-commands` (el que funciona): copia script, unidad y env desde
  `/cdrom/cidata` a `/target` y crea a mano el symlink en
  `multi-user.target.wants`. **El bloque termina siempre en `true`** — un
  `late-commands` con rc≠0 aborta la instalación entera. Nada de `systemctl`
  dentro de `/target`.
- `autoinstall.user-data` (`write_files` + `runcmd`): redundante e idempotente.
  Cubre el arranque desde partición CIDATA suelta. **No funcionó como camino
  principal** (módulos *per-instance* que cloud-init omite en silencio,
  incidencia #1); por eso el otro es el bueno.

`cloud-init/coolify-setup.service` es fuente única, usada por los dos caminos.
Lleva `Conflicts=` de las getty pero **no `Before=`** (con `Before` un asistente
colgado deja el equipo sin consola de login) y `TTYPath=/dev/console`, no
`tty1`. Estas dos decisiones están verificadas en VM y `tests/run.sh` las
comprueba como invariantes.

**Capas de adaptación en `setup.sh`** — el script se amolda a lo que encuentre:
HTTP (`curl` > `wget` > `python3`), JSON (`jq` del sistema > `python3` >
descargar `jq` al directorio de trabajo, **sin instalarlo**), UI (`whiptail` >
`dialog` > texto plano). `json_get` tiene dos motores y la suite exige que den
salida idéntica, incluido el caso `false ≠ vacío` (jq lo colapsa con
`// empty`).

**`tests/cf-mock.py`** simula la API de Cloudflare. `setup.sh` apunta ahí con
`CF_API_BASE`; el token válido es `GOODTOKEN`. Expone `/__state` para verificar
qué se creó, no solo que la llamada devolvió 200.

## Reglas del código

**POSIX sh estricto.** Nada de `[[ ]]`, arrays, `printf -v`, `declare`,
`local -`, `${var,,}`. El grupo `syntax` de la suite busca esos patrones
explícitamente y `shellcheck` se ejecuta con `-s sh` a propósito, para que marque
los bashismos en vez de aceptarlos. Los scripts se comprueban con `-n` en
`sh dash bash ksh zsh`.

**El diagnóstico va a stderr; stdout es para datos.** Hubo un fallo real en que
un mensaje de progreso se coló en una sustitución de comandos y corrompió el
valor capturado.

**Cada paso nuevo, con `run_step`,** y que la función devuelva 0 solo si de
verdad terminó.

**No preguntar nada derivable.** Antes de añadir una pregunta, agota la vía de
API, deducción del sistema o generación.

Trampas concretas ya pisadas: no llamar `GROUPS` a una variable (es especial en
bash y revienta bajo `set -e`); nada de `/dev/tcp` (bashismo) ni `install -D`
(extensión GNU) en código que la suite ejecuta en cualquier POSIX; un comentario
que empiece por `# shellcheck ` se interpreta como directiva.

## Secretos

`cloud-init/user-data` y `*.iso` están en `.gitignore` porque **incrustan el
token de Cloudflare** con `--cf-token`. CI tiene un guardián que busca
`CF_API_TOKEN=[A-Za-z0-9_-]{12,}` en el árbol excluyendo `tests/` (allí hay
cadenas de prueba deliberadas como `GOODTOKEN`). Los valores literales en
`--cf-token=xxx` son visibles en `ps`: la forma recomendada es `@fichero`, `@-`
o `CF_API_TOKEN`.

## Lo que las pruebas no cubren

Hay que verificarlo a mano en una VM y decirlo en el PR:

- El arranque real desde la ISO y el primer boot.
- El paso `tunnel_service`, que habla con el edge real de Cloudflare.

Si tocas `cloud-init/user-data.tpl`, la unidad systemd o el bloque
`late-commands`, **prueba en una VM**. Ese camino ya se rompió una vez en
silencio; las pruebas automáticas solo comprueban la forma del artefacto, no que
arranque. El README documenta en detalle qué está verificado y qué no, y las
limitaciones conocidas apuntan a incidencias abiertas (#2 integridad de
descargas, #4 sin cortafuegos, #6 túnel sin probar de verdad).

## Commits

Uno por cambio, imperativo, con prefijo (`feat:`, `fix:`, `docs:`, `chore:`).
El cuerpo explica **por qué**, no qué. Si el cambio viene de un fallo observado,
cuenta el fallo: es lo que evita que alguien lo revierta por parecer innecesario.
Incluye qué probaste.
