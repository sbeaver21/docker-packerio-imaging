#Requires -Version 5.1
<#
    .SYNOPSIS
        Enables the remote management services a Packer build needs: WinRM, Remote Desktop
        and inbound ICMP echo requests.

    .DESCRIPTION
        Runs as the first <FirstLogonCommands> entry of the unattend file, before
        win-init.ps1:

            %SystemRoot%\system32\WindowsPowerShell\v1.0\powershell.exe -File F:\windows-init.ps1

        First logon commands run without a console, so nothing written to the console is ever
        seen. Every message therefore also goes to C:\Windows\Temp\windows-init.log, which is
        the only record of what happened during the build.

        Each customization is an independent step. A step that fails is logged and the
        remaining steps still run, so a problem with an optional feature (IPv6 ping, the
        autologon counter) cannot leave the build without the WinRM listener Packer connects
        to. Unless -FailOnError is given the script always exits 0, which is what the
        unattend file expects.

        Every step is idempotent: firewall rules are written from an explicit definition and
        registry values are overwritten with -Force, so running the script twice leaves the
        machine in the same state as running it once.

    .PARAMETER RemoteAddress
        Source addresses or subnets, for example '10.20.0.0/16', that the inbound Remote
        Desktop rules accept connections from. Empty (the default) accepts any address, which
        is what this script has always done.

    .PARAMETER NetworkProfileTimeoutSeconds
        How long to wait for a network connection profile to leave the 'Identifying...'
        state. WinRM's quick configuration refuses to run while the profile is unknown.

    .PARAMETER LogFile
        Log destination. Defaults to C:\Windows\Temp\windows-init.log.

    .PARAMETER FailOnError
        Exit with code 1 when a step failed. Off by default, so that the remaining first logon
        commands still run.

    .EXAMPLE
        powershell.exe -ExecutionPolicy Bypass -File F:\windows-init.ps1

    .EXAMPLE
        # Only accept Remote Desktop from the management subnet, and fail loudly.
        powershell.exe -ExecutionPolicy Bypass -File F:\windows-init.ps1 -RemoteAddress '10.20.0.0/16' -FailOnError

    .NOTES
        Author: Stephen Beaver
#>
[CmdletBinding()]
param(
    [string[]] $RemoteAddress                = @(),

    [int]      $NetworkProfileTimeoutSeconds = 300,

    [string]   $LogFile                      = (Join-Path $env:SystemRoot 'Temp\windows-init.log'),

    [switch]   $FailOnError
)

# ---------------------------------------------------------------------------
# Script state
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

$LogFileEnabled  = $true
$Failures        = New-Object 'System.Collections.Generic.List[string]'
$ScriptStartTime = Get-Date

# Everything below is addressed by the identifier Windows uses internally - the group
# resource ID, the rule name, the registry value name - rather than the name shown to a
# human. Display names and the text printed by winrm and netsh are localized, and a
# localized name silently stops matching on a non-English image.
$WinRmServiceName          = 'WinRM'
$WinRmCommandPath          = Join-Path $env:SystemRoot 'system32\winrm.cmd'
$WinRmFirewallGroup        = '@FirewallAPI.dll,-30267'    # Windows Remote Management (HTTP-In)
$AllowUnencryptedPath      = 'WSMan:\localhost\Service\AllowUnencrypted'
$BasicAuthPath             = 'WSMan:\localhost\Service\Auth\Basic'
$WsManListenerPath         = 'WSMan:\localhost\Listener'
$EnabledStateTrue          = 'True'
$DisabledStateFalse        = 'False'

$IdentifyingProfileName    = 'Identifying...'
$NetworkProfilePollSeconds = 5

$RemoteDesktopServiceName  = 'TermService'
$RemoteDesktopPort         = 3389
$IcmpV6EchoRequestType     = 128

$RdpRegistryPath           = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$RdpClientPolicyPath       = 'HKLM:\Software\Policies\Microsoft\Windows NT\Terminal Services\Client'
$WinlogonRegistryPath      = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$AutoLogonCountReference   = 'https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-autologon-logoncount#logoncount-known-issue'

$RuleDescription           = 'Created by windows-init.ps1 for the Packer build.'

# ICMPv4 is created without an ICMP type, which allows every ICMPv4 type - the same range
# the netsh rule this replaces allowed. ICMPv6 echo request is type 128; the type 8 the
# script used before is the ICMPv4 echo request, so IPv6 ping was never actually allowed.
$PingRuleDefinitions = @(
    @{ Name = 'Packer-ICMPv4-In'; DisplayName = 'ICMPv4 (Ping)'; Protocol = 'ICMPv4'; IcmpType = $null }
    @{ Name = 'Packer-ICMPv6-In'; DisplayName = 'ICMPv6 (Ping)'; Protocol = 'ICMPv6'; IcmpType = $IcmpV6EchoRequestType }
)

$RemoteDesktopRuleDefinitions = @(
    @{ Name = 'Packer-RDP-In-TCP'; DisplayName = 'RDP (TCP)'; Protocol = 'TCP'; LocalPort = $RemoteDesktopPort }
    @{ Name = 'Packer-RDP-In-UDP'; DisplayName = 'RDP (UDP)'; Protocol = 'UDP'; LocalPort = $RemoteDesktopPort }
)

# Names held by the rules from the version of this script that created them with
# New-NetFirewallRule -DisplayName, and by the duplicate ICMPv4 rule netsh created. Those
# rules have generated names and a different definition, so they are replaced by the named
# rules above instead of being left to accumulate.
$ManagedRuleNames       = @($RemoteDesktopRuleDefinitions.Name) + @($PingRuleDefinitions.Name)
$LegacyRuleDisplayNames = @('RDP (TCP)', 'RDP (UDP)', 'ICMP Allow V4 Ping', 'ICMP Allow V6 Ping', 'All ICMP V4')

# A terminating error that escapes every step still has to leave a record behind.
trap {
    Write-Log ('Unhandled error: {0}' -f $_.Exception.Message) -Level 'ERROR'
    if ($_.ScriptStackTrace) {
        Write-Log ('    at {0}' -f ($_.ScriptStackTrace -split '\r?\n')[0]) -Level 'ERROR'
    }
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
            The step gets its own error scope so a failure is contained and reported with the
            remaining error handling intact. Failures are collected rather than thrown so that
            later steps still run; -FailOnError rethrows instead.
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

function Invoke-NativeCommand {
    <#
        .SYNOPSIS
            Runs an external program and checks its exit code.

        .DESCRIPTION
            $ErrorActionPreference does not apply to external programs: winrm and netsh report
            a failure only through their exit code, and the original script ignored it. Output
            is written to the build log so the tool's own diagnostics are kept.

        .PARAMETER ContinueOnFailure
            Log a non-zero exit code as a warning instead of failing the step. Used where the
            result is verified afterwards anyway, which is the real gate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $FilePath,
        [string[]] $ArgumentList = @(),
        [int[]] $SuccessExitCode = @(0),
        [string] $Description = $FilePath,
        [switch] $ContinueOnFailure
    )

    Write-Log ('    > {0} {1}' -f (Split-Path -Leaf $FilePath), ($ArgumentList -join ' '))

    # An array splat passes every element as one argument, which is what a path containing a
    # space needs; the single quote around '@{...}' is also why the winrm.cmd quoting problem
    # is avoided by using the WSMan provider for these settings instead.
    $output = & $FilePath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE

    foreach ($line in @($output)) {
        if ([string] $line -match '\S') { Write-Log ('      {0}' -f ([string] $line).TrimEnd()) }
    }

    if ($SuccessExitCode -notcontains $exitCode) {
        $message = '{0} failed with exit code {1}.' -f $Description, $exitCode
        if ($ContinueOnFailure) {
            Write-Log ('    {0}' -f $message) -Level 'WARN'
        } else {
            throw $message
        }
    }

    return $exitCode
}

function Test-IsElevated {
    <#
        .SYNOPSIS
            True when the current process holds the Administrator token.
    #>
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Wait-NetworkProfile {
    <#
        .SYNOPSIS
            Returns the network connection profiles once they have been identified.

        .DESCRIPTION
            A profile that is still being identified cannot be changed, and WinRM's quick
            configuration refuses to run while a profile is unknown. The original loop had no
            end: a machine that never identifies its network hung the build forever.

            The name of an unidentified profile is localized, so on a non-English image this
            check never matches and the wait simply runs to its timeout; the step that calls
            this reports that the profile could not be used rather than waiting for ever.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [int] $TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ($true) {
        $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
        $pending  = @($profiles | Where-Object Name -eq $IdentifyingProfileName)

        if ($pending.Count -eq 0 -or (Get-Date) -ge $deadline) { break }

        Write-Log ('    {0} profile(s) still identifying; waiting {1}s...' -f $pending.Count, $NetworkProfilePollSeconds)
        Start-Sleep -Seconds $NetworkProfilePollSeconds
    }

    $pending = @($profiles | Where-Object Name -eq $IdentifyingProfileName)
    if ($pending.Count -gt 0) {
        Write-Log ('    A network profile is still "Identifying..." after {0}s.' -f $TimeoutSeconds) -Level 'WARN'
    }

    return $profiles
}

function Test-WsManValueSet {
    <#
        .SYNOPSIS
            Returns $true when the value held at a WSMan provider path is true.

        .PARAMETER Path
            A provider path such as WSMan:\localhost\Service\AllowUnencrypted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Path
    )

    $value = @((Get-Item -LiteralPath $Path -ErrorAction Stop).Value)[0]
    return ([string] $value).Trim().ToLowerInvariant() -in @('true', '1')
}

function Test-WinRmListenerConfigured {
    <#
        .SYNOPSIS
            Returns $true when at least one WinRM listener is configured.

        .DESCRIPTION
            Two independent checks, because either one on its own can be inconclusive. The
            WSMan provider shows the configuration directly, and winrm's own enumeration is
            the interface Packer's communicator ends up using; if the provider reports no
            listener, winrm's answer decides. Every observation is written to the log, so a
            failed step can be told apart from a listener that was simply not found.

        .PARAMETER WinRmCommandPath
            Path to winrm.cmd, used when the provider reports no listener.

        .OUTPUTS
            True or false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $WinRmCommandPath
    )

    if (Test-Path -LiteralPath $WsManListenerPath) {
        $listeners = @(Get-ChildItem -Path $WsManListenerPath -ErrorAction SilentlyContinue)
        if ($listeners.Count -gt 0) {
            Write-Log ('    WSMan provider listener(s): {0}' -f (($listeners | Select-Object -ExpandProperty Name) -join ', '))
            return $true
        }
        Write-Log '    The WSMan provider reports no listener.'
    }

    $output = @(& $WinRmCommandPath 'enumerate' 'winrm/config/listener' 2>&1)
    $exitCode = $LASTEXITCODE

    foreach ($line in $output) {
        if ([string] $line -match '\S') { Write-Log ('      {0}' -f ([string] $line).TrimEnd()) }
    }

    if ($exitCode -ne 0) {
        Write-Log ('    winrm enumerate exited with code {0}.' -f $exitCode) -Level 'WARN'
        return $false
    }

    return [bool] (($output | Out-String) -match 'Transport')
}

function Enable-FirewallRuleGroup {
    <#
        .SYNOPSIS
            Enables every rule in a firewall group and proves that none is left disabled.

        .DESCRIPTION
            -Group takes the group's resource ID, which is identical on every language of
            Windows. The original called netsh with the display name of a group
            ("Windows Remote Administration"), which netsh cannot match; netsh is not covered
            by $ErrorActionPreference, so that failure was invisible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Group,
        [Parameter(Mandatory, Position = 1)]
        [string] $FriendlyName
    )

    $rules = @(Get-NetFirewallRule -Group $Group -ErrorAction Stop)
    if ($rules.Count -eq 0) {
        throw ('No firewall rules exist in the group that identifies {0} ({1}).' -f $FriendlyName, $Group)
    }

    Enable-NetFirewallRule -Group $Group

    $disabled = @(Get-NetFirewallRule -Group $Group -Enabled $DisabledStateFalse -ErrorAction SilentlyContinue)
    if ($disabled.Count -gt 0) {
        throw ('{0} firewall rule(s) are still disabled after enabling the {1} group: {2}' -f `
            $disabled.Count, $FriendlyName, (($disabled | Select-Object -ExpandProperty Name) -join ', '))
    }

    Write-Log ('    enabled {0} {1} rule(s).' -f $rules.Count, $FriendlyName)
}

function Remove-LegacyFirewallRule {
    <#
        .SYNOPSIS
            Removes rules made by the earlier version of this script, keeping the named rules
            this version owns.

        .DESCRIPTION
            The rules are matched by display name because the old rules were created with
            -DisplayName and their names are generated GUIDs. A rule whose name is owned by
            this script is left alone, so a re-run does not delete and recreate its own work.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]] $DisplayName,
        [Parameter(Mandatory, Position = 1)]
        [string[]] $ManagedName
    )

    $removed = 0

    foreach ($candidate in $DisplayName) {
        # The name is tested as well as excluded: a result without a name cannot be removed, and
        # passing $null to Remove-NetFirewallRule would fail the step instead of being ignored.
        $rules = @(Get-NetFirewallRule -DisplayName $candidate -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -and $ManagedName -notcontains $_.Name })

        foreach ($rule in $rules) {
            Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop
            Write-Log ('    removed rule "{0}" (name {1}).' -f $rule.DisplayName, $rule.Name)
            $removed++
        }
    }

    if ($removed -eq 0) {
        Write-Log '    no rules from an earlier run are present.'
    }

    return $removed
}

function Set-InboundFirewallRule {
    <#
        .SYNOPSIS
            Creates one inbound allow rule from an explicit definition.

        .DESCRIPTION
            New-NetFirewallRule fails when a rule with the same name exists, so the rule is
            removed first: the definition in this file is the desired state, and an existing
            rule is replaced rather than trusted to match it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Name,
        [Parameter(Mandatory, Position = 1)]
        [string] $DisplayName,
        [Parameter(Mandatory, Position = 2)]
        [string] $Protocol,
        [int] $LocalPort = 0,
        [int] $IcmpType = 0,
        [string[]] $RemoteAddress = @(),
        [string] $Description = $RuleDescription
    )

    if (Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -Name $Name -ErrorAction Stop
    }

    $parameters = @{
        Name        = $Name
        DisplayName = $DisplayName
        Description = $Description
        Direction   = 'Inbound'
        Action      = 'Allow'
        Protocol    = $Protocol
        Profile     = 'Any'
        Enabled     = $EnabledStateTrue
    }

    if ($LocalPort -gt 0) { $parameters['LocalPort'] = $LocalPort }
    if ($IcmpType  -gt 0) { $parameters['IcmpType']  = $IcmpType }

    # RemoteAddress is only passed when it was asked for: an empty value would bind as
    # "no address", which is harder to read than leaving the restriction off.
    if ($RemoteAddress.Count -gt 0) { $parameters['RemoteAddress'] = $RemoteAddress }

    New-NetFirewallRule @parameters | Out-Null

    $rule = Get-NetFirewallRule -Name $Name -ErrorAction Stop
    if ($rule.Enabled -ne $EnabledStateTrue) {
        throw ('{0} was created but reports Enabled = {1}.' -f $DisplayName, $rule.Enabled)
    }

    $portText    = if ($LocalPort -gt 0) { 'port {0}' -f $LocalPort } else { 'every port' }
    $addressText = if ($RemoteAddress.Count -gt 0) { $RemoteAddress -join ', ' } else { 'any address' }
    Write-Log ('    {0}: {1} inbound on {2} from {3}.' -f $DisplayName, $Protocol, $portText, $addressText)
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

# Drop the log of an earlier run so that a log always belongs to one build.
Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue

$remoteAddressText = if ($RemoteAddress.Count -gt 0) { $RemoteAddress -join ', ' } else { 'any address' }

Write-Log '========================================================================'
Write-Log ('Windows remote management initialization started on {0} at {1}' -f $env:COMPUTERNAME, $ScriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))
Write-Log ('    Windows PowerShell : {0}' -f $PSVersionTable.PSVersion)
Write-Log ('    Log file           : {0}' -f $LogFile)
Write-Log ('    Remote Desktop from: {0}' -f $remoteAddressText)

if (-not (Test-IsElevated)) {
    throw 'Administrator rights are required: the script creates firewall rules, writes to HKLM and starts services. First logon commands run elevated, so this only happens when the script is run by hand from a standard shell.'
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

Invoke-Step -Name 'Make the network connection profiles usable by WinRM' -Script {
    $profiles = @(Wait-NetworkProfile -TimeoutSeconds $NetworkProfileTimeoutSeconds)
    if ($profiles.Count -eq 0) {
        throw ('No network connection profile appeared within {0}s; WinRM cannot be configured without one.' -f $NetworkProfileTimeoutSeconds)
    }

    # WinRM's quick configuration only refuses to run while a profile is Public or unknown;
    # Private and Domain are both accepted. The original set the first profile to Private
    # whatever it was, and a rejected Set-NetConnectionProfile is terminating while
    # $ErrorActionPreference is Stop, so that one call could abort the entire script and leave
    # the build with no WinRM listener, no Remote Desktop and no firewall rules at all.
    # Every profile is considered, not just the first: a build host can have more than one
    # adapter. The loop variable is $connection, not $profile: $profile is an automatic
    # variable holding the path of the PowerShell profiles, and overwriting it is both
    # misleading and a change to state the rest of the session can see.
    foreach ($connection in $profiles) {
        if ($connection.NetworkCategory -ne 'Public') {
            Write-Log ('    {0} ({1}) is {2}; WinRM accepts it.' -f $connection.Name, $connection.InterfaceAlias, $connection.NetworkCategory)
            continue
        }

        Set-NetConnectionProfile -InterfaceAlias $connection.InterfaceAlias -NetworkCategory 'Private' -ErrorAction Stop
        $updated = Get-NetConnectionProfile -InterfaceAlias $connection.InterfaceAlias -ErrorAction Stop
        Write-Log ('    {0} ({1}): {2} -> {3}' -f $updated.Name, $updated.InterfaceAlias, $connection.NetworkCategory, $updated.NetworkCategory)

        if ($updated.NetworkCategory -eq 'Public') {
            throw ('{0} is still Public after being set to Private, so the WinRM quick configuration will refuse to run.' -f $updated.InterfaceAlias)
        }
    }
}

Invoke-Step -Name 'Start the WinRM service' -Script {
    $service = Get-Service -Name $WinRmServiceName -ErrorAction Stop

    if ($service.StartType -ne 'Automatic') {
        Set-Service -Name $WinRmServiceName -StartupType 'Automatic'
    }
    if ($service.Status -ne 'Running') {
        Start-Service -Name $WinRmServiceName
    }

    $service = Get-Service -Name $WinRmServiceName
    Write-Log ('    {0} is {1} with start type {2}.' -f $WinRmServiceName, $service.Status, $service.StartType)

    if ($service.Status -ne 'Running') {
        throw ('The {0} service is {1}; Packer cannot connect without it.' -f $WinRmServiceName, $service.Status)
    }
}

Invoke-Step -Name 'Configure the WinRM listener and authentication' -Script {
    # quickconfig is still what creates the HTTP listener and the service configuration; its
    # exit code is the only thing it reports, so a failure is logged and the state is verified
    # below rather than trusted.
    Invoke-NativeCommand -FilePath $WinRmCommandPath -ArgumentList @('quickconfig', '-quiet') `
        -Description 'winrm quickconfig' -ContinueOnFailure

    # The WSMan provider replaces "winrm set winrm/config/service '@{...}'". That form handed
    # an @{...} hashtable string to a cscript wrapper, so a typo in the quoting set nothing and
    # reported no error; the provider throws instead, which the step records.
    Set-Item -Path $AllowUnencryptedPath -Value $true -Force
    Set-Item -Path $BasicAuthPath -Value $true -Force

    if (-not (Test-WinRmListenerConfigured -WinRmCommandPath $WinRmCommandPath)) {
        throw 'No WinRM listener is configured, so Packer cannot connect: quickconfig could not create one, which usually means the network connection profile is still Public or unknown.'
    }

    foreach ($setting in @($AllowUnencryptedPath, $BasicAuthPath)) {
        if (-not (Test-WsManValueSet -Path $setting)) {
            throw ('{0} is still false; the Packer WinRM communicator cannot authenticate without it.' -f $setting)
        }
        Write-Log ('    {0} = true' -f $setting)
    }
}

Invoke-Step -Name 'Allow Windows Remote Management through the firewall' -Script {
    Enable-FirewallRuleGroup -Group $WinRmFirewallGroup -FriendlyName 'Windows Remote Management'
}

Invoke-Step -Name 'Remove firewall rules made by an earlier run of this script' -Script {
    Remove-LegacyFirewallRule -DisplayName $LegacyRuleDisplayNames -ManagedName $ManagedRuleNames | Out-Null
}

Invoke-Step -Name 'Enable Remote Desktop' -Script {
    New-ItemProperty -LiteralPath $RdpRegistryPath -Name 'fDenyTSConnections' -Value 0 -PropertyType 'DWord' -Force | Out-Null

    # Client side policy, kept for parity with the desktop builds: 0 leaves the RDP client's
    # UDP transport available. The key only exists once a group policy has created it, so it
    # is created here rather than assumed.
    if (-not (Test-Path -LiteralPath $RdpClientPolicyPath)) {
        $null = New-Item -Path $RdpClientPolicyPath -Force
        Write-Log ('    created {0}' -f $RdpClientPolicyPath)
    }
    New-ItemProperty -LiteralPath $RdpClientPolicyPath -Name 'fClientDisableUDP' -Value 0 -PropertyType 'DWord' -Force | Out-Null

    $rdpDenied = (Get-ItemProperty -LiteralPath $RdpRegistryPath -Name 'fDenyTSConnections' -ErrorAction Stop).fDenyTSConnections
    $clientUdp = (Get-ItemProperty -LiteralPath $RdpClientPolicyPath -Name 'fClientDisableUDP' -ErrorAction Stop).fClientDisableUDP
    Write-Log ('    fDenyTSConnections = {0}, fClientDisableUDP = {1}' -f $rdpDenied, $clientUdp)

    if ($rdpDenied -ne 0) {
        throw ('fDenyTSConnections is {0}; Remote Desktop is still disabled.' -f $rdpDenied)
    }

    # The listener runs as TermService, which starts on demand and is not running on a fresh
    # image. Starting it here means RDP answers as soon as the build ends.
    $service = Get-Service -Name $RemoteDesktopServiceName -ErrorAction Stop
    if ($service.Status -ne 'Running') {
        Start-Service -Name $RemoteDesktopServiceName
        Write-Log ('    started the {0} service ({1} -> Running).' -f $RemoteDesktopServiceName, $service.Status)
    }

    # Explicit rules rather than the built-in Remote Desktop group: the build's network profile
    # can still be Public or Unknown at first logon, and the built-in rules are scoped to
    # Domain and Private only, which would leave RDP unreachable exactly when the build needs it.
    foreach ($definition in $RemoteDesktopRuleDefinitions) {
        Set-InboundFirewallRule -Name $definition.Name -DisplayName $definition.DisplayName `
            -Protocol $definition.Protocol -LocalPort $definition.LocalPort -RemoteAddress $RemoteAddress
    }
}

Invoke-Step -Name 'Allow inbound ICMP echo requests' -Script {
    # -RemoteAddress deliberately does not apply to these rules: it restricts Remote Desktop,
    # and the ICMP rules have always accepted echo requests from any address, which latency
    # probes and the health checks outside the build depend on.
    foreach ($definition in $PingRuleDefinitions) {
        $icmpType = if ($null -ne $definition.IcmpType) { [int] $definition.IcmpType } else { 0 }
        Set-InboundFirewallRule -Name $definition.Name -DisplayName $definition.DisplayName `
            -Protocol $definition.Protocol -IcmpType $icmpType
    }
}

Invoke-Step -Name 'Reset the autologon count' -Script {
    # Reset rather than read: the autologon counter must not survive into later builds.
    New-ItemProperty -LiteralPath $WinlogonRegistryPath -Name 'AutoLogonCount' -Value 0 -PropertyType 'DWord' -Force | Out-Null

    Write-Log ('    {0}\AutoLogonCount = {1}' -f $WinlogonRegistryPath, (Get-ItemProperty -LiteralPath $WinlogonRegistryPath -Name 'AutoLogonCount').AutoLogonCount)
    Write-Log ('    Reference: {0}' -f $AutoLogonCountReference)
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$duration = (Get-Date) - $ScriptStartTime

Write-Log '========================================================================'
if ($Failures.Count -eq 0) {
    Write-Log ('Finished remote management initialization: every step succeeded in {0:N1} minutes.' -f $duration.TotalMinutes)
} else {
    foreach ($failure in $Failures) {
        Write-Log ('FAILED STEP - {0}' -f $failure) -Level 'ERROR'
    }
    Write-Log ('Finished remote management initialization with {0} failed step(s) in {1:N1} minutes.' -f $Failures.Count, $duration.TotalMinutes) -Level 'WARN'
}

if ($FailOnError -and $Failures.Count -gt 0) { exit 1 }
exit 0
