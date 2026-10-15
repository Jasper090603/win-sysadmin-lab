#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Step 3: configures DNS (forwarders, reverse zone, records, scavenging) and DHCP (authorize, scope, options).

.DESCRIPTION
    Run on DC01 as JSLAB\Administrator after the promotion reboot.
      DNS : forwarders to public resolvers, reverse lookup zone for 10.10.10.0/24, PTR for DC01,
            A record for the floor printer, aging/scavenging so stale records clean themselves up
      DHCP: authorized in AD, scope 10.10.10.100-199, router/DNS/domain options, dynamic DNS updates,
            reservation for the printer
#>
[CmdletBinding()]
param(
    [string]  $ServerIP   = '10.10.10.10',
    [string]  $ScopeId    = '10.10.10.0',
    [string]  $ScopeStart = '10.10.10.100',
    [string]  $ScopeEnd   = '10.10.10.199',
    [string]  $SubnetMask = '255.255.255.0',
    [string]  $Router     = '10.10.10.1',
    [string[]]$Forwarders = @('1.1.1.1', '8.8.8.8'),
    [string]  $PrinterIP  = '10.10.10.150',
    [string]  $PrinterMac = '00-15-5D-0A-0A-96'   # made-up MAC; there is no physical printer in the lab
)
$ErrorActionPreference = 'Stop'

$domain      = (Get-ADDomain).DNSRoot
$fqdn        = "$($env:COMPUTERNAME).$domain".ToLower()
$reverseZone = '10.10.10.in-addr.arpa'

# --- DNS client: the DC uses itself for DNS --------------------------------------------------
$nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses @($ServerIP, '127.0.0.1')

# --- DNS server ------------------------------------------------------------------------------
Write-Host 'Configuring DNS server' -ForegroundColor Cyan
Set-DnsServerForwarder -IPAddress $Forwarders

if (-not (Get-DnsServerZone -Name $reverseZone -ErrorAction SilentlyContinue)) {
    Add-DnsServerPrimaryZone -NetworkId '10.10.10.0/24' -ReplicationScope Forest -DynamicUpdate Secure
    Write-Host "  + reverse zone $reverseZone"
}
if (-not (Get-DnsServerResourceRecord -ZoneName $reverseZone -Name '10' -RRType Ptr -ErrorAction SilentlyContinue)) {
    Add-DnsServerResourceRecordPtr -ZoneName $reverseZone -Name '10' -PtrDomainName $fqdn
    Write-Host "  + PTR 10.10.10.10 -> $fqdn"
}
if (-not (Get-DnsServerResourceRecord -ZoneName $domain -Name 'prn-floor1' -RRType A -ErrorAction SilentlyContinue)) {
    Add-DnsServerResourceRecordA -ZoneName $domain -Name 'prn-floor1' -IPv4Address $PrinterIP -CreatePtr
    Write-Host "  + A prn-floor1.$domain -> $PrinterIP"
}

# Aging/scavenging: removes records left behind by machines that no longer exist
Set-DnsServerScavenging -ScavengingState $true -ScavengingInterval 7.00:00:00 -ApplyOnAllZones
Set-DnsServerZoneAging -Name $domain -Aging $true

# --- DHCP server -----------------------------------------------------------------------------
Write-Host 'Configuring DHCP server' -ForegroundColor Cyan
Add-DhcpServerSecurityGroup            # creates the DHCP Administrators / DHCP Users groups
Restart-Service DHCPServer

if (-not (Get-DhcpServerInDC | Where-Object IPAddress -eq $ServerIP)) {
    Add-DhcpServerInDC -DnsName $fqdn -IPAddress $ServerIP
    Write-Host "  + authorized $fqdn in Active Directory"
}
# Tell Server Manager that post-install configuration is complete (clears the yellow flag)
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState -Value 2

if (-not (Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue)) {
    Add-DhcpServerv4Scope -Name 'LabNet clients' -StartRange $ScopeStart -EndRange $ScopeEnd `
        -SubnetMask $SubnetMask -LeaseDuration 8.00:00:00 -State Active
    Write-Host "  + scope $ScopeStart - $ScopeEnd"
}
Set-DhcpServerv4OptionValue -ScopeId $ScopeId -Router $Router -DnsServer $ServerIP -DnsDomain $domain
Set-DhcpServerv4DnsSetting -ScopeId $ScopeId -DynamicUpdates Always -DeleteDnsRROnLeaseExpiry $true

if (-not (Get-DhcpServerv4Reservation -IPAddress $PrinterIP -ErrorAction SilentlyContinue)) {
    Add-DhcpServerv4Reservation -ScopeId $ScopeId -IPAddress $PrinterIP -ClientId $PrinterMac `
        -Name 'prn-floor1' -Description 'Floor 1 printer'
    Write-Host "  + reservation $PrinterIP for prn-floor1"
}

# --- Verify ----------------------------------------------------------------------------------
Write-Host "`nVerification" -ForegroundColor Cyan
Get-DhcpServerv4Scope | Format-Table ScopeId, Name, StartRange, EndRange, State -AutoSize
Resolve-DnsName -Name $domain -Server 127.0.0.1 | Format-Table Name, Type, IPAddress -AutoSize
Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$domain" -Type SRV -Server 127.0.0.1 |
    Where-Object Type -eq 'SRV' | Format-Table Name, NameTarget, Port -AutoSize
Resolve-DnsName -Name 'www.microsoft.com' -Server 127.0.0.1 -DnsOnly | Select-Object -First 1 |
    Format-Table Name, Type -AutoSize
Write-Host 'DNS and DHCP are ready. Next: build the client VM and join it (scripts\client\Join-LabDomain.ps1).' -ForegroundColor Green
