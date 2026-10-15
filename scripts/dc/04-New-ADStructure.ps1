#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Step 4: builds the OU tree, security groups, help desk delegation and the domain password policy.

.DESCRIPTION
    OU=JSLab
      OU=Users      -> OU=IT, Finance, HR, Engineering, Sales
      OU=Groups     -> all lab security groups
      OU=Computers  -> OU=Workstations (new domain joins land here)
      OU=Disabled   -> offboarded accounts

    Groups follow AGDLP: Accounts -> Global groups -> Domain Local groups -> Permissions
      GG_<Dept>               Global       one per department (people)
      DL_Share_<Dept>_RW/_RO  Domain Local one pair per share (permissions)
      GG_IT_Helpdesk          Global       delegated: reset passwords + unlock users in OU=Users
      GG_Patch_Pilot/_Broad   Global       computer groups that pick the Windows Update ring
#>
[CmdletBinding()]
param(
    [string]  $RootOU      = 'JSLab',
    [string[]]$Departments = @('IT', 'Finance', 'HR', 'Engineering', 'Sales')
)
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$domain   = Get-ADDomain
$domainDN = $domain.DistinguishedName
$netbios  = $domain.NetBIOSName

function New-LabOU {
    param([string]$Name, [string]$Path)
    $dn = "OU=$Name,$Path"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $true
        Write-Host "  + OU  $dn"
    }
    $dn
}

function New-LabGroup {
    param([string]$Name, [string]$Scope, [string]$Path, [string]$Description)
    if (-not (Get-ADGroup -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $Name -SamAccountName $Name -GroupScope $Scope -GroupCategory Security `
            -Path $Path -Description $Description
        Write-Host "  + GRP $Name ($Scope)"
    }
}

# --- OUs ---------------------------------------------------------------------------------
Write-Host 'Creating OUs' -ForegroundColor Cyan
$rootDN      = New-LabOU -Name $RootOU      -Path $domainDN
$usersDN     = New-LabOU -Name 'Users'      -Path $rootDN
$groupsDN    = New-LabOU -Name 'Groups'     -Path $rootDN
$computersDN = New-LabOU -Name 'Computers'  -Path $rootDN
$null        = New-LabOU -Name 'Disabled'   -Path $rootDN
$wksDN       = New-LabOU -Name 'Workstations' -Path $computersDN
foreach ($d in $Departments) { $null = New-LabOU -Name $d -Path $usersDN }

# --- Groups ------------------------------------------------------------------------------
Write-Host 'Creating groups' -ForegroundColor Cyan
foreach ($d in $Departments) {
    New-LabGroup -Name "GG_$d"             -Scope Global      -Path $groupsDN -Description "All $d staff"
    New-LabGroup -Name "DL_Share_$($d)_RW" -Scope DomainLocal -Path $groupsDN -Description "Modify on \\DC01\$d"
    New-LabGroup -Name "DL_Share_$($d)_RO" -Scope DomainLocal -Path $groupsDN -Description "Read on \\DC01\$d"
    # AGDLP: the department's global group gets read/write on its own share
    $members = Get-ADGroupMember -Identity "DL_Share_$($d)_RW" | Select-Object -ExpandProperty SamAccountName
    if ($members -notcontains "GG_$d") {
        Add-ADGroupMember -Identity "DL_Share_$($d)_RW" -Members "GG_$d"
        Write-Host "  + GG_$d nested in DL_Share_$($d)_RW"
    }
}
New-LabGroup -Name 'GG_IT_Helpdesk' -Scope Global -Path $groupsDN -Description 'Delegated password reset and unlock on lab users'
New-LabGroup -Name 'GG_Patch_Pilot' -Scope Global -Path $groupsDN -Description 'Computers in Windows Update ring 1 (no deferral)'
New-LabGroup -Name 'GG_Patch_Broad' -Scope Global -Path $groupsDN -Description 'Computers in Windows Update ring 2 (7-day deferral)'

# --- Help desk delegation (least privilege instead of Domain Admins) -----------------------
Write-Host 'Delegating password reset and unlock to GG_IT_Helpdesk' -ForegroundColor Cyan
$hd = "$netbios\GG_IT_Helpdesk"
$aces = @(
    "$($hd):CA;Reset Password;user",   # reset password (extended right)
    "$($hd):RPWP;pwdLastSet;user",     # tick "User must change password at next logon"
    "$($hd):RPWP;lockoutTime;user"     # unlock account
)
foreach ($ace in $aces) {
    & dsacls.exe $usersDN /I:S /G $ace | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "dsacls failed for '$ace'. Check OU=Users > Properties > Security in ADUC." }
}

# --- New computers land in the Workstations OU instead of the default container --------------
& redircmp.exe $wksDN | Out-Null

# --- Domain password + lockout policy ----------------------------------------------------------
Write-Host 'Setting default domain password policy' -ForegroundColor Cyan
Set-ADDefaultDomainPasswordPolicy -Identity $domain.DNSRoot `
    -MinPasswordLength 12 -ComplexityEnabled $true -PasswordHistoryCount 12 `
    -MaxPasswordAge 90.00:00:00 -MinPasswordAge 1.00:00:00 `
    -LockoutThreshold 5 -LockoutDuration 00:15:00 -LockoutObservationWindow 00:15:00

Get-ADDefaultDomainPasswordPolicy | Format-List MinPasswordLength, LockoutThreshold, LockoutDuration, MaxPasswordAge
Write-Host 'AD structure ready. Next: 05-New-LabUsers.ps1' -ForegroundColor Green
