%{ if ip != null ~}
network --device=${device} --bootproto=static --ip=${ip} --netmask=${cidrnetmask("${ip}/${netmask}")} --gateway=${gateway} --nameserver=${join(",", dns)} --hostname=${name} --noipv6 --activate 
%{ else ~}
network --device=${device} --bootproto=dhcp --noipv6 --activate 
%{ endif ~}