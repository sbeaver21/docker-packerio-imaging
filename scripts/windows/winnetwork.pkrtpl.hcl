<#
.--------------------------------------------------------------------------------------------------
.Created : Image-Automation - Server Operations
.Author  : Stephen Beaver
.Version : v1.0
.Date    : 09-2025
.Modified: 
.--------------------------------------------------------------------------------------------------
.SYNOPSIS
    A simple Powershell script to set a tempary network configuration for VMware golden images via docker-packerio-imaging.

.DESCRIPTION
    Set tmp network configuration on Windows builds.
.--------------------------------------------------------------------------------------------------
#>

Write-Host ""
Write-Host "Windows Build Image Temporary Network Configuration" -ForegroundColor White
Write-Host ""

# Stop on all errors
$ErrorActionPreference = 'Stop'

# Set the static IP address, subnet mask, and default gateway
Write-Output 'Setting the static IP address, subnet mask, and default gateway...'
netsh interface ipv4 set address "$((get-netadapter).Name)" static ${ip} ${netmask} ${gateway}
netsh interface ipv4 add dnsserver "$((get-netadapter).Name)" address=${dns[0]} index=1
netsh interface ipv4 add dnsserver "$((get-netadapter).Name)" address=${dns[1]} index=2
Write-Output $(netsh interface ipv4 show addresses)
