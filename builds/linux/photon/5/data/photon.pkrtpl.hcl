{
   "arch": "x86_64",
   "hostname":"photon",
   "password":{
      "crypted":true,
      "text":"${root_password_encrypted}"
   },
   "os_display_name": "VMware Photon OS 64-bit",
   "install_linux_esx": true
   "bootmode": "efi",
   "linux_flavor": "linux-esx"
   "bootmode": "efi",
   "network":{
        "ip_family": "ipv4",
        "mode": "static",
        "type": "static",
        "ip_addr": "${ip}",
        "netmask": "${cidrnetmask("${ip}/${netmask}")}",
        "gateway": "${gateway}",
        "nameserver": "${join(" ", dns)}"
   },
  "ssh_enable": true,
  "timezone": "UTC",
  "keyboard": "us",
   "disk":"/dev/sda",
   "partitions":[
      {
         "mountpoint":"/",
         "size":0,
         "filesystem":"ext4"
      },
      {
         "mountpoint":"/boot",
         "size":128,
         "filesystem":"ext4"
      },
      {
         "mountpoint":"/root",
         "size":128,
         "filesystem":"ext4"
      },
      {
         "size":128,
         "filesystem":"swap"
      }
   ],
   "packages": [
     "bash",
     "bc",
     "bridge-utils",
     "bzip2",
     "ca-certificates",
     "cloud-init",
     "cpio",
     "cracklib-dicts",
     "dbus",
     "e2fsprogs",
     "file",
     "filesystem",
     "findutils",
     "gdbm",
     "grep",
     "gzip",
     "iana-etc",
     "initramfs",
     "iptables",
     "iproute2",
     "iputils",
     "libtool",
     "linux",
     "motd",
     "net-tools",
     "openssh-server",
     "open-vm-tools",
     "pkg-config",
     "photon-release",
     "photon-repos",
     "procps-ng",
     "rpm",
     "sed",
     "sudo",
     "tdnf",
     "tzdata",
     "util-linux",
     "vim",
     "which"
   ],
   //#"packagelist_file": "packages_${os_packagelist}.json",
   "postinstall":[
      "#!/bin/sh",
      "chage -I -1 -m 0 -M 99999 -E -1 ${build_username}",
      "sed -i 's/PermitRootLogin no/PermitRootLogin yes/g' /etc/ssh/sshd_config",
      "sed -i 's/.*MaxAuthTries.*/MaxAuthTries 10/g' /etc/ssh/sshd_config",
      "systemctl restart sshd.service"
   ]
}