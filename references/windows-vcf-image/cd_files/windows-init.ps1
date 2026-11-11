<#
    .NOTES  Author:
    Stephen Beaver

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
Write-Output 'Create RDP allow firewall rules...'
New-NetFirewallRule -DisplayName "RDP (TCP)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -RemoteAddress $RemoteAddress -Profile Any -Enabled True | Out-Null
New-NetFirewallRule -DisplayName "RDP (UDP)" -Direction Inbound -Action Allow -Protocol UDP -LocalPort 3389 -RemoteAddress $RemoteAddress -Profile Any -Enabled True | Out-Null
# Allow all IPv4 Echo Requests (Ping)
Write-Output 'Allow all Echo Requests (Ping)...'
New-NetFirewallRule -DisplayName "ICMP Allow V4 Ping" -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Action Allow
New-NetFirewallRule -DisplayName "ICMP Allow V6 Ping" -Direction Inbound -Protocol ICMPv6 -IcmpType 8 -Action Allow
netsh advfirewall firewall add rule name= "All ICMP V4" protocol=icmpv4:any,any dir=in action=allow

# Install PowerShell 7 Core PWSH
Write-Output 'Installing PowerShell 7 Core PWSH Latest'
try
	{
	#iex "& { $(irm https://aka.ms/install-powershell.ps1) } -UseMSI -Quiet"
    Start-Process powershell -ArgumentList '-NoProfile -Command iex ""& { $(irm https://aka.ms/install-powershell.ps1) } -UseMSI -Quiet""' -Verb RunAs
} catch {
	Write-Output 'Failed to install PowerShell 7 Core...'
	Write-Output $_.Exception 
}

# $msiUrl = 'https://cloudbase.it'
# $msiPath = "$env:TEMP\\CloudbaseInitSetup.msi"
# Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath

Write-Output 'Copy cloudbased-init files...'
try
	{
	if (Test-Path "F:\CloudbaseInitSetup.msi") {
		Copy-Item -Path "F:\CloudbaseInitSetup.msi" -Destination "C:\Windows\Temp\CloudbaseInitSetup.msi" -Force
	}
	if (Test-Path "F:\cloudbase-init.conf") {
		Copy-Item -Path "F:\cloudbase-init.conf" -Destination "C:\Windows\Temp\cloudbase-init.conf" -Force
	}
	if (Test-Path "F:\cloudbase-init-unattend.conf") {
		Copy-Item -Path "F:\cloudbase-init-unattend.conf" -Destination "C:\Windows\Temp\cloudbase-init-unattend.conf" -Force
	}
	if (Test-Path "F:\cloudbased-init-local.ps1") {
		Copy-Item -Path "F:\cloudbase-init-local.ps1" -Destination "C:\Windows\Temp\cloudbase-init-local.ps1" -Force
	}
} catch {
	Write-Output 'Failed to copy cloudbased-init files...'
	Write-Output $_.Exception 
}	

# Disable all Firewall profiles
#NetSh AdvFirewall Show AllProfiles State
#Write-Output 'Disable all Firewall profiles...'
#Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
#NetSh AdvFirewall set AllProfiles State Off
#NetSh AdvFirewall Show AllProfiles State