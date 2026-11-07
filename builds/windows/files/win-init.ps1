#Requires -Version 5.1
<#
    .SYNOPSIS
        Applies the base Windows customizations to a freshly installed Windows Server build.

    .DESCRIPTION
        Runs at first logon from the build media, immediately after windows-init.ps1:

            powershell.exe -File F:\win-init.ps1

        Every customization runs as an independent step. A step that fails is logged
        and the remaining steps still run, so one broken optional feature (a network
        driver without an 'Rx Ring' property, a capability that needs Windows Update)
        does not abandon the rest of the build. Unless -FailOnError is given the
        script always exits 0, which is what the unattend file expects.

        Everything is written to C:\Windows\Temp\win-init.log. First logon commands
        run without a usable console, so that log is the only record of what happened
        during the image build.

        The OpenSSH server is started by this script, which is what allows Packer's
        SSH communicator to connect and run the provisioners that consume C:\CD and
        C:\Temp. Keep the staging and OpenSSH steps ahead of everything else.

    .PARAMETER SourceRoot
        Root of the build media that holds the stage folders (the floppy Packer
        mounts as F:).

    .PARAMETER StageFolder
        Folders copied from the build media to the system drive.

    .PARAMETER DestinationRoot
        Drive the stage folders are copied to.

    .PARAMETER TimeZone
        Windows time zone ID applied at the end of the run.

    .PARAMETER PasswordNeverExpiresUsers
        Local accounts whose password must never expire. The default (empty) applies
        to every enabled local account, which is what keeps the build account Packer
        connects with from hitting the 42 day default password age.

    .PARAMETER DisableNetworkLevelAuthentication
        Disables NLA for Remote Desktop, which is what this script has always done so
        that legacy RDP clients can connect. Pass $false to keep NLA enabled.

    .PARAMETER PowerShellVersion
        PowerShell 7 version to install, or 'latest'.

    .PARAMETER CompletionMarker
        Written when the script finishes. Packer provisioners that depend on C:\CD or
        C:\Temp can wait for this file instead of racing the copy.

    .PARAMETER FailOnError
        Exit with code 1 when a step failed. Off by default so a failed optional step
        never blocks the unattend file's first logon command.

    .EXAMPLE
        powershell.exe -ExecutionPolicy Bypass -File F:\win-init.ps1

    .EXAMPLE
        # Fail loudly on any error, pin PowerShell 7, and leave NLA enabled.
        powershell.exe -ExecutionPolicy Bypass -File F:\win-init.ps1 -FailOnError -PowerShellVersion 7.4.6 -DisableNetworkLevelAuthentication:$false

    .NOTES
        Author: Stephen Beaver
#>
[CmdletBinding()]
param(
    [string]   $SourceRoot                        = 'F:\',
    [string[]] $StageFolder                       = @('CD', 'Temp'),
    [string]   $DestinationRoot                   = 'C:\',
    [string]   $TimeZone                          = 'Eastern Standard Time',
    [string[]] $PasswordNeverExpiresUsers         = @(),
    [bool]     $DisableNetworkLevelAuthentication = $true,
    [string]   $PowerShellVersion                 = 'latest',
    [string]   $CompletionMarker                  = 'C:\Windows\Temp\win-init.complete',
    [switch]   $FailOnError
)

# ---------------------------------------------------------------------------
# Script state
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
# Invoke-WebRequest spends most of its time drawing a progress bar.
$ProgressPreference    = 'SilentlyContinue'
# Windows PowerShell 5.1 does not always negotiate TLS 1.2 for the downloads below.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$LogFile         = Join-Path $env:SystemRoot 'Temp\win-init.log'
$LogFileEnabled  = $true
$Failures        = New-Object 'System.Collections.Generic.List[string]'
$CapabilityCache = $null
$ScriptStartTime = Get-Date

# Native tools are called by full path so that a modified PATH on the build media
# cannot change what actually runs.
$RobocopyExe          = Join-Path $env:SystemRoot 'System32\Robocopy.exe'
$PowerCfgExe          = Join-Path $env:SystemRoot 'System32\powercfg.exe'
$WindowsPowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Registry locations and firewall groups used below.
$Ipv6RegistryPath           = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
$Ipv6DisabledComponents     = 0xFF
$TerminalServerPath         = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$TerminalServerRdpTcpPath   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
$RemoteDesktopFirewallGroup = '@FirewallAPI.dll,-28752'

# The OpenSSH Server capability owns the inbound rule below. It is addressed by name, not
# by display name: the name is what the firewall stores and it is the same on every
# language of Windows, while the display name is translated - on the English image it is
# "OpenSSH SSH Server (sshd)", not the "OpenSSH Server (sshd)" an earlier version of this
# script tested for, so that test never matched the rule Microsoft had already installed.
$SshdServiceName            = 'sshd'
$SshdFirewallRuleName       = 'OpenSSH-Server-In-TCP'
$SshdPort                   = 22

# Only used when the capability shipped no rule at all. The name belongs to this script,
# so it can never collide with a rule Windows manages.
$SshdFallbackRuleName       = 'Packer-OpenSSH-In-TCP'
$SshdFallbackDisplay        = 'OpenSSH Server (sshd)'
$SshdFallbackDescription    = 'Created by win-init.ps1 for the Packer build.'

# Advanced properties the vmxnet3 driver is expected to expose. A driver that does
# not offer one of them is reported and skipped instead of failing the step.
$NetworkAdapterSettings = @(
    @{ DisplayName = 'Small Rx Buffers'; DisplayValue = '8192' },
    @{ DisplayName = 'Rx Ring #1 Size';  DisplayValue = '4096' }
)

# A terminating error that escapes every step still has to leave a usable record.
trap {
    Write-Log ('Unhandled error: {0}' -f $_.Exception.Message) -Level 'ERROR'
    if ($_.ScriptStackTrace) {
        Write-Log ('    at {0}' -f $_.ScriptStackTrace) -Level 'ERROR'
    }
    Set-Content -LiteralPath $CompletionMarker -Value 'failed' -Encoding UTF8 -Force -ErrorAction SilentlyContinue
    exit 1
}
# ---------------------------------------------------------------------------
# Reusable helpers
# ---------------------------------------------------------------------------

function Write-Log {
    <#
        .SYNOPSIS
            Writes a timestamped line to the console and to the build log file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string] $Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level = 'INFO'
    )

    $entry = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    switch ($Level) {
        'WARN'  { Write-Host $entry -ForegroundColor Yellow }
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        default { Write-Host $entry }
    }

    if ($LogFileEnabled) {
        # Disable file logging and carry on: losing the log must never fail the build.
        try {
            Add-Content -LiteralPath $LogFile -Value $entry -Encoding UTF8 -ErrorAction Stop
        } catch {
            $script:LogFileEnabled = $false
        }
    }
}

function Invoke-Step {
    <#
        .SYNOPSIS
            Runs one unit of work, logs how long it took and remembers its failure.

        .DESCRIPTION
            The step gets its own error scope so a failure is contained and reported
            with the remaining error handling intact. Failures are collected rather
            than thrown so that later steps still run; -FailOnError rethrows instead.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Name,

        [Parameter(Mandatory, Position = 1)]
        [scriptblock] $Script
    )

    Write-Log ('==> {0}' -f $Name)
    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        & $Script
        $timer.Stop()
        Write-Log ('    completed in {0:N1}s' -f $timer.Elapsed.TotalSeconds)
    } catch {
        $timer.Stop()
        Write-Log ('    FAILED after {0:N1}s: {1}' -f $timer.Elapsed.TotalSeconds, $_.Exception.Message) -Level 'ERROR'
        if ($_.ScriptStackTrace) {
            Write-Log ('    {0}' -f ($_.ScriptStackTrace -split '\r?\n')[0]) -Level 'ERROR'
        }
        $Failures.Add(('{0}: {1}' -f $Name, $_.Exception.Message))
        if ($FailOnError) { throw }
    }
}

function Invoke-Process {
    <#
        .SYNOPSIS
            Runs an external program, waits for it and fails on an unexpected exit code.

        .DESCRIPTION
            Start-Process joins -ArgumentList with spaces and does not quote anything,
            so arguments containing whitespace are quoted here or the target sees extra
            arguments. The output of the process is redirected to temporary files: the
            last -LogTailLines lines are copied into the build log, which keeps an
            installer's own diagnostics without flooding the log.

        .OUTPUTS
            The process exit code.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $FilePath,

        [string[]] $ArgumentList = @(),

        [int[]] $SuccessExitCode = @(0),

        [string] $Description = $FilePath,

        [int] $LogTailLines = 0
    )

    # @() keeps this a real array even for a single argument; a plain string bound to
    # Start-Process would leave a spaced argument unquoted.
    $quotedArguments = @(foreach ($argument in $ArgumentList) {
        if ($argument -match '\s' -and -not $argument.StartsWith('"')) { '"{0}"' -f $argument } else { $argument }
    })

    Write-Log ('    > {0} {1}' -f (Split-Path -Leaf $FilePath), ($quotedArguments -join ' '))

    $standardOutput = Join-Path ([System.IO.Path]::GetTempPath()) ('{0}.out.log' -f [guid]::NewGuid().ToString('N'))
    $standardError  = Join-Path ([System.IO.Path]::GetTempPath()) ('{0}.err.log' -f [guid]::NewGuid().ToString('N'))

    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $quotedArguments -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $standardOutput -RedirectStandardError $standardError

        if ($LogTailLines -gt 0) {
            foreach ($line in @(Get-Content -LiteralPath $standardOutput -Tail $LogTailLines -ErrorAction SilentlyContinue)) {
                if ($line.Trim()) { Write-Log ('      {0}' -f $line.TrimEnd()) }
            }
        }

        if ($SuccessExitCode -notcontains $process.ExitCode) {
            foreach ($line in @(Get-Content -LiteralPath $standardError -Tail 15 -ErrorAction SilentlyContinue)) {
                if ($line.Trim()) { Write-Log ('      {0}' -f $line.TrimEnd()) -Level 'ERROR' }
            }
            throw ('{0} failed with exit code {1} ({2} {3}).' -f $Description, $process.ExitCode, (Split-Path -Leaf $FilePath), ($quotedArguments -join ' '))
        }

        return $process.ExitCode
    } finally {
        Remove-Item -LiteralPath $standardOutput, $standardError -Force -ErrorAction SilentlyContinue
    }
}

function Get-OnlineWindowsCapability {
    <#
        .SYNOPSIS
            Returns one online Windows capability, caching the full enumeration.

        .DESCRIPTION
            Get-WindowsCapability -Online takes tens of seconds because it enumerates
            every optional feature, and the original script called it four times.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $NamePattern
    )

    if (-not $CapabilityCache) {
        $script:CapabilityCache = Get-WindowsCapability -Online
    }

    return $script:CapabilityCache | Where-Object Name -like $NamePattern | Select-Object -First 1
}

function Install-WindowsCapabilityAndVerify {
    <#
        .SYNOPSIS
            Installs an optional Windows capability if it is missing, then verifies it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $NamePattern,

        [Parameter(Mandatory, Position = 1)]
        [string] $CapabilityName,

        [Parameter(Mandatory, Position = 2)]
        [string] $FriendlyName
    )

    $capability = Get-OnlineWindowsCapability -NamePattern $NamePattern
    if ($capability -and $capability.State -eq 'Installed') {
        Write-Log ('    {0} is already installed.' -f $FriendlyName)
        return
    }

    Write-Log ('    Installing {0} ({1})...' -f $FriendlyName, $CapabilityName)
    $result = Add-WindowsCapability -Online -Name $CapabilityName
    if ($result.RestartNeeded) {
        Write-Log ('    {0} reports that a restart is required.' -f $FriendlyName) -Level 'WARN'
    }

    # Never trust the installer's own success message; ask Windows instead.
    $script:CapabilityCache = $null
    $capability = Get-OnlineWindowsCapability -NamePattern $NamePattern

    if (-not $capability) {
        throw ('{0} is not offered by this image (no capability matches "{1}").' -f $FriendlyName, $NamePattern)
    }
    if ($capability.State -ne 'Installed') {
        throw ('{0} could not be installed; its state is "{1}". Windows Update or a Features on Demand source must be reachable.' -f $FriendlyName, $capability.State)
    }

    Write-Log ('    {0} installed.' -f $FriendlyName)
}

function Get-PowerSchemeGuid {
    <#
        .SYNOPSIS
            Returns the GUID of a power scheme, or of the active scheme.

        .DESCRIPTION
            powercfg is the only source for this information, but its output is
            translated and its column widths change between releases, so the GUID is
            read with a regular expression. The original script used .split()[3],
            which silently produced the wrong token as soon as either changed.

        .PARAMETER NamePattern
            Regular expression matched against the scheme name, for example
            'High performance'. Ignored when -Active is used.

        .PARAMETER Active
            Return the GUID of the active scheme instead of searching by name.
    #>
    [CmdletBinding()]
    param(
        [string] $NamePattern,

        [switch] $Active
    )

    # Two literal calls rather than splatting an argument array: in Windows
    # PowerShell 5.1 an array of one element produced by an if statement collapses to
    # a plain string, and splatting a string passes the target command unusable
    # arguments ("Invalid Parameters -- try /? for help").
    if ($Active) {
        $parameter = '-getactivescheme'
        $output    = & $PowerCfgExe -getactivescheme
    } else {
        $parameter = '-list'
        $output    = & $PowerCfgExe -list
    }

    if ($LASTEXITCODE -ne 0) {
        throw ('powercfg {0} failed with exit code {1}.' -f $parameter, $LASTEXITCODE)
    }

    $pattern = '^\s*Power Scheme GUID:\s*([0-9a-fA-F-]{36})\s*(?:\((.*?)\))?'
    foreach ($line in @($output)) {
        $match = [regex]::Match([string] $line, $pattern)
        if (-not $match.Success) { continue }
        if ($Active -or -not $NamePattern) { return $match.Groups[1].Value }
        if ($match.Groups[2].Success -and [regex]::IsMatch($match.Groups[2].Value, $NamePattern)) {
            return $match.Groups[1].Value
        }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

# Drop the log of any earlier run so that a log always belongs to one build.
Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue

Write-Log '========================================================================'
Write-Log ('Windows initialization started on {0} at {1}' -f $env:COMPUTERNAME, $ScriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))
Write-Log ('    Windows PowerShell : {0}' -f $PSVersionTable.PSVersion)
Write-Log ('    Build media        : {0}' -f $SourceRoot)
Write-Log ('    Destination        : {0}' -f $DestinationRoot)
Write-Log ('    Log file           : {0}' -f $LogFile)

# --- Network -------------------------------------------------------------

Invoke-Step -Name 'Disable the IPv6 components' -Script {
    # DisabledComponents = 0xFF disables every IPv6 component except the IPv6
    # loopback interface; 0x20 would only prefer IPv4 over IPv6. The value is read
    # at boot, so it takes effect after the next restart.
    New-ItemProperty -LiteralPath $Ipv6RegistryPath -Name 'DisabledComponents' -PropertyType 'DWord' `
        -Value $Ipv6DisabledComponents -Force | Out-Null

    Write-Log ('    {0}\DisabledComponents = 0x{1:X2}' -f $Ipv6RegistryPath, $Ipv6DisabledComponents)
}

# --- Build media staging -------------------------------------------------
# Runs before OpenSSH so that C:\CD and C:\Temp are complete by the time the
# Packer provisioners that consume them can connect.

foreach ($folder in $StageFolder) {
    $sourceFolder      = Join-Path $SourceRoot $folder
    $destinationFolder = Join-Path $DestinationRoot $folder

    Invoke-Step -Name ('Stage {0} to {1}' -f $sourceFolder, $destinationFolder) -Script {
        if (-not (Test-Path -LiteralPath $sourceFolder -PathType Container)) {
            throw ('Build media folder "{0}" does not exist.' -f $sourceFolder)
        }

        if (-not (Test-Path -LiteralPath $destinationFolder -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $destinationFolder -Force
            Write-Log ('    created {0}' -f $destinationFolder)
        }

        # /E         copy subdirectories, including empty ones
        # /COPY:DAT  copy data, attributes and timestamps but not the ACLs, so the
        #            files keep the permissions they inherit from the destination
        # /A-:R      drop the read-only attribute; without it every read-only file on
        #            the media arrives read-only and later provisioners cannot modify
        #            it (the original script cleared this afterwards, but only for the
        #            top level of the folder, so nested files stayed read-only)
        # /R:2 /W:2  two retries two seconds apart; the one million retry default
        #            turns a single locked file into a hung build
        # /XJ        skip junctions so a link on the media cannot loop the copy
        # /NP /NDL /NFL  summary output only, which is what ends up in the log
        Invoke-Process -FilePath $RobocopyExe `
            -ArgumentList @($sourceFolder, $destinationFolder, '/E', '/COPY:DAT', '/A-:R', '/R:2', '/W:2', '/XJ', '/NP', '/NDL', '/NFL') `
            -SuccessExitCode @(0, 1, 2, 3) `
            -LogTailLines 15 `
            -Description ('robocopy {0} {1}' -f $sourceFolder, $destinationFolder)
    }
}

Invoke-Step -Name 'Hide the CD folder' -Script {
    # -bor keeps the attributes the folder already has instead of replacing them.
    $cdFolder = Join-Path $DestinationRoot 'CD'
    $item     = Get-Item -LiteralPath $cdFolder -Force
    $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden

    Write-Log ('    {0} attributes: {1}' -f $cdFolder, (Get-Item -LiteralPath $cdFolder -Force).Attributes)
}

# --- OpenSSH -------------------------------------------------------------
# Packer connects over SSH, so the server is started here, before the long
# installs, so that the build does not wait on them to begin provisioning.

Invoke-Step -Name 'Install the OpenSSH client and server capabilities' -Script {
    Install-WindowsCapabilityAndVerify -NamePattern 'OpenSSH.Client*' -CapabilityName 'OpenSSH.Client~~~~0.0.1.0' -FriendlyName 'OpenSSH Client'
    Install-WindowsCapabilityAndVerify -NamePattern 'OpenSSH.Server*' -CapabilityName 'OpenSSH.Server~~~~0.0.1.0' -FriendlyName 'OpenSSH Server'
}

Invoke-Step -Name 'Start the OpenSSH server' -Script {
    $service = Get-Service -Name $SshdServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        throw ('The {0} service does not exist, so the OpenSSH Server capability did not install.' -f $SshdServiceName)
    }

    Set-Service -Name $SshdServiceName -StartupType 'Automatic'
    if ($service.Status -ne 'Running') {
        Start-Service -Name $SshdServiceName
    }

    # The capability ships the inbound rule below, so it is enabled rather than replaced.
    # The earlier version of this step looked for the display name "OpenSSH Server (sshd)",
    # which Windows does not use, so the lookup always came up empty and the step went on to
    # create a rule under the name Windows already owned. Windows reports creating a rule
    # under a name that is taken as "Cannot create a file when that file already exists",
    # and that is what failed this step in the build log.
    $ruleName = $SshdFirewallRuleName
    $rule     = Get-NetFirewallRule -Name $SshdFirewallRuleName -ErrorAction SilentlyContinue

    if ($rule) {
        if ($rule.Enabled -eq 'True') {
            Write-Log ('    the firewall rule the capability installed is already enabled ({0}).' -f $SshdFirewallRuleName)
        } else {
            Enable-NetFirewallRule -Name $SshdFirewallRuleName
            Write-Log ('    enabled the firewall rule the capability installed ({0}).' -f $SshdFirewallRuleName)
        }
    } else {
        # No rule was shipped, so this script makes its own, under a name it owns: a rule
        # created with the capability's name either fails or takes over a rule Windows
        # manages. A leftover of ours is removed first, so the step stays repeatable.
        $ruleName = $SshdFallbackRuleName
        if (Get-NetFirewallRule -Name $SshdFallbackRuleName -ErrorAction SilentlyContinue) {
            Remove-NetFirewallRule -Name $SshdFallbackRuleName
        }

        $null = New-NetFirewallRule -Name $SshdFallbackRuleName -DisplayName $SshdFallbackDisplay `
            -Description $SshdFallbackDescription -Enabled True -Direction Inbound -Protocol TCP `
            -Action Allow -LocalPort $SshdPort -Profile Any

        Write-Log ('    the capability shipped no rule, so {0} was created.' -f $SshdFallbackRuleName)
    }

    # Never trust the configuration; ask Windows whether the rule SSH depends on is usable.
    $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction Stop
    if ($rule.Enabled -ne 'True') {
        throw ('{0} is not enabled, so nothing allows the sshd listener Packer connects to.' -f $ruleName)
    }

    $ports = @(($rule | Get-NetFirewallPortFilter -ErrorAction Stop).LocalPort)
    if ($ports -notcontains [string] $SshdPort -and $ports -notcontains 'Any') {
        throw ('{0} does not allow TCP {1}; it allows {2}.' -f $ruleName, $SshdPort, ($ports -join ', '))
    }
    Write-Log ('    {0}: inbound TCP {1}, profile {2}.' -f $ruleName, ($ports -join ', '), $rule.Profile)

    # A rule that does not cover the profile the build is on leaves the listener blocked, and
    # Packer reports that as a communicator timeout rather than as a failed step, so it is
    # said out loud here. The rule is not widened: it belongs to Windows.
    $profileNames = @{ 'DomainAuthenticated' = 'Domain'; 'Private' = 'Private'; 'Public' = 'Public' }
    foreach ($connection in @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
        $profileName = $profileNames[[string] $connection.NetworkCategory]
        if (-not $profileName) { continue }
        if ($rule.Profile -ne 'Any' -and $rule.Profile -notlike ('*{0}*' -f $profileName)) {
            Write-Log ('    {0} does not cover the {1} profile of {2}, so the firewall may still block SSH.' -f $ruleName, $profileName, $connection.InterfaceAlias) -Level 'WARN'
        }
    }

    $sshd = Get-Service -Name $SshdServiceName
    Write-Log ('    sshd is {0} with start type {1}.' -f $sshd.Status, $sshd.StartType)
}

# --- Accounts ------------------------------------------------------------

Invoke-Step -Name 'Disable password expiration for the local accounts' -Script {
    $candidates = if ($PasswordNeverExpiresUsers.Count -gt 0) {
        Get-LocalUser | Where-Object { $PasswordNeverExpiresUsers -contains $_.Name }
    } else {
        # Default: every enabled local account, which includes the account Packer
        # connects with. A standalone server expires passwords after 42 days by
        # default, which would break later builds that sign in as that account.
        Get-LocalUser | Where-Object Enabled -eq $true
    }

    if (-not $candidates) {
        Write-Log '    No local accounts matched; nothing to change.' -Level 'WARN'
        return
    }

    $updated = 0
    foreach ($user in $candidates) {
        if ($user.PasswordNeverExpires) {
            Write-Log ('    {0}: password already never expires.' -f $user.Name)
            continue
        }

        Set-LocalUser -Name $user.Name -PasswordNeverExpires $true
        Write-Log ('    {0}: password expiration disabled.' -f $user.Name)
        $updated++
    }

    Write-Log ('    {0} account(s) updated.' -f $updated)
}

# --- Power, desktop and network tuning -----------------------------------

Invoke-Step -Name 'Activate the High Performance power plan' -Script {
    $highPerformance = Get-PowerSchemeGuid -NamePattern 'High performance'
    if (-not $highPerformance) {
        # SCHEME_MIN is the documented powercfg alias for High performance.
        Write-Log '    No "High performance" scheme was listed; falling back to the SCHEME_MIN alias.' -Level 'WARN'
        $highPerformance = 'SCHEME_MIN'
    }

    $active = Get-PowerSchemeGuid -Active
    Write-Log ('    Active scheme  : {0}' -f $active)
    Write-Log ('    High performance: {0}' -f $highPerformance)

    if ($active -eq $highPerformance) {
        Write-Log '    The High Performance power plan is already active.'
        return
    }

    Invoke-Process -FilePath $PowerCfgExe -ArgumentList @('-setactive', $highPerformance) -Description 'powercfg -setactive'
    Write-Log ('    Active scheme is now {0}.' -f (Get-PowerSchemeGuid -Active))
}

Invoke-Step -Name 'Enable Remote Desktop' -Script {
    Set-ItemProperty -LiteralPath $TerminalServerPath -Name 'fDenyTSConnections' -Value 0 -Force

    if ($DisableNetworkLevelAuthentication) {
        # Deliberate: the unattend file enables NLA, but legacy RDP clients need it
        # off. Run with -DisableNetworkLevelAuthentication:$false to keep NLA.
        Set-ItemProperty -LiteralPath $TerminalServerRdpTcpPath -Name 'UserAuthentication' -Value 0 -Force
    }

    Enable-NetFirewallRule -Group $RemoteDesktopFirewallGroup

    $connections = (Get-ItemProperty -LiteralPath $TerminalServerPath -Name 'fDenyTSConnections').fDenyTSConnections
    $nla         = (Get-ItemProperty -LiteralPath $TerminalServerRdpTcpPath -Name 'UserAuthentication').UserAuthentication
    Write-Log ('    fDenyTSConnections = {0}, UserAuthentication (NLA) = {1}' -f $connections, $nla)
}

Invoke-Step -Name 'Set the network adapter ring and buffer sizes' -Script {
    $adapters = @(Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty Name)
    if ($adapters.Count -eq 0) {
        Write-Log '    No connected network adapters were found; skipping.' -Level 'WARN'
        return
    }

    Write-Log ('    Connected adapters: {0}' -f ($adapters -join ', '))

    foreach ($setting in $NetworkAdapterSettings) {
        foreach ($adapter in $adapters) {
            $property = Get-NetAdapterAdvancedProperty -Name $adapter -DisplayName $setting.DisplayName -ErrorAction SilentlyContinue
            if (-not $property) {
                # The driver does not expose this setting; not every NIC does.
                Write-Log ('    {0}: not offered by "{1}"; skipped.' -f $setting.DisplayName, $adapter) -Level 'WARN'
                continue
            }

            try {
                # -NoRestart leaves the change pending until the adapter restarts, so
                # the value is read back to prove the driver accepted it.
                Set-NetAdapterAdvancedProperty -Name $adapter -DisplayName $setting.DisplayName `
                    -DisplayValue $setting.DisplayValue -NoRestart -ErrorAction Stop

                $applied = (Get-NetAdapterAdvancedProperty -Name $adapter -DisplayName $setting.DisplayName).DisplayValue
                Write-Log ('    {0}: {1} -> {2} on "{3}".' -f $setting.DisplayName, $property.DisplayValue, $applied, $adapter)
            } catch {
                Write-Log ('    {0} could not be set on "{1}": {2}' -f $setting.DisplayName, $adapter, $_.Exception.Message) -Level 'WARN'
            }
        }
    }
}
Invoke-Step -Name ('Set the time zone to {0}' -f $TimeZone) -Script {
    # tzutil /s does the same thing but reports failures only through its exit code.
    Set-TimeZone -Id $TimeZone
    Write-Log ('    time zone is now {0}.' -f (Get-TimeZone).Id)
}

# --- PowerShell 7 --------------------------------------------------------

Invoke-Step -Name ('Install PowerShell {0}' -f $PowerShellVersion) -Script {
    $installer = Join-Path $env:SystemRoot 'Temp\install-powershell.ps1'
    Invoke-WebRequest -Uri 'https://aka.ms/install-powershell.ps1' -OutFile $installer -UseBasicParsing
    Write-Log ('    installer : {0}' -f $installer)

    $arguments = @('-UseMSI', '-Quiet')
    if ($PowerShellVersion -ne 'latest') {
        $arguments += @('-Version', $PowerShellVersion)
    }

    # Run it in a child Windows PowerShell: it is a third party script and must not
    # be able to end this script early with its own exit statement (the original
    # Start-Process iex form also assembled its command line with mismatched quotes).
    Invoke-Process -FilePath $WindowsPowerShellExe `
        -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer) + $arguments) `
        -LogTailLines 10 `
        -Description 'PowerShell 7 installation'

    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) {
        throw ('pwsh.exe was not found at "{0}" after the installation.' -f $pwsh)
    }

    $installed = & $pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
    Write-Log ('    installed {0} ({1})' -f $pwsh, ($installed -join ' '))

    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$duration = (Get-Date) - $ScriptStartTime

Write-Log '========================================================================'
if ($Failures.Count -eq 0) {
    Write-Log ('Finished Windows Initialization: every step succeeded in {0:N1} minutes.' -f $duration.TotalMinutes)
} else {
    foreach ($failure in $Failures) {
        Write-Log ('FAILED STEP - {0}' -f $failure) -Level 'ERROR'
    }
    Write-Log ('Finished Windows Initialization with {0} failed step(s) in {1:N1} minutes.' -f $Failures.Count, $duration.TotalMinutes) -Level 'WARN'
}

# Lets the Packer provisioners that consume C:\CD and C:\Temp wait for this file
# instead of racing the copy that produced them.
try {
    Set-Content -LiteralPath $CompletionMarker -Value ('{0} failure(s) at {1:yyyy-MM-dd HH:mm:ss}' -f $Failures.Count, (Get-Date)) -Encoding UTF8 -Force
    Write-Log ('Completion marker written to {0}.' -f $CompletionMarker)
} catch {
    Write-Log ('Could not write the completion marker {0}: {1}' -f $CompletionMarker, $_.Exception.Message) -Level 'WARN'
}

if ($FailOnError -and $Failures.Count -gt 0) { exit 1 }
exit 0
