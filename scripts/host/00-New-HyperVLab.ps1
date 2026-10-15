#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates the lab network (internal switch + NAT) and both VMs on a Windows host running Hyper-V.

.DESCRIPTION
    Run this on your laptop (the Hyper-V host), not inside a VM.
      - Internal switch "LabNet"; the host gets 10.10.10.1 and NATs the lab to the internet
      - DC01  : Gen 2, 2 vCPU, 2-4 GB dynamic RAM, 60 GB disk, boots the Windows Server ISO
      - WKS01 : Gen 2, 2 vCPU, 4 GB static RAM, 64 GB disk, vTPM on (Windows 11 requires it)

    Using VirtualBox instead? Skip this script and follow "Option B" in docs/LAB-GUIDE.md.

.EXAMPLE
    .\00-New-HyperVLab.ps1 -ServerIso 'D:\ISO\Server2022_Eval.iso' -ClientIso 'D:\ISO\Win11_Ent_Eval.iso'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerIso,
    [Parameter(Mandatory)][string]$ClientIso,
    [string]$VmRoot     = 'C:\HyperV\JSLab',
    [string]$SwitchName = 'LabNet',
    [string]$GatewayIP  = '10.10.10.1',
    [string]$NatPrefix  = '10.10.10.0/24'
)
$ErrorActionPreference = 'Stop'

foreach ($iso in $ServerIso, $ClientIso) {
    if (-not (Test-Path $iso)) { throw "ISO not found: $iso" }
}
if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    throw 'Hyper-V is not enabled. Run: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All  then reboot.'
}

# --- 1. Network: internal switch + host gateway IP + NAT ---------------------------------
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -SwitchName $SwitchName -SwitchType Internal | Out-Null
    Write-Host "Created internal switch '$SwitchName'" -ForegroundColor Green
}

$hostNic = Get-NetAdapter -Name "vEthernet ($SwitchName)"
if (-not (Get-NetIPAddress -InterfaceIndex $hostNic.ifIndex -IPAddress $GatewayIP -ErrorAction SilentlyContinue)) {
    New-NetIPAddress -InterfaceIndex $hostNic.ifIndex -IPAddress $GatewayIP -PrefixLength 24 | Out-Null
    Write-Host "Host gateway address set to $GatewayIP" -ForegroundColor Green
}

$existingNat = Get-NetNat -ErrorAction SilentlyContinue
if (-not ($existingNat | Where-Object InternalIPInterfaceAddressPrefix -eq $NatPrefix)) {
    if ($existingNat) {
        Write-Warning "Another NAT already exists ($($existingNat.Name)). Windows allows only one; remove it or reuse its subnet."
    }
    New-NetNat -Name 'LabNAT' -InternalIPInterfaceAddressPrefix $NatPrefix | Out-Null
    Write-Host "NAT created for $NatPrefix" -ForegroundColor Green
}

# --- 2. Virtual machines -------------------------------------------------------------------
New-Item -ItemType Directory -Path $VmRoot -Force | Out-Null

function New-LabVM {
    param(
        [string]$Name,
        [string]$Iso,
        [int64]$MemoryBytes,
        [int64]$DiskBytes,
        [switch]$DynamicMemory,
        [switch]$EnableTpm
    )
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
        Write-Host "$Name already exists, skipping"
        return
    }
    $vhd = Join-Path $VmRoot "$Name.vhdx"
    New-VM -Name $Name -Generation 2 -MemoryStartupBytes $MemoryBytes -NewVHDPath $vhd `
           -NewVHDSizeBytes $DiskBytes -SwitchName $SwitchName -Path $VmRoot | Out-Null
    Set-VMProcessor -VMName $Name -Count 2
    if ($DynamicMemory) {
        Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true -MinimumBytes 1GB -StartupBytes $MemoryBytes -MaximumBytes 4GB
    }
    else {
        Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false
    }
    Add-VMDvdDrive -VMName $Name -Path $Iso
    Set-VMFirmware -VMName $Name -FirstBootDevice (Get-VMDvdDrive -VMName $Name)
    Set-VM -Name $Name -AutomaticCheckpointsEnabled $false
    Enable-VMIntegrationService -VMName $Name -Name 'Guest Service Interface'
    if ($EnableTpm) {
        Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector
        Enable-VMTPM -VMName $Name
    }
    Write-Host "Created VM $Name" -ForegroundColor Green
}

New-LabVM -Name 'DC01'  -Iso $ServerIso -MemoryBytes 2GB -DiskBytes 60GB -DynamicMemory
New-LabVM -Name 'WKS01' -Iso $ClientIso -MemoryBytes 4GB -DiskBytes 64GB -EnableTpm

Write-Host @"

Next steps
  1. Start DC01, press a key at "Press any key to boot from CD or DVD", install
     "Windows Server 2022 Standard Evaluation (Desktop Experience)".
  2. Before you change anything:  Checkpoint-VM -Name DC01 -SnapshotName 'Clean install'
  3. Continue with scripts\dc\01-Initialize-Server.ps1 inside DC01.
"@
