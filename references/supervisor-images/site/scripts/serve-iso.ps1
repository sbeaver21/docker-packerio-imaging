<#
.SYNOPSIS
    Serves ISO files from the project's iso/ directory over HTTP for vSphere Supervisor image import.
.DESCRIPTION
    Starts a lightweight Python HTTP server on a configurable port to serve ISO files
    so that the vSphere Supervisor cluster can access them for image import.
    Displays available ISOs, local IP addresses, and example import_source_url usage.
.PARAMETER Port
    TCP port for the HTTP server. Must be between 1 and 65535. Default is 8080.
.PARAMETER IsoDir
    Path to the directory containing ISO files. If not provided, defaults to
    <repo-root>/iso relative to the script location.
.EXAMPLE
    .\serve-iso.ps1
    .\serve-iso.ps1 -Port 9090
    .\serve-iso.ps1 -Port 8080 -IsoDir "C:\ISOs"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 65535)]
    [int]$Port = 8080,

    [Parameter(Mandatory = $false)]
    [string]$IsoDir = ""
)

# --- Resolve ISO directory ---
if (-not $IsoDir) {
    # Four levels up: scripts/ -> site/ -> supervisor-images/ -> references/ -> root.
    # Plain path arithmetic rather than Join-Path -AdditionalChildPath, which is
    # Windows PowerShell 5.1-incompatible and is not the parameter's real name.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "..\..\..\.."))
    $IsoDir = Join-Path -Path $repoRoot -ChildPath "iso"
}

# Resolve to a full path; fail early if the path doesn't exist or can't be resolved
try {
    $IsoDir = Resolve-Path -Path $IsoDir -ErrorAction Stop
} catch {
    Write-Error "ISO directory not found or inaccessible: $IsoDir"
    exit 1
}

# --- Verify Python availability ---
$pythonCmd = Get-Command -Name "python" -ErrorAction SilentlyContinue
if (-not $pythonCmd) {
    Write-Error "Python 3 is required but 'python' was not found on the PATH. Please install Python 3 and try again."
    exit 1
}

# --- Cache ISO file metadata (single filesystem pass) ---
$isoFiles = Get-ChildItem -Path $IsoDir -Filter "*.iso" -File

if ($isoFiles.Count -eq 0) {
    Write-Warning "No .iso files found in '$IsoDir'. The HTTP server will start but the directory listing will be empty."
}

# --- Display header ---
Write-Host ("=" * 44) -ForegroundColor Cyan
Write-Host "  vSphere Supervisor ISO File Server" -ForegroundColor Cyan
Write-Host ("=" * 44) -ForegroundColor Cyan
Write-Host ""
Write-Host "ISO Directory: $IsoDir"
Write-Host ""

# --- List available ISOs ---
if ($isoFiles.Count -gt 0) {
    Write-Host "Available ISO files:" -ForegroundColor Green
    foreach ($file in $isoFiles) {
        $sizeGb = $file.Length / 1GB
        Write-Host "  - $($file.Name) ($('{0:N2}' -f $sizeGb) GB)" -ForegroundColor Yellow
    }
    Write-Host ""
}

Write-Host "Server URL: http://localhost:$Port/" -ForegroundColor Green
Write-Host ""

# --- Discover non-loopback IPv4 addresses ---
$ipAddresses = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
        $_.PrefixOrigin -ne "LinkLocal" -and
        $_.InterfaceAlias -notmatch "Loopback|Tunnel|Bluetooth" -and
        $_.IPAddress -ne "127.0.0.1"
    }

if ($ipAddresses.Count -gt 0) {
    Write-Host "Local IP addresses for remote access:" -ForegroundColor Green
    foreach ($ip in $ipAddresses) {
        Write-Host "  http://$($ip.IPAddress):$Port/" -ForegroundColor White
    }
    Write-Host ""

    if ($isoFiles.Count -gt 0) {
        Write-Host "Example import_source_url usage:" -ForegroundColor Green
        foreach ($ip in $ipAddresses) {
            foreach ($file in $isoFiles) {
                Write-Host "  import_source_url = ""http://$($ip.IPAddress):$Port/$($file.Name)""" -ForegroundColor White
            }
        }
        Write-Host ""
    }
} else {
    Write-Warning "No suitable IPv4 addresses found for remote access. The server will only be available on localhost."
}

Write-Host "Starting HTTP server... Press Ctrl+C to stop." -ForegroundColor Cyan
Write-Host ("=" * 44) -ForegroundColor Cyan

# --- Start Python HTTP server ---
$previousLocation = Get-Location
try {
    Set-Location -Path $IsoDir
    python -m http.server $Port
}
finally {
    # Restore original working directory, even if the user presses Ctrl+C
    Set-Location -Path $previousLocation
}
