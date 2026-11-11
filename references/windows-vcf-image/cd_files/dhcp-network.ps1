<#
    .NOTES  Author:
    Stephen Beaver

    .DESCRIPTION
    Set dhcp network configuration on Windows builds.
#>

$ErrorActionPreference = 'Stop'

# Configure the network interface to DHCP
Write-Output 'Showing the current IP address, subnet mask, and default gateway...'
Write-Output $(netsh interface ip show config)
Write-Output $(netsh interface ipv4 show addresses)
Write-Output 'Setting the IP address, subnet mask, and default gateway to DHCP...'
Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -Command `"netsh interface ip set dns $((get-netadapter).Name) dhcp; netsh interface ip set address $((get-netadapter).Name) dhcp; exit;`"" -Verb RunAs
exit;
