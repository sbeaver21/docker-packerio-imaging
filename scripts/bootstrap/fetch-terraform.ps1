<#
.SYNOPSIS
    Download the pinned Terraform release and put terraform.exe in tools\terraform.

.DESCRIPTION
    Terraform is not committed: it is a ~30 MB platform-specific binary, and a
    binary in git is either stale or enormous. Instead this fetches the exact
    release recorded in terraform.lock, verifies its SHA-256 against the digest
    pinned there, and expands it into tools\terraform\ - the directory the
    documented commands run from.

    A digest mismatch stops the fetch. That is the whole point of the lock: an
    image built with a different Terraform than the one recorded here is not
    reproducible, and there is no other place that difference would show up.

.PARAMETER Version
    Override the version from the lock. The digest still has to match a line in
    the lock, so an override only works for a version already pinned there.

.PARAMETER Destination
    Where to install. Defaults to tools\terraform at the repository root.

.EXAMPLE
    .\scripts\bootstrap\fetch-terraform.ps1
    .\scripts\bootstrap\fetch-terraform.ps1 -Destination C:\tools\terraform
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$Destination
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Invoke-WebRequest draws a progress bar per 8 KB chunk, which turns a 30 MB
# download into thousands of lines of console output in a CI log.
$ProgressPreference = 'SilentlyContinue'

function Get-Sha256Hex {
    <#
      SHA-256 of a file, via .NET rather than Get-FileHash. That cmdlet lives in
      an optional module, and a build host whose module path is stripped then
      fails at the one step that exists to verify the download.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $bytes = $algorithm.ComputeHash($stream)
    }
    finally {
        $stream.Dispose()
        $algorithm.Dispose()
    }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$LockPath = Join-Path $PSScriptRoot 'terraform.lock'

if (-not (Test-Path -LiteralPath $LockPath)) {
    throw "no lock file at $LockPath"
}

# The lock is deliberately a flat, greppable two-column file: version on its own
# line, then one digest per artifact. Parsing it with a regex keeps this script
# readable and lets the shell version read the same file.
$lines = Get-Content -LiteralPath $LockPath
$pinnedVersion = ''
$digests = @{}

foreach ($line in $lines) {
    $trimmed = $line.Trim()
    if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }

    if ($trimmed -match '^version\s+(\S+)$') {
        $pinnedVersion = $Matches[1]
        continue
    }
    if ($trimmed -match '^(\S+)\s+([0-9a-fA-F]{64})$') {
        $digests[$Matches[1]] = $Matches[2].ToLowerInvariant()
        continue
    }
    throw "unrecognised line in terraform.lock: $trimmed"
}

$wanted = if ($Version) { $Version } else { $pinnedVersion }
if (-not $wanted) { throw "terraform.lock records no version" }

# Windows is the only platform this script can install on; the check exists so a
# mistake reads as a mistake rather than a 404 from releases.hashicorp.com.
$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'amd64' }
    'ARM64' { 'arm64' }
    default { throw "unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
}
$platform = "windows_$architecture"

if (-not $digests.ContainsKey($platform)) {
    throw "terraform.lock has no digest for $platform"
}
$expected = $digests[$platform]

$fileName = "terraform_${wanted}_${platform}.zip"
$url = "https://releases.hashicorp.com/terraform/$wanted/$fileName"

if (-not $Destination) {
    $Destination = Join-Path $RepositoryRoot 'tools\terraform'
}
$Destination = [System.IO.Path]::GetFullPath($Destination)
$target = Join-Path $Destination 'terraform.exe'

# Already installed at the pinned version: nothing to do, and no network call.
if (Test-Path -LiteralPath $target) {
    $installed = (& $target version 2>$null | Select-Object -First 1)
    if ($installed -match "Terraform v$([regex]::Escape($wanted))$") {
        Write-Output "terraform $wanted already present at $target"
        return
    }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("terraform-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$zip = Join-Path $work $fileName

try {
    Write-Output "downloading $fileName"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

    $actual = Get-Sha256Hex -Path $zip
    if ($actual -ne $expected) {
        throw @"
digest mismatch for $fileName
  expected $expected
  actual   $actual
Refusing to install. Update terraform.lock only after checking the digest
against https://releases.hashicorp.com/terraform/$wanted/terraform_${wanted}_SHA256SUMS
"@
    }

    # Expand-Archive is from the same optional module; this API is always there.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $work)

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $work 'terraform.exe') -Destination $target -Force

    $reported = (& $target version | Select-Object -First 1)
    Write-Output "installed $Destination"
    Write-Output "  $reported"
    Write-Output "  sha256 $actual"
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
