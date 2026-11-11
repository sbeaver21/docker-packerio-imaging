# Copyright 2023-2024 Broadcom. All Rights Reserved.
# SPDX-License-Identifier: BSD-2

<#
    .DESCRIPTION
    Install Cloudbased-init on Windows builds for customization.
#>

$ErrorActionPreference = 'Stop'

$msiPath = "$env:TEMP\CloudbaseInitSetup.msi"
$cbiConfDir = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf"

Write-Output 'Installing Cloudbase-Init silently...'
# Install without immediately launching Sysprep from the installer wizard
# Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart RUN_SERVICE_AS_LOCAL_SYSTEM=1" -Wait
Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /passive /norestart RUN_SERVICE_AS_LOCAL_SYSTEM=1" -Wait

Write-Output "Applying custom configuration files..."
if (Test-Path "$env:TEMP\cloudbase-init.conf") {
    Copy-Item -Path "$env:TEMP\cloudbase-init.conf" -Destination "$cbiConfDir\cloudbase-init.conf" -Force
}
if (Test-Path "F:\cloudbase-init-unattend.conf") {
    Copy-Item -Path "$env:TEMP\cloudbase-init-unattend.conf" -Destination "$cbiConfDir\cloudbase-init-unattend.conf" -Force
}

Write-Output 'Clearing old installation logs...'
if (Test-Path "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log") {
    Remove-Item -Path "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\*" -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'Executing Sysprep and shutting down...'
# You must specify Cloudbase-init's custom Unattend.xml file to tie in cloudbase-init-unattend.conf during specialization
Start-Process -FilePath "C:\Windows\System32\Sysprep\sysprep.exe" `
              -ArgumentList "/generalize /oobe /shutdown /mode:vm `"/unattend:$cbiConfDir\Unattend.xml`"" `
              -Wait
