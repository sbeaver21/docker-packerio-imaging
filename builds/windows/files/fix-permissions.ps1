<#
.SYNOPSIS
    Fixes Windows file/folder ownership and permission warnings.
    Resolves: "Warning: this is a potential security risk because anyone who can access this object can take ownership of it."

.DESCRIPTION
    This script resolves the common Windows security warning that appears when files/folders
    have ownership set but lack proper ACL permissions. It will:
      1. Take ownership of the specified paths recursively
      2. Grant Full Control to the current user
      3. Grant Full Control to the Administrators group
      4. Reset inheritance to apply permissions to all children
      5. Force explicit permissions on all child objects

.PARAMETER Path
    One or more file/folder paths to fix. Supports wildcards.
    Defaults to the current working directory if not specified.

.PARAMETER Recursive
    Process all subdirectories and files recursively. Default: $true

.PARAMETER GrantUser
    The user/account to grant permissions to. Defaults to the current user.

.PARAMETER ResetInheritance
    Reset permission inheritance so the path inherits from its parent. Default: $true

.PARAMETER Force
    Skip confirmation prompts. Default: $false

.PARAMETER RemoveExplicitDeny
    Remove any explicit Deny ACE entries that may be blocking access. Default: $false

.EXAMPLE
    .\Fix-Permissions.ps1 -Path "C:\SomeFolder"

.EXAMPLE
    .\Fix-Permissions.ps1 -Path "C:\Folder1", "C:\Folder2" -Recursive $true -Force

.EXAMPLE
    .\Fix-Permissions.ps1  # Fix current directory

.NOTES
    Author: Script generated for automated Windows permission repair
    Requires: PowerShell 5.0+ (Run as Administrator recommended)
#>

param(
    [Parameter(Position = 0, ValueFromPipeline = $true)]
    [string[]]$Path = @("."),

    [Parameter()]
    [bool]$Recursive = $true,

    [Parameter()]
    [string]$GrantUser = "",

    [Parameter()]
    [bool]$ResetInheritance = $true,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$RemoveExplicitDeny
)

# Ensure script runs with elevation (Admin rights) when fixing system locations
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$targetingSystemPaths = $false

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

function Test-Administrator {
    if (-not $isAdmin) {
        Write-Log "WARNING: Not running as Administrator. Some operations may fail for system-protected files." "WARN"
        Write-Log "Consider re-running with 'Run as Administrator'." "WARN"
        Write-Host ""
    }
}

function Grant-Permission {
    param(
        [string]$ItemPath,
        [string]$Account,
        [string]$Rights = "FullControl",
        [bool]$IsRecursive = $true
    )

    $exists = Test-Path -LiteralPath $ItemPath
    if (-not $exists) {
        Write-Log "Path not found: $ItemPath" "ERROR"
        return $false
    }

    try {
        # Use icacls to grant permissions (more reliable for corner cases)
        $inheritanceFlags = if ($IsRecursive) { "/T" } else { "" }

        # Grant full control to the specified account
        $grantResult = icacls $ItemPath /grant ("${Account}:(OI)(CI)F") $inheritanceFlags 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "icacls grant failed for $ItemPath : $grantResult" "WARN"
            return $false
        }

        Write-Log "Granted $Rights to $Account on $ItemPath" "INFO"
        return $true
    }
    catch {
        Write-Log "Error granting permissions on $ItemPath : $_" "ERROR"
        return $false
    }
}

function Set-Owner {
    param(
        [string]$ItemPath,
        [bool]$IsRecursive = $true
    )

    $exists = Test-Path -LiteralPath $ItemPath
    if (-not $exists) {
        Write-Log "Path not found: $ItemPath" "ERROR"
        return $false
    }

    try {
        $recursiveFlag = if ($IsRecursive) { "/R" } else { "" }

        # Take ownership using takeown
        $takeownResult = takeown /F $ItemPath $recursiveFlag /D Y 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "takeown failed for $ItemPath : $takeownResult" "WARN"
            return $false
        }

        Write-Log "Took ownership of $ItemPath" "INFO"
        return $true
    }
    catch {
        Write-Log "Error taking ownership of $ItemPath : $_" "ERROR"
        return $false
    }
}

function Reset-AclInheritance {
    param(
        [string]$ItemPath,
        [bool]$IsRecursive = $true
    )

    $exists = Test-Path -LiteralPath $ItemPath
    if (-not $exists) {
        Write-Log "Path not found: $ItemPath" "ERROR"
        return $false
    }

    try {
        $recursiveFlag = if ($IsRecursive) { "/T" } else { "" }

        # Reset inheritance: remove explicit permissions and inherit from parent
        $icaclsResult = icacls $ItemPath /reset $recursiveFlag 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "icacls reset failed for $ItemPath : $icaclsResult" "WARN"
            return $false
        }

        Write-Log "Reset ACL inheritance on $ItemPath" "INFO"
        return $true
    }
    catch {
        Write-Log "Error resetting ACL on $ItemPath : $_" "ERROR"
        return $false
    }
}

function Remove-ExplicitDenyAcls {
    param(
        [string]$ItemPath,
        [bool]$IsRecursive = $true
    )

    $exists = Test-Path -LiteralPath $ItemPath
    if (-not $exists) {
        return
    }

    try {
        $recursiveFlag = if ($IsRecursive) { "/T" } else { "" }
        # Remove deny entries (this removes explicit deny entries from the ACL)
        $icaclsResult = icacls $ItemPath /remove:d "Everyone" $recursiveFlag 2>&1 | Out-Null
        $icaclsResult = icacls $ItemPath /remove:d "BUILTIN\Users" $recursiveFlag 2>&1 | Out-Null

        Write-Log "Removed explicit Deny ACEs on $ItemPath" "INFO"
        Write-Log "Results: $icaclsResult"
    }
    catch {
        Write-Log "Error removing deny ACLs on $ItemPath : $_" "WARN"
    }
}

function Repair-Path {
    param(
        [string]$TargetPath,
        [string]$ResolvedPath
    )

    Write-Host ""
    Write-Log "=== Processing: $ResolvedPath ===" "INFO"

    # Step 1: Take ownership
    $ownershipResult = Set-Owner -ItemPath $ResolvedPath -IsRecursive $Recursive
    if (-not $ownershipResult) {
        Write-Log "Failed to take ownership, attempting permission grant anyway..." "WARN"
    }

    # Step 2: Reset ACL inheritance (this clears corrupt inherited permissions)
    if ($ResetInheritance) {
        $resetResult = Reset-AclInheritance -ItemPath $ResolvedPath -IsRecursive $false
        if (-not $resetResult) {
            Write-Log "Failed to reset ACL inheritance." "WARN"
        }
    }

    # Step 3: Grant permissions to the target user
    $grantUser = if ([string]::IsNullOrWhiteSpace($GrantUser)) { "$env:USERDOMAIN\$env:USERNAME" } else { $GrantUser }

    $grantResult = Grant-Permission -ItemPath $ResolvedPath -Account $grantUser -IsRecursive $Recursive
    if (-not $grantResult) {
        Write-Log "Failed to grant permissions to $grantUser." "WARN"
    }

    # Step 4: Grant to Administrators group for safety
    $adminGrantResult = Grant-Permission -ItemPath $ResolvedPath -Account "BUILTIN\Administrators" -IsRecursive $Recursive
    if (-not $adminGrantResult) {
        Write-Log "Failed to grant permissions to Administrators." "WARN"
    }

    # Step 5: Optionally remove explicit Deny entries
    if ($RemoveExplicitDeny) {
        Remove-ExplicitDenyAcls -ItemPath $ResolvedPath -IsRecursive $Recursive
    }

    Write-Log "=== Completed: $ResolvedPath ===" "INFO"
}

# ---- Main Execution ----

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "   Windows Permission Fix Utility" -ForegroundColor Cyan
Write-Host "   Resolves ownership & permission warnings" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

Test-Administrator

foreach ($p in $Path) {
    # Resolve the path
    $resolved = Resolve-Path -LiteralPath $p -ErrorAction SilentlyContinue
    if (-not $resolved) {
        Write-Log "Cannot resolve path: $p. Skipping." "ERROR"
        continue
    }

    $resolvedPath = $resolved.Path

    # Check if targeting system paths
    if ($resolvedPath -match '^C:\\Windows' -or $resolvedPath -match '^C:\\Program Files' -or $resolvedPath -match '^C:\\Program Files \(x86\)') {
        $targetingSystemPaths = $true
    }

    # Check if Force is set or prompt user
    if (-not $Force) {
        $itemType = if ((Get-Item -LiteralPath $resolvedPath) -is [System.IO.DirectoryInfo]) { "folder" } else { "file" }
        $recursiveDesc = if ($Recursive) { " recursively" } else { "" }
        Write-Host "Recursive description returned: $recursiveDesc" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "About to fix permissions on the following:" -ForegroundColor Yellow
        Write-Host "  Path: $resolvedPath" -ForegroundColor Yellow
        Write-Host "  Type: $itemType" -ForegroundColor Yellow
        Write-Host "  Recursive: $Recursive" -ForegroundColor Yellow
        Write-Host ""

        if (-not $Force) {
            $confirm = Read-Host "Proceed with fixing permissions? (Y/N)"
            if ($confirm -notmatch '^[Yy]') {
                Write-Log "Skipped by user." "INFO"
                continue
            }
        }
    }

    Repair-Path -TargetPath $p -ResolvedPath $resolvedPath
}

Write-Host ""
Write-Log "Permission fix operation complete." "INFO"
Write-Host ""

if ($targetingSystemPaths -and -not $isAdmin) {
    Write-Log "NOTE: Some system paths may have been skipped due to lack of Administrator privileges." "WARN"
    Write-Log "      Re-run this script as Administrator to fix system paths." "WARN"
    Write-Host ""
}

Write-Host "If the warning persists, verify the file/folder is not:" -ForegroundColor Yellow
Write-Host "  - Encrypted with EFS (check Properties -> Advanced Attributes)" -ForegroundColor Yellow
Write-Host "  - On a network share where the server has different permissions" -ForegroundColor Yellow
Write-Host "  - Protected by Windows System Protection (e.g., C:\Windows\System32)" -ForegroundColor Yellow
Write-Host "  - Corrupted (try chkdsk for disk issues)" -ForegroundColor Yellow
Write-Host ""
Write-Host "To fix common file/folder issues also try:" -ForegroundColor Cyan
Write-Host '  icacls <path> /reset /T       (Reset all ACLs)' -ForegroundColor Cyan
Write-Host '  takeown /F <path> /R /D Y    (Take ownership recursively)' -ForegroundColor Cyan