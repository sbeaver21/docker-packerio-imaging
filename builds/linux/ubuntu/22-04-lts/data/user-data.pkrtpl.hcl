#cloud-config

# Copyright 2023-2024 Broadcom. All rights reserved.
# SPDX-License-Identifier: BSD-2

# Ubuntu Server 24.04 LTS

autoinstall:
  version: 1
  # Refresh to the latest snap built from the "main" subiquity branch
  refresh-installer:
    update: true
    channel: latest/edge
  apt:
    geoip: true
    preserve_sources_list: false
    primary:
      - arches: [amd64, i386]
        uri: http://archive.ubuntu.com/ubuntu
      - arches: [default]
        uri: http://ports.ubuntu.com/ubuntu-ports
  early-commands:
    - sudo systemctl stop ssh
  locale: ${vm_guest_os_language}
  keyboard:
    layout: ${vm_guest_os_keyboard}
  write_files:
  - path: /etc/ssh/sshd_config
    content: |
         Port 22
         Protocol 2
         HostKey /etc/ssh/ssh_host_rsa_key
         HostKey /etc/ssh/ssh_host_dsa_key
         HostKey /etc/ssh/ssh_host_ecdsa_key
         HostKey /etc/ssh/ssh_host_ed25519_key
         UsePrivilegeSeparation yes
         KeyRegenerationInterval 3600
         ServerKeyBits 1024
         SyslogFacility AUTH
         LogLevel INFO
         LoginGraceTime 120
         PermitRootLogin yes
         StrictModes no
         RSAAuthentication yes
         PubkeyAuthentication no
         IgnoreRhosts yes
         RhostsRSAAuthentication no
         HostbasedAuthentication no
         PermitEmptyPasswords no
         ChallengeResponseAuthentication no
         X11Forwarding yes
         X11DisplayOffset 10
         PrintMotd no
         PrintLastLog yes
         TCPKeepAlive yes
         AcceptEnv LANG LC_*
         Subsystem sftp /usr/lib/openssh/sftp-server
         UsePAM yes
         AllowUsers ubuntu
${storage}
${network}
  identity:
    hostname: ubuntu-server
    username: ${build_username}
    password: ${build_password_encrypted}
  ssh:
    install-server: true
    allow-pw: true
  packages:
    - openssh-server
    - open-vm-tools
    - cloud-init
%{ for package in additional_packages ~}
    - ${package}
%{ endfor ~}
  user-data:
    disable_root: false
    timezone: ${vm_guest_os_timezone}
    users:
      - name: ${build_username}
        gecos: ${build_username}
        passwd: ${build_password_encrypted}
        groups: adm, cdrom, dip, lxd, plugdev, sudo
        shell: /bin/bash
        lock_passwd: False
      - name: ${auto_username}
        gecos: ${auto_username}
        passwd: ${auto_password_encrypted}
        groups: adm, cdrom, dip, lxd, plugdev, sudo
        shell: /bin/bash
        lock_passwd: False
  late-commands:
    - sed -i -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /target/etc/ssh/sshd_config
    - echo '${build_username} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/${build_username}
    - curtin in-target --target=/target -- chmod 440 /etc/sudoers.d/${build_username}
    - echo '${build_username} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/${build_username}
    - curtin in-target --target=/target -- chmod 440 /etc/sudoers.d/${build_username}
    - echo '${auto_username} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/${auto_username}
    - curtin in-target --target=/target -- chmod 440 /etc/sudoers.d/${auto_username}

