<#
.SYNOPSIS
  READ-ONLY CHECK SCRIPT: Verifies security hardening settings without making changes.
.NOTES
  This script must be run with Administrator privileges and requires a reboot after hardening.
#>

# --- Configuration ---
$LogPath = "C:\Temp"

# --- Logging Functions ---
if (-not (Test-Path $LogPath)) {
    try {
        New-Item -Path $LogPath -ItemType Directory -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "ERROR: Could not create log directory '$LogPath'." -ForegroundColor Red
        Exit 1
    }
}
$LogFile = "$LogPath\VulnFixCheckLog-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

function Log {
    param([string]$Message, [System.ConsoleColor]$ForegroundColor = 'Gray')
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logMessage = "$timestamp - $Message"
    Write-Host $logMessage -ForegroundColor $ForegroundColor
    $logMessage | Out-File -FilePath $LogFile -Append
}

# --- Check Function ---
function Check-Setting {
    param (
        [string]$Description,
        [ScriptBlock]$GetCurrentValueScript,
        [ScriptBlock]$GetExpectedValueScript
    )
    $currentValue = $null
    $pass = $false
    try {
        $currentValue = & $GetCurrentValueScript
        $expectedValue = & $GetExpectedValueScript
        if (($currentValue -is [System.Collections.IEnumerable]) -and ($expectedValue -is [System.Collections.IEnumerable]) -and -not ($currentValue -is [string]) -and -not ($expectedValue -is [string])) {
            $sortedCurrent = ($currentValue | Sort-Object) -join ','
            $sortedExpected = ($expectedValue | Sort-Object) -join ','
            $pass = ($sortedCurrent -eq $sortedExpected)
        } else {
            $pass = ($currentValue -eq $expectedValue)
        }
        if ($pass) {
            Log "PASS: $Description" -ForegroundColor Green
        } else {
            Log "FAIL: $Description" -ForegroundColor Red
            Log "         Current Value: '$(($currentValue | Out-String | ForEach-Object { $_.Trim() }))'" -ForegroundColor Red
            Log "         Expected Value: '$(($expectedValue | Out-String | ForEach-Object { $_.Trim() }))'" -ForegroundColor Red
        }
    } catch {
        Log "ERROR checking '$Description': $($_.Exception.Message)" -ForegroundColor Yellow
        $pass = $false
    }
    return $pass
}

# --- Helper Function ---
function Test-ProtocolDisabled {
    param([string]$ProtocolName)
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$ProtocolName\Server"
    $props = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
    return (($props.Enabled -eq 0) -or ($props.DisabledByDefault -eq 1))
}

# --- Main Script Logic ---
Log "===== Starting Vulnerability Fix Check Script ====="
Log "Note: A reboot is required after hardening for these checks to be accurate."
$overallPass = $true

# === Check 1: Account & Lockout Policies ===
Log "Checking Account Policies..."
$netAccounts = net accounts
$checkResult = Check-Setting "Minimum Password Length is 12" { ($netAccounts | Select-String "Minimum password length").ToString().Split(':')[1].Trim() } { 12 }
$overallPass = $overallPass -and $checkResult
$checkResult = Check-Setting "Account Lockout Threshold is 3" { ($netAccounts | Select-String "Lockout threshold").ToString().Split(':')[1].Trim() } { 3 }
$overallPass = $overallPass -and $checkResult
$checkResult = Check-Setting "Account Lockout Duration (minutes) is 1440" { ($netAccounts | Select-String "Lockout duration").ToString().Split(':')[1].Trim() } { 1440 }
$overallPass = $overallPass -and $checkResult
$checkResult = Check-Setting "Account Lockout Window (minutes) is 15" { ($netAccounts | Select-String "Lockout observation window").ToString().Split(':')[1].Trim() } { 15 }
$overallPass = $overallPass -and $checkResult

# === Check 2: Lsa LMCompatibilityLevel ===
Log "Checking LSA Configuration..."
$checkResult = Check-Setting "Lsa LMCompatibilityLevel is set to 5" { (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa").LMCompatibilityLevel } { 5 }
$overallPass = $overallPass -and $checkResult

# === Check 3: CVE-2013-3900 (Cert Padding Check) ===
Log "Checking Cryptography Configuration..."
$checkResult = Check-Setting "CVE-2013-3900 (Cert Padding Check) is enabled" { (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Cryptography\Wintrust\Config" -ErrorAction SilentlyContinue).EnableCertPaddingCheck } { 1 }
$overallPass = $overallPass -and $checkResult

# === Check 4: SMB Settings ===
Log "Checking SMB Server Configuration..."
$checkResult = Check-Setting "SMBv1 is disabled" { (Get-SmbServerConfiguration -ErrorAction SilentlyContinue).EnableSMB1Protocol } { $false }
$overallPass = $overallPass -and $checkResult
$checkResult = Check-Setting "SMB signing is required" { (Get-SmbServerConfiguration -ErrorAction SilentlyContinue).RequireSecuritySignature } { $true }
$overallPass = $overallPass -and $checkResult

# === Check 5: IIS HTTP OPTIONS Method ===
Log "Checking IIS Configuration..."
Import-Module ServerManager -ErrorAction SilentlyContinue
if (Get-Module -Name ServerManager -ErrorAction SilentlyContinue) {
    if ((Get-WindowsFeature -Name Web-Mgmt-Console).Installed) {
        $checkResult = Check-Setting "HTTP OPTIONS verb is disabled in IIS" {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            (Get-WebConfiguration -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/security/requestFiltering/verbs/add[@verb='OPTIONS']").allowed
        } { $false }
        $overallPass = $overallPass -and $checkResult
    } else {
        Log "IIS Management Console not found. Skipping HTTP OPTIONS check." -ForegroundColor Cyan
    }
} else {
    Log "ServerManager module not available. Skipping IIS role check." -ForegroundColor Cyan
}

# === Check 6: SCHANNEL Protocol Disablement ===
Log "Checking SCHANNEL Protocols..."
$protocolsToDisable = @("SSL 2.0", "SSL 3.0", "TLS 1.0", "TLS 1.1")
foreach ($protocol in $protocolsToDisable) {
    $checkResult = Check-Setting "$protocol is disabled" { Test-ProtocolDisabled -ProtocolName $protocol } { $true }
    $overallPass = $overallPass -and $checkResult
}

# === Check 7: Secure Cipher Suite List ===
Log "Checking SCHANNEL Cipher Suites..."
$expectedSecureCiphers = @("TLS_AES_256_GCM_SHA384", "TLS_AES_128_GCM_SHA256", "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384", "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256", "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384", "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256", "TLS_DHE_RSA_WITH_AES_256_GCM_SHA384", "TLS_DHE_RSA_WITH_AES_128_GCM_SHA256", "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384", "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256", "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384", "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256")
$currentCiphers = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Cryptography\Configuration\Local\SSL\00010002" -ErrorAction SilentlyContinue).Functions
if ($currentCiphers) {
    Log "--- Currently Configured Cipher Suites ---" -ForegroundColor Cyan
    foreach ($cipher in $currentCiphers) { Log "   $cipher" -ForegroundColor Cyan }
    Log "------------------------------------------" -ForegroundColor Cyan
}
$checkResult = Check-Setting "Secure cipher suite list is correctly applied" { $currentCiphers } { $expectedSecureCiphers }
$overallPass = $overallPass -and $checkResult

# === Check 8: Diffie-Hellman Key Length ===
Log "Checking SCHANNEL Key Exchange Algorithms..."
$checkResult = Check-Setting "Diffie-Hellman minimum server key length is 2048 bits" { (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\KeyExchangeAlgorithms\Diffie-Hellman" -ErrorAction SilentlyContinue).ServerMinKeyBitLength } { 2048 }
$overallPass = $overallPass -and $checkResult

# --- Final Summary ---
Log ""
Log "===== Script Check Complete ====="
if ($overallPass) {
    Log "Overall Status: ALL HARDENING CHEKS PASSED!" -ForegroundColor Green
} else {
    Log "Overall Status: SOME HARDENING CHECKS FAILED. Review '$LogFile' for details." -ForegroundColor Red
}