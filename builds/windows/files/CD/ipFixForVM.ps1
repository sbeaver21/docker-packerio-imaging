$actions = @('Backup','Restore')

Function Show-Menu {
    Param(
        [String[]]$actions
    )
    do { 
        Write-Host "Please make a selection"
        $index = 1
        foreach ($action in $actions) {
            Write-Host "[$index] $action"
            $index++
        }
        $Selection = Read-Host 
    } until ($actions[$selection-1])
    Write-Verbose "You selected $($actions[$selection-1])" -Verbose
    $actions[$selection-1]
}

$ipAction = Show-Menu -actions $actions

if ( $ipAction -eq "Backup"){

    Get-NetIpConfiguration | Out-File C:\CD\netConfig.ini 
    Get-NetAdapter | Get-NetIpConfiguration | Get-NetIpAddress | Where-Object AddressFamily -eq IPv4 | ConvertTo-Json | Out-File C:\CD\ip4net.json

} else {

    $ipType = "IPv4"
    $adapter = Get-NetAdapter #| ?{$.Status -eq "up"} 
    $interface = $adapter | Get-NetIPInterface -AddressFamily $IPType 
    $InterfaceAlias = ((Get-Content C:\CD\netConfig.ini) | Select-String "InterfaceAlias").toString().split(":")[1].trim()
    $InterfaceIndex = ((Get-Content C:\CD\netConfig.ini) | Select-String "InterfaceIndex").toString().split(":")[1].trim()
    $InterfaceDescription = ((Get-Content C:\CD\netConfig.ini) | Select-String "InterfaceDescription").toString().split(":")[1].trim()
    $NetProfileName = ((Get-Content C:\CD\netConfig.ini) | Select-String "NetProfile.Name").toString().split(":")[1].trim()
    $IPv4Address = ((Get-Content C:\CD\netConfig.ini) | Select-String "IPv4Address").toString().split(":")[1].trim()
    $IPv4DefaultGateway = ((Get-Content C:\CD\netConfig.ini) | Select-String "IPv4DefaultGateway").toString().split(":")[1].trim()
    $DNSServer = ((Get-Content C:\CD\netConfig.ini) | Select-String "DNSServer").toString().split(":")[1].trim()
    $PrefixLength = (Get-Content C:\CD\ip4net.json | ConvertFrom-Json).PrefixLength 
    $dns1 = ((Get-Content C:\CD\netConfig.ini).split(":")[17].trim())
    $dns2 = ((Get-Content C:\CD\netConfig.ini).split(":")[18].trim())

    Write-Host "Adapter is $adapter"
    Write-Host "Interface is $interface"
    Write-Host "ipType is $ipType"
    Write-Host "InterfaceIndex is $InterfaceIndex"
    Write-Host "InterfaceDescription is $InterfaceDescription"
    Write-Host "NetProfileName is $NetProfileName" 
    Write-Host "IPv4Address is $IPv4Address"
    Write-Host "InterfaceAlias is $InterfaceAlias"
    Write-Host "PrefixLength is $PrefixLength"
    Write-Host "DNSServer is $DNSServer"
    #$interface | Set-NetIPInterface -InterfaceAlias $InterfaceAlias -Dhcp Disabled 
    #$adapter | New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $IPv4Address -PrefixLength $PrefixLength -DefaultGateway $IPv4DefaultGateway

    Set-NetIPInterface -InterfaceAlias $InterfaceAlias -Dhcp Disabled 
    New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $IPv4Address -PrefixLength $PrefixLength -DefaultGateway $IPv4DefaultGateway
    Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses ($dns1,$dns2)
}
