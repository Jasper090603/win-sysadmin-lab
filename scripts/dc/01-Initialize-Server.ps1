#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Step 1 on the fresh Windows Server VM: static IP, hostname, time zone and server roles.

.DESCRIPTION
    Installs AD DS, DNS, DHCP, File Server and Print Server roles plus their management tools,
    renames the server to DC01 and reboots. Run 02-Install-Forest.ps1 after the reboot.

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force
    .\01-Initialize-Server.ps1
#>
[CmdletBinding()]
param(
    [string]$ComputerName = 'DC01',
    [string]$IPAddress    = '10.10.10.10',
    [int]   $PrefixLength = 24,
    [string]$Gateway      = '10.10.10.1',
    [string]$TempDns      = '1.1.1.1',
    [string]$TimeZone     = 'Eastern Standard Time'
)
$ErrorActionPreference = 'Stop'

# --- Static IP -------------------------------------------------------------------------
$nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
if (-not $nic) { throw 'No connected network adapter found. Check that the VM is attached to the LabNet switch.' }

Write-Host "Configuring '$($nic.Name)' as $IPAddress/$PrefixLength, gateway $Gateway" -ForegroundColor Cyan
Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Disabled
Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false
Get-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false
New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $IPAddress -PrefixLength $PrefixLength -DefaultGateway $Gateway | Out-Null

# Public DNS for now so the server can reach Windows Update. 03-Set-DnsDhcp.ps1 points it at itself later.
Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $TempDns

if (-not (Test-Connection -ComputerName $Gateway -Count 2 -Quiet)) {
    Write-Warning "Cannot ping the gateway $Gateway. Check the host NAT (00-New-HyperVLab.ps1) before continuing."
}

# --- Time zone ----------------------------------------------------------------------------
Set-TimeZone -Id $TimeZone

# --- Roles --------------------------------------------------------------------------------
$features = 'AD-Domain-Services', 'DNS', 'DHCP', 'FS-FileServer', 'Print-Server', 'GPMC'
Write-Host "Installing roles: $($features -join ', ')" -ForegroundColor Cyan
$result = Install-WindowsFeature -Name $features -IncludeManagementTools
$result | Format-Table Success, RestartNeeded, ExitCode -AutoSize

# --- Rename + reboot ------------------------------------------------------------------------
if ($env:COMPUTERNAME -ne $ComputerName) {
    Rename-Computer -NewName $ComputerName -Force
}
Write-Host 'Done. Rebooting in 15 seconds; then run 02-Install-Forest.ps1' -ForegroundColor Green
Start-Sleep -Seconds 15
Restart-Computer -Force
