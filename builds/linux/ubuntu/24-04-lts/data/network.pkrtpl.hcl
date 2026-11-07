  network:
    network:
      version: 2
      ethernets:
%{ if ip != null ~}
        # Use wildcards to match any interface starting with 'ens'
        en-all:
          match:
            name: "ens*"
          dhcp4: false
          addresses:
            - ${ip}/${netmask}
          routes:
            - to: default
              via: ${gateway}
          nameservers:
            addresses:
%{ for item in dns ~}
              - ${item}
%{ endfor ~}
%{ else ~}
        en-all:
          match:
            name: "ens*"
          dhcp4: true
%{ endif ~}