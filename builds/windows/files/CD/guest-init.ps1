
<#
    .DESCRIPTION
    Performs image automation configuration on Windows builds.
#>

$ErrorActionPreference = 'Stop'

### Image Automation Custom Additions ###

# Set CD-ROM Drive Letter to Z
Write-Output "Change drive letter of the CD-ROM to Z:..."
Get-WmiObject -Class Win32_volume -Filter "DriveType=5" | Select-Object -First 1 | Set-WmiInstance -Arguments @{DriveLetter="Z:"}

# Set Network Ring and Buffer Size
Write-Output "Setting Ring and Buffer Sizes..."
Set-NetAdapterAdvancedProperty (Get-NetAdapter | where status -eq "Up" | select -ExpandProperty name) -DisplayName "Small Rx Buffers" -DisplayValue "8192" -NoRestart -Verbose
Set-NetAdapterAdvancedProperty (Get-NetAdapter | where status -eq "Up" | select -ExpandProperty name) -DisplayName "Rx Ring #1 Size" -DisplayValue "4096" -NoRestart -Verbose

# Disable TCP IP Version 6
Write-Output "Disabling TCP IP Version 6..."
New-ItemProperty "HKLM:SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" -Name "DisabledComponents" -Value 0xff -PropertyType "DWord"

# Make CD folder hidden
Write-Output "Making the CD Folder Hidden..."
Set-ItemProperty -LiteralPath "C:\CD" -Name Attributes -Value Hidden
