## Qué cambia y por qué

<!-- El diff ya dice qué. Cuenta por qué. Si viene de un fallo observado,
     describe el fallo: es lo que evita que alguien lo revierta después. -->

Cierra #

## Qué he probado

<!-- Un PR sin evidencia de prueba es una hipótesis. -->

- [ ] `make lint`
- [ ] `make test`
- [ ] Probado en una VM (**obligatorio** si tocas `user-data.tpl`, la unidad
      systemd o el bloque `late-commands`: ese camino ya se rompió una vez en
      silencio, y las pruebas automáticas solo cubren la forma del artefacto,
      no que arranque)

Detalle de lo probado a mano:

## Comprobaciones

- [ ] Sin bashismos
- [ ] El diagnóstico va a stderr, no a stdout
- [ ] No añade preguntas que se puedan derivar
- [ ] No introduce secretos en el repositorio ni en los logs
- [ ] Documentación y `CHANGELOG.md` al día
