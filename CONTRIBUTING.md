# Contribuir

## Reglas del código

**POSIX sh, sin bashismos.** El objetivo es que `setup.sh` corra en `dash`,
`ash`/BusyBox, `bash`, `ksh` y el `sh` de macOS y los BSD. Nada de `[[ ]]`,
arrays, `printf -v`, `${var,,}` ni `local -`. La suite lo comprueba.

**El diagnóstico va a stderr.** `stdout` está reservado para datos. No es
cosmético: hubo un fallo real en que un mensaje de progreso se coló en una
sustitución de comandos y corrompió el valor capturado.

**Cada paso es idempotente y reintentable.** Un paso completado deja una marca
en `/var/lib/coolify-setup/` y no se repite. Si añades un paso, hazlo con
`run_step` y que la función devuelva 0 solo si de verdad terminó.

**Nada que se pueda derivar se pregunta.** Antes de añadir una pregunta,
convénceme de que el dato no se puede obtener por API, deducir del sistema o
generar.

## Antes de abrir un PR

```bash
make lint
make test
```

CI ejecuta lo mismo y además exige que **ningún grupo de pruebas se omita**: si
falta una dependencia en el runner, falla en vez de dar verde sin haber
probado.

## Lo que la suite no cubre

Dos cosas hay que probarlas a mano en una máquina virtual:

- El arranque real desde la ISO y el primer boot.
- El paso `tunnel_service`, que habla con el edge real de Cloudflare.

Si tocas `cloud-init/user-data.tpl`, la unidad systemd o el bloque
`late-commands`, **prueba en una VM** y di en el PR qué comprobaste. Ese camino
ya se rompió una vez en silencio (incidencia #1) y las pruebas automáticas solo
cubren la forma del artefacto, no que arranque.

## Commits

Uno por cambio, en imperativo y con prefijo (`feat:`, `fix:`, `docs:`,
`chore:`). El cuerpo explica **por qué**, no qué: el diff ya dice qué. Si el
cambio viene de un fallo observado, cuenta el fallo — es lo que evita que
alguien lo revierta por parecer innecesario.

Incluye qué probaste. Un commit sin evidencia de prueba es una hipótesis.
