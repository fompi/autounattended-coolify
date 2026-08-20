#cloud-config
# Plantilla de autoinstall para Ubuntu Server.
# No editar a mano: build-usb.sh la rellena y genera cloud-init/user-data.
autoinstall:
  version: 1

  locale: en_US.UTF-8
  keyboard:
    layout: __KEYBOARD__

  # DHCP en cualquier interfaz cableada. Si el equipo solo tuviera WiFi,
  # setup.sh la configura en el primer arranque.
  network:
    version: 2
    ethernets:
      any-eth:
        match:
          name: "en*"
        dhcp4: true
        dhcp-identifier: mac
        optional: true

  # Todo el disco, LVM. Subiquity crea la ESP automáticamente si el arranque
  # detectado es UEFI, y una partición bios_grub si es BIOS heredado: el mismo
  # fichero sirve para los dos modos.
  storage:
    layout:
      name: lvm

  # Cuenta de servicio para completar la instalación. Nace bloqueada ('!' en
  # el campo de contraseña de /etc/shadow) y nadie inicia sesión con ella:
  # setup.sh crea el usuario administrador real en el primer arranque. Así no
  # hay ningún hash ni contraseña que generar al construir el USB.
  identity:
    hostname: ubuntu-tmp
    username: installer
    password: "!"

  ssh:
    install-server: true
    allow-pw: true

  # Lo mínimo para que setup.sh arranque; él descarga o instala lo demás.
  packages:
    - curl
    - ca-certificates
    - whiptail
    - jq

  # Bloque que cloud-init vuelve a procesar dentro del sistema ya instalado.
  user-data:
    write_files:
      - path: /usr/local/sbin/coolify-setup.sh
        owner: root:root
        permissions: '0755'
        content: |
__SETUP_SH__

      - path: /etc/systemd/system/coolify-setup.service
        owner: root:root
        permissions: '0644'
        content: |
          [Unit]
          Description=Configuracion de primer arranque (Docker + Coolify + Cloudflare Tunnel)
          After=network-online.target
          Wants=network-online.target
          # Toma la consola en exclusiva para que el asistente no compita con
          # el login.
          Conflicts=getty@tty1.service serial-getty@ttyS0.service
          Before=getty@tty1.service serial-getty@ttyS0.service
          ConditionPathExists=!/var/lib/coolify-setup/completed

          [Service]
          Type=oneshot
          # El token viaja por entorno, no por linea de comandos: asi no queda
          # visible en 'ps'. El guion '-' hace opcional el fichero.
          EnvironmentFile=-/etc/coolify-setup.env
          ExecStart=/usr/local/sbin/coolify-setup.sh
          StandardInput=tty-force
          StandardOutput=tty
          StandardError=tty
          # /dev/console, no /dev/tty1: apunta a la consola que el kernel tenga
          # configurada. Con monitor es la pantalla; en un equipo headless por
          # puerto serie (o en una VM) es la serie. Fijar tty1 dejaba el
          # asistente en una consola que nadie ve. Comprobado en VM.
          TTYPath=/dev/console
          TTYReset=yes
          TTYVHangup=yes
          RemainAfterExit=no
          TimeoutStartSec=infinity

          [Install]
          WantedBy=multi-user.target
__ENV_FILE__
    # runcmd corre en la fase final de cloud-init, cuando multi-user.target ya
    # se ha alcanzado: con 'enable' a secas el asistente no arrancaria hasta el
    # SEGUNDO reinicio, asi que hay que arrancarlo explicitamente. Y con
    # --no-block, porque el asistente es interactivo y puede tardar lo que
    # quiera: sin eso, cloud-init se quedaria esperandolo.
    runcmd:
      - [ systemctl, daemon-reload ]
      - [ systemctl, enable, coolify-setup.service ]
      - [ systemctl, start, --no-block, coolify-setup.service ]

  # Aqui NO va ningun 'late-commands' que toque coolify-setup.service: durante
  # la instalacion la unidad todavia no existe (la escribe cloud-init en el
  # primer arranque), asi que un 'systemctl enable' fallaria y, como
  # late-commands aborta la instalacion al fallar, dejaria el equipo sin
  # instalar. Comprobado en VM.
