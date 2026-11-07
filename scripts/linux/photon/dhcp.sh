#!/bin/bash
### DHCP

echo "Restarting Network Manager..."
sudo su buildops
systemctl restart NetworkManager
echo "Setting network back to DHCP..."
nmcli device connect ens192
echo $(nmcli device modify ens192 ipv4.method auto)
exit
