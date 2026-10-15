#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Step 7: shares a network printer from the print server and publishes it in Active Directory.

.DESCRIPTION
    There is no physical printer in the lab. The queue points at a Standard TCP/IP port on
    10.10.10.150 (DHCP reservation + DNS record from step 3), which is enough to practise
    deploying printers, permissions and troubleshooting a stuck spooler.

    Production note: never run the Print Spooler on a real domain controller (PrintNightmare,
    CVE-2021-34527). The lab doubles up roles only to save RAM.
#>
[CmdletBinding()]
param(
    [string]$PrinterName = 'Floor1-Printer',
    [string]$PrinterHost,                       # default: prn-floor1.<your domain>
    [string]$DriverName  = 'Generic / Text Only',
    [string]$Location    = 'Floor 1, open area'
)
$ErrorActionPreference = 'Stop'
if (-not $PrinterHost) { $PrinterHost = "prn-floor1.$((Get-ADDomain).DNSRoot)" }

$portName = "IP_$PrinterHost"
if (-not (Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue)) {
    Add-PrinterPort -Name $portName -PrinterHostAddress $PrinterHost
    Write-Host "  + port $portName"
}
if (-not (Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue)) {
    try {
        Add-PrinterDriver -Name $DriverName
        Write-Host "  + driver $DriverName"
    }
    catch {
        throw "Driver '$DriverName' is not in the driver store. Run Get-PrinterDriver to list installed drivers and pass one with -DriverName."
    }
}
if (-not (Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue)) {
    Add-Printer -Name $PrinterName -DriverName $DriverName -PortName $portName `
        -Shared -ShareName $PrinterName -Published -Location $Location `
        -Comment 'Lab printer queue (no physical device)'
    Write-Host "  + shared printer \\$($env:COMPUTERNAME)\$PrinterName" -ForegroundColor Green
}

Get-Printer -Name $PrinterName | Format-List Name, ShareName, PortName, DriverName, Shared, Published, PrinterStatus
