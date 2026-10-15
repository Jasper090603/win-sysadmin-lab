#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Step 8: two Windows Update rings and a small workstation baseline, all delivered by Group Policy.

.DESCRIPTION
    Ring GPOs are linked to OU=Workstations and security-filtered, so a computer gets exactly one
    ring based on its group membership:

      GPO                   Applies to        Quality-update deferral   Install
      WU - Ring 1 Pilot     GG_Patch_Pilot    0 days                    daily 12:00
      WU - Ring 2 Broad     GG_Patch_Broad    7 days                    daily 03:00

    Patch flow this models: updates hit the pilot ring first, you check the pilot machines
    (Get-PatchCompliance.ps1 + Get-LabHealthReport.ps1), and the broad ring follows a week later.

    WKS - Baseline (linked to Workstations, applies to all): 15-minute screen lock, logon banner,
    WinRM listener allowed so the reporting scripts can reach the workstations.

    After linking, move a computer into a ring with:  Add-ADGroupMember GG_Patch_Pilot -Members 'WKS01$'
    then reboot it (computer group membership only updates at boot) and run gpresult /r on it.
#>
[CmdletBinding()]
param([string]$RootOU = 'JSLab')
$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy
Import-Module ActiveDirectory

$domainDN = (Get-ADDomain).DistinguishedName
$wksOU    = "OU=Workstations,OU=Computers,OU=$RootOU,$domainDN"
$wuKey    = 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate'
$auKey    = "$wuKey\AU"

function Get-OrNewGPO {
    param([string]$Name, [string]$Comment)
    try   { Get-GPO -Name $Name -ErrorAction Stop }
    catch { Write-Host "  + GPO $Name"; New-GPO -Name $Name -Comment $Comment }
}

function Set-GPLinkOnce {
    param([string]$Name, [string]$Target)
    $links = (Get-GPInheritance -Target $Target).GpoLinks | Select-Object -ExpandProperty DisplayName
    if ($links -notcontains $Name) {
        New-GPLink -Name $Name -Target $Target -LinkEnabled Yes | Out-Null
        Write-Host "    linked to $Target"
    }
}

function Set-Dword {
    param([string]$Gpo, [string]$Key, [string]$ValueName, [int]$Value)
    Set-GPRegistryValue -Name $Gpo -Key $Key -ValueName $ValueName -Type DWord -Value $Value | Out-Null
}

# --- Update rings ------------------------------------------------------------------------------
$rings = @(
    @{ Name = 'WU - Ring 1 Pilot'; Group = 'GG_Patch_Pilot'; DeferDays = 0; InstallHour = 12 },
    @{ Name = 'WU - Ring 2 Broad'; Group = 'GG_Patch_Broad'; DeferDays = 7; InstallHour = 3  }
)

foreach ($r in $rings) {
    $null = Get-OrNewGPO -Name $r.Name -Comment "Windows Update ring; quality updates deferred $($r.DeferDays) days"

    Set-Dword $r.Name $auKey 'NoAutoUpdate' 0
    Set-Dword $r.Name $auKey 'AUOptions' 4                        # 4 = auto download and schedule install
    Set-Dword $r.Name $auKey 'ScheduledInstallDay' 0              # 0 = every day
    Set-Dword $r.Name $auKey 'ScheduledInstallTime' $r.InstallHour
    Set-Dword $r.Name $auKey 'NoAutoRebootWithLoggedOnUsers' 1
    Set-Dword $r.Name $wuKey 'DeferQualityUpdates' 1
    Set-Dword $r.Name $wuKey 'DeferQualityUpdatesPeriodInDays' $r.DeferDays

    # Security filtering: everyone can READ the GPO (required since MS16-072), only the ring group APPLIES it
    Set-GPPermission -Name $r.Name -TargetName 'Authenticated Users' -TargetType Group -PermissionLevel GpoRead -Replace | Out-Null
    Set-GPPermission -Name $r.Name -TargetName $r.Group -TargetType Group -PermissionLevel GpoApply | Out-Null

    Set-GPLinkOnce -Name $r.Name -Target $wksOU
}

# --- Workstation baseline ----------------------------------------------------------------------
$baseline = 'WKS - Baseline'
$null = Get-OrNewGPO -Name $baseline -Comment 'Screen lock, logon banner, WinRM for remote reporting'
$sysKey = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System'
Set-Dword $baseline $sysKey 'InactivityTimeoutSecs' 900
Set-GPRegistryValue -Name $baseline -Key $sysKey -ValueName 'LegalNoticeCaption' -Type String `
    -Value 'JSLab - authorized use only' | Out-Null
Set-GPRegistryValue -Name $baseline -Key $sysKey -ValueName 'LegalNoticeText' -Type String `
    -Value 'This lab system is for training. Activity may be logged.' | Out-Null
$winrmKey = 'HKLM\Software\Policies\Microsoft\Windows\WinRM\Service'
Set-Dword $baseline $winrmKey 'AllowAutoConfig' 1
Set-GPRegistryValue -Name $baseline -Key $winrmKey -ValueName 'IPv4Filter' -Type String -Value '*' | Out-Null
Set-GPRegistryValue -Name $baseline -Key $winrmKey -ValueName 'IPv6Filter' -Type String -Value '*' | Out-Null
Set-GPLinkOnce -Name $baseline -Target $wksOU

Write-Host "`nGPOs linked to $wksOU" -ForegroundColor Cyan
(Get-GPInheritance -Target $wksOU).GpoLinks | Format-Table Order, DisplayName, Enabled -AutoSize
Write-Host "Put WKS01 in the pilot ring:  Add-ADGroupMember GG_Patch_Pilot -Members 'WKS01$'  (then reboot WKS01)" -ForegroundColor Green
