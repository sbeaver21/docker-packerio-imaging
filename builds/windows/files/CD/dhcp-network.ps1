# Copyright 2023-2024 Broadcom. All Rights Reserved.
# SPDX-License-Identifier: BSD-2

<#
    .DESCRIPTION
    Set dhcp network configuration on Windows builds.
#>

$ErrorActionPreference = 'Stop'

# Configure the network interface to DHCP
Write-Output 'Setting the IP address, subnet mask, and default gateway to DHCP...'
Write-Output $(netsh interface ip show config)
Write-Output $(netsh interface ipv4 show addresses)
netsh interface ip set dns "$((get-netadapter).Name)" dhcp
netsh interface ip set address "$((get-netadapter).Name)" dhcp
exit
