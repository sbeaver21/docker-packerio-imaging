#!/bin/bash
### DHCP

echo "Restarting Network Manager..."
sudo su buildops
systemctl restart NetworkManager
echo "Setting network back to DHCP..."
ens=$(find /sys/class/net -type l -not -lname '*virtual*' -printf '%f\n')
#nmcli device connect ens33
nmcli device connect $ens
#echo $(nmcli device modify ens33 ipv4.method auto)
echo $(nmcli device modify $ens ipv4.method auto)
exit
