# Registro de cambios

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/).
Versionado [semántico](https://semver.org/lang/es/).

## [No publicado]

### Añadido
- Suite de pruebas (`tests/run.sh`) con 81 comprobaciones y un simulador de la
  API de Cloudflare.
- Integración continua: shellcheck en dialecto `sh`, sintaxis en cinco shells,
  la suite completa y comprobaciones de que no se filtran secretos.
- `LICENSE` (MIT), `SECURITY.md` con el modelo de amenaza, `CONTRIBUTING.md`,
  `Makefile` y plantillas de incidencia y de PR.

### Corregido
- El bloque `late-commands` usaba `install -D`, que es una extensión de GNU.
  Ahora `mkdir -p` + `cp` + `chmod`, para poder ejecutarlo y comprobarlo en
  cualquier POSIX.

## [0.2.0] — 2026-08-21

### Corregido
- **El asistente de primer arranque no se ejecutaba** ([#1]). Tres defectos:
  dependía de que el cloud-init del destino re-ejecutase módulos
  *per-instance*; el netplan hacía match con `en*` y dejaba sin red a las
  máquinas cuya interfaz es `eth0`; y la unidad llevaba `Before=` de las getty,
  con lo que un asistente colgado dejaba el equipo sin login.

### Añadido
- `--rescue-password` en `build-usb.sh`.
- Reempaquetado de la ISO con `--iso`: mete el `cidata` dentro y añade
  `autoinstall` al arranque, para que el USB sea un único `dd`.

## [0.1.0] — 2026-08-20

### Añadido
- `setup.sh`: instalador portable en POSIX sh de Docker, Coolify y el túnel.
- Plantilla de autoinstall y `build-usb.sh`.

[#1]: https://github.com/fompi/autounattended-coolify/issues/1
