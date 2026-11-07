%{ if ip != null ~}
        "type": "static",
        "ip_addr": "${ip}",
        "netmask": "${cidrnetmask("${ip}/${netmask}")}",
        "gateway": "${gateway}",
        "dns": "${join(" ", dns)}"
%{ else ~}
        "type": "dhcp"
%{ endif ~}