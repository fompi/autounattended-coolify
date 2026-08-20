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
  #
  # El patron es "e*" y no "en*" a proposito. Los nombres predecibles de
  # systemd empiezan por 'en' (enp1s0, ens3, eno1, enx...), pero cuando no hay
  # informacion de firmware o de bus estable el kernel se queda con el nombre
  # clasico 'eth0': pasa en maquinas virtuales con virtio-mmio y en bastante
  # hardware embebido. Con "en*" esas maquinas se quedaban SIN NINGUNA
  # configuracion de red, y como el asistente va After=network-online.target,
  # no llegaba a ejecutarse nunca. Comprobado en VM: la interfaz era eth0.
  network:
    version: 2
    ethernets:
      any-eth:
        match:
          name: "e*"
        dhcp4: true
        dhcp-identifier: mac
        optional: true

  # Todo el disco, LVM. Subiquity crea la ESP automaticamente si el arranque
  # detectado es UEFI, y una particion bios_grub si es BIOS heredado: el mismo
  # fichero sirve para los dos modos.
  storage:
    layout:
      name: lvm

  # Cuenta de servicio para completar la instalacion. Por defecto nace
  # bloqueada ('!' en el campo de contrasena de /etc/shadow) y nadie inicia
  # sesion con ella: setup.sh crea el usuario administrador real en el primer
  # arranque. Con build-usb.sh --rescue-password aqui va un hash real, para
  # tener una via de entrada si el asistente fallara.
  identity:
    hostname: ubuntu-tmp
    username: installer
    password: "__INSTALLER_PW_HASH__"

  ssh:
    install-server: true
    allow-pw: true

  # Lo minimo para que setup.sh arranque; el descarga o instala lo demas.
  packages:
    - curl
    - ca-certificates
    - whiptail
    - jq

  # Camino PRINCIPAL de instalacion del asistente.
  #
  # Se hace aqui, y no via cloud-init del sistema destino, porque depender de
  # que el cloud-init del destino re-ejecute modulos per-instance (write_files,
  # runcmd) resulto ser fragil: en las pruebas el servicio no llegaba a
  # instalarse nunca y fallaba en silencio, sin errores. Ver incidencia #1.
  #
  # late-commands corre en el entorno del instalador, con el sistema instalado
  # montado en /target, en un momento conocido y a la vista en la consola.
  #
  # Dos precauciones que vienen de haber roto esto antes:
  #   - El bloque termina SIEMPRE en 'true'. Un late-commands que devuelve
  #     error aborta la instalacion entera y deja el equipo sin instalar.
  #   - No se usa 'systemctl' dentro de /target: el enlace en
  #     multi-user.target.wants se crea a mano, que es exactamente lo que hace
  #     'systemctl enable' y no necesita un systemd corriendo alli.
  late-commands:
    - |
      for d in /cdrom/cidata /media/cdrom/cidata /run/media/cdrom/cidata; do
        if [ -f "$d/coolify-setup.sh" ]; then
          install -D -m 0755 "$d/coolify-setup.sh" /target/usr/local/sbin/coolify-setup.sh
          install -D -m 0644 "$d/coolify-setup.service" /target/etc/systemd/system/coolify-setup.service
          if [ -f "$d/coolify-setup.env" ]; then
            install -D -m 0600 "$d/coolify-setup.env" /target/etc/coolify-setup.env
          fi
          if [ -f "$d/coolify-setup.pub" ]; then
            install -D -m 0644 "$d/coolify-setup.pub" /target/etc/coolify-setup.pub
          fi
          mkdir -p /target/etc/systemd/system/multi-user.target.wants
          ln -sf ../coolify-setup.service \
            /target/etc/systemd/system/multi-user.target.wants/coolify-setup.service
          echo "coolify-setup: instalado desde $d"
          break
        fi
      done
      true

  # Camino REDUNDANTE. Si el cloud-init del destino si procesa esto, escribe
  # los mismos ficheros; es idempotente con lo que ya hizo late-commands. Se
  # mantiene porque cubre el caso de arrancar desde una particion CIDATA
  # suelta, donde no hay /cdrom/cidata del que copiar.
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
__UNIT_FILE__
__ENV_FILE__
    # 'enable' a secas no bastaria: runcmd corre en la fase final de
    # cloud-init, cuando multi-user.target ya se alcanzo, asi que el asistente
    # no arrancaria hasta el segundo reinicio. Con --no-block porque es
    # interactivo y cloud-init no debe quedarse esperandolo.
    runcmd:
      - [ systemctl, daemon-reload ]
      - [ systemctl, enable, coolify-setup.service ]
      - [ systemctl, start, --no-block, coolify-setup.service ]
