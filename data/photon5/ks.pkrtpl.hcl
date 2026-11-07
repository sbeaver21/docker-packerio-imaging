{
    "hostname": "${vm_hostname}",
    "password":
        {
            "crypted": false,
            "text": "Vmware@123!Vmware@123!"
        },
    "disk": "/dev/sda",
    "partitions":[
       {
          "mountpoint":"/",
          "size":0,
          "filesystem":"ext4",
          "lvm":{
             "vg_name":"vg1",
             "lv_name":"rootfs"
            }
       },
       {
          "mountpoint":"/boot",
          "size":128,
          "filesystem":"ext4"
       },
       {
          "mountpoint":"/root",
          "size":128,
          "filesystem":"ext4",
          "lvm":{
             "vg_name":"vg1",
             "lv_name":"root"
          }
       },
       {
          "size":128,
          "filesystem":"swap",
          "lvm":{
             "vg_name":"vg2",
             "lv_name":"swap"
          }
       }
    ],
    "bootmode": "efi",
    "packages": [
        "minimal",
        "linux",
        "initramfs",
        "sudo",
        "vim",
%{ for package in additional_packages ~}
        "${package}",
%{ endfor ~}
        "cloud-utils"
    ],
    "postinstall": [
        "#!/bin/sh",
        "useradd -m -p '${build_password_encrypted}' -s /bin/bash ${build_username}",
        "usermod -aG sudo ${build_username}",
        "echo \"${build_username} ALL=(ALL) NOPASSWD: ALL\" >> /etc/sudoers.d/${build_username}",
        "chage -I -1 -m 0 -M 99999 -E -1 root",
        "chage -I -1 -m 0 -M 99999 -E -1 ${build_username}",
        "systemctl restart iptables",
        "rm -f /etc/resolv.conf",
%{ for server in dns ~}
        "echo 'nameserver ${server}' >> /etc/resolv.conf",
%{ endfor ~}
        "chmod 0644 /etc/resolv.conf",
        "sed -i 's/.*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config",
        "sed -i 's/.*MaxAuthTries.*/MaxAuthTries 10/g' /etc/ssh/sshd_config",
        "systemctl restart sshd.service"
    ],
    "linux_flavor": "linux",
    "network": {
        "type": "static",
        "ip_addr": "${ip}",
        "netmask": "${cidrnetmask("${ip}/${netmask}")}",
        "gateway": "${gateway}",
        "dns": "${join(" ", dns)}"
    }
}
