#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Run on the Windows 11 VM: checks DHCP and DNS, enables remoting, joins jslab.internal as WKS01.

.DESCRIPTION
    The checks mirror what you would do on a real "can't join the domain" ticket:
      1. Did the client get a DHCP lease (not 169.254.x.x / APIPA)?
      2. Is its DNS server the domain controller (not 8.8.8.8 or the router)?
      3. Can it find a DC through the _ldap SRV record?
#>
[CmdletBinding()]
param(
    [string]$DomainName   = 'jslab.internal',
    [string]$ComputerName = 'WKS01',
    [string]$DcIP         = '10.10.10.10'
)
$ErrorActionPreference = 'Stop'

$nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
$ip  = (Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 | Select-Object -First 1).IPAddress
Write-Host "IPv4 address: $ip"
if ($ip -like '169.254.*') {
    throw 'APIPA address: no DHCP lease. Check the DHCPServer service and scope on DC01, and that WKS01 is on the LabNet switch.'
}

$dns = (Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4).ServerAddresses
Write-Host "DNS servers : $($dns -join ', ')"
if ($dns -notcontains $DcIP) {
    throw "DNS is not pointing at the DC ($DcIP). Fix DHCP option 006 on DC01, then run: ipconfig /renew"
}

try {
    $srv = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$DomainName" -Type SRV -ErrorAction Stop |
        Where-Object Type -eq 'SRV' | Select-Object -First 1
    Write-Host "Found DC    : $($srv.NameTarget)" -ForegroundColor Green
}
catch {
    throw "Cannot resolve the domain controller SRV record for $DomainName. Check DNS on DC01."
}

# WinRM so Get-PatchCompliance.ps1 can query this machine later
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null

$cred = Get-Credential -Message "Account allowed to join computers, e.g. JSLAB\Administrator"
if ($env:COMPUTERNAME -ne $ComputerName) {
    Add-Computer -DomainName $DomainName -NewName $ComputerName -Credential $cred -Force -Restart
}
else {
    Add-Computer -DomainName $DomainName -Credential $cred -Force -Restart
}
