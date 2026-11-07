# Copyright 2023-2024 Broadcom. All Rights Reserved.
# SPDX-License-Identifier: BSD-2

<#
    .DESCRIPTION
    Set tmp network configuration on Windows builds.
#>

$ErrorActionPreference = 'Stop'

# Set the static IP address, subnet mask, and default gateway
Write-Output 'Setting the static IP address, subnet mask, and default gateway...'
Write-Output $(netsh interface ipv4 show addresses)
netsh interface ipv4 set address "Ethernet0" static "192.0.2.40" "255.255.255.0" "192.0.2.1"
netsh interface ipv4 add dnsserver "Ethernet0" address=192.0.2.53 index=1
netsh interface ipv4 add dnsserver "Ethernet0" address=192.0.2.54 index=2
Write-Output $(netsh interface ipv4 show addresses)
