# © Broadcom. All Rights Reserved.
# The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-2-Clause

<#
    .DESCRIPTION
    Enables Windows Remote Management on Windows builds.
#>

$ErrorActionPreference = 'Stop'

# Set network connections provile to Private mode.
Write-Output 'Setting the network connection profiles to Private...'
$connectionProfile = Get-NetConnectionProfile
While ($connectionProfile.Name -eq 'Identifying...') {
    Start-Sleep -Seconds 10
    $connectionProfile = Get-NetConnectionProfile
}
Set-NetConnectionProfile -Name $connectionProfile.Name -NetworkCategory Private

# Set the Windows Remote Management configuration.
Write-Output 'Setting the Windows Remote Management configuration...'
winrm quickconfig -quiet
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'

# Allow Windows Remote Management in the Windows Firewall.
Write-Output 'Allowing Windows Remote Management in the Windows Firewall...'
netsh advfirewall firewall set rule group="Windows Remote Administration" new enable=yes
netsh advfirewall firewall set rule name="Windows Remote Management (HTTP-In)" new enable=yes action=allow

# Reset the autologon count.
# Reference: https://docs.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-autologon-logoncount#logoncount-known-issue
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoLogonCount -Value 0

# Enable RDP configuration
# Registry
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Set-ItemProperty -Path 'HKLM:\Software\Policies\Microsoft\Windows NT\Terminal Services\Client' -Name fClientDisableUDP -Value 0

# Firewall
New-NetFirewallRule -DisplayName "RDP (TCP)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -RemoteAddress $RemoteAddress -Profile Any -Enabled True | Out-Null
New-NetFirewallRule -DisplayName "RDP (UDP)" -Direction Inbound -Action Allow -Protocol UDP -LocalPort 3389 -RemoteAddress $RemoteAddress -Profile Any -Enabled True | Out-Null

# Set TLS & SSL.
Write-Output "Setting TLS and SSL values..."
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server' -Name "Enabled" Value = 0
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server' -Name "DisabledByDefault" -Value = 1
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Server' -Name "Enabled" Value = 0
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Server' -Name "DisabledByDefault" -Value = 1
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\SSL 2.0\Server' -Name "Enabled" -Value 0
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\SSL 3.0\Server' -Name "Enabled" -Value 0
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server' -Name "Enabled" -Value 1
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.3\Server' -Name "Enabled" -Value 1

# Set SMB Settings
Write-Output "Setting SMB values..."
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force 
Set-SmbServerConfiguration -RequireSecuritySignature $true -Force
Set-SmbServerConfiguration -EnableSMB2Protocol $true -Force

# Set Cipher Suites
Write-Output "Using standard cipher set for Server 2016 or higher..."
$secureCiphers = @(
    "TLS_AES_256_GCM_SHA384", "TLS_AES_128_GCM_SHA256",
    "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384", "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384", "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
    "TLS_DHE_RSA_WITH_AES_256_GCM_SHA384", "TLS_DHE_RSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384", "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256",
    "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384", "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256"
)
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Cryptography\Configuration\Local\SSL\00010002" -Name "Functions" -Value $secureCiphers -PropertyType MultiString -Force

# Set LM Compatibility
Write-Output "Setting Lsa LMCompatibilityLevel to 5..."
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "LMCompatibilityLevel" -Value 5 -Force

# Set LGPO-style Lockout Policy 
Write-Output "Set lockout policy (threshold=3, duration=1440, window=15)..."
net accounts /lockoutthreshold:3
net accounts /lockoutduration:1440
net accounts /lockoutwindow:15

# Set Minimum Password Length
Write-Output "Set minimum password length to 12..."
net accounts /minpwlen:12

# Set CVE-2013-3900 Patch
Write-Output "EnableCertPaddingCheck (CVE-2013-3900 mitigation)..."
$regPath = "HKLM:\Software\Microsoft\Cryptography\Wintrust\Config"
if (-not (Test-Path $regPath)) {
    New-Item -Path "HKLM:\Software\Microsoft\Cryptography\Wintrust" -Name "Config" -Force | Out-Null
}
New-ItemProperty -Path $regPath -Name EnableCertPaddingCheck -Value 1 -PropertyType DWord -Force


