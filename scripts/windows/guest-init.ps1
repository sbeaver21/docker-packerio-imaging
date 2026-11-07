
<#
    .DESCRIPTION
    Performs image automation configuration on Windows builds.
#>

$ErrorActionPreference = 'Stop'

### Image Automation Custom Additions ###

# Set Network Ring and Buffer Size
try
  {
    Write-Output "Getting Ring and Buffer Sizes..."
    Write-Output (Get-NetAdapterAdvancedProperty (Get-NetAdapter | where status -eq "Up" | select -ExpandProperty name) -DisplayName "Small Rx Buffers")
    Write-Output "Current Small Rx Buffer = " (Get-NetAdapterAdvancedProperty (Get-NetAdapter | where status -eq "Up" | select -ExpandProperty name) -DisplayName "Small Rx Buffers").DisplayValue
    $rxBuffer = (Get-NetAdapterAdvancedProperty (Get-NetAdapter | where status -eq "Up" | select -ExpandProperty name) -DisplayName "Small Rx Buffers").DisplayValue
    Write-Output (Get-NetAdapterAdvancedProperty (Get-NetAdapter | where status -eq "Up" | select -ExpandProperty name) -DisplayName "Rx Ring #1 Size")
    Write-Output "Current Rx Ring #1 Size = " (Get-NetAdapterAdvancedProperty (Get-NetAdapter | where status -eq "Up" | select -ExpandProperty name) -DisplayName "Rx Ring #1 Size").DisplayValue
    $rxRing = (Get-NetAdapterAdvancedProperty (Get-NetAdapter | where status -eq "Up" | select -ExpandProperty name) -DisplayName "Rx Ring #1 Size").DisplayValue
    Write-Output "Setting Ring and Buffer Sizes..."
	if ( $rxBuffer -ne "8192" )  {
       Set-NetAdapterAdvancedProperty (Get-NetAdapter | where status -eq "Up" | select -ExpandProperty name) -DisplayName "Small Rx Buffers" -DisplayValue "8192" -NoRestart -Verbose
    }
	if ( $rxRing -ne "4096" )  {
	   Set-NetAdapterAdvancedProperty (Get-NetAdapter | where status -eq "Up" | select -ExpandProperty name) -DisplayName "Rx Ring #1 Size" -DisplayValue "4096" -NoRestart -Verbose
	}   
} catch {
	Write-Error "Setting Ring and Buffer Sizes Failed..."
	Write-Error $_.Exception
}

# Enable Remote Desktop.
Write-Output "Enabling Remote Desktop..."
try
  {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0 | Out-Null
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -name "UserAuthentication" -Value 0
    Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'
  } catch {
	Write-Error "Enabling Remote Desktop Failed ..."
	Write-Error $_.Exception
  }	

# Make CD folder hidden
Write-Error "Making the CD Folder Hidden Failed..."
try
  {
    Set-ItemProperty -LiteralPath "C:\CD" -Name Attributes -Value Hidden
  } catch {
	Write-Error $_.Exception
  }	

# Enable Ultimate Performance
$out = & "$env:windir\System32\powercfg.exe" /DuplicateScheme 'e9a42b02-d5df-448d-aa00-03f14749eb61';
if( $out -match '\s([a-f0-9-]{36})\s' ) {
    & "$env:windir\System32\powercfg.exe" /SetActive $Matches[1];
} else {
    'Could not enable Ultimate Performance power scheme.' | Write-Warning;
}

# Enable High Performance
Write-Output "Enabling High Performance Power Plan Settings..."
try
  {
    # Sets High Performance Power Plan Settings
    $HighPerf = powercfg -l | ForEach-Object {if($_.contains("High performance")) {$_.split()[3]}}
    $CurrPlan = $(powercfg -getactivescheme).split()[3]
    if ($CurrPlan -eq $HighPerf){
      Write-Output "High Performance Power Plan Already Enabled"
    }else{
      powercfg -setactive $HighPerf
      Write-Output "High Performance Power Plan Enabled"
    }
} catch {
	Write-Error "Failed to set the power to high performance..."
	Write-Error $_.Exception
}

# Disable TCP IP Version 6
try
  {
    Write-Output "Disabling TCP IP Version 6..."
	Write-Output $(Get-ItemProperty "HKLM:SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters")
    New-ItemProperty "HKLM:SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" -Name "DisabledComponents" -Value 0xff -PropertyType "DWord"
} catch {
	Write-Error "Failed to disable TCP IP Version 6..."
	Write-Error $_.Exception
}
Write-Output "End of image init..."
