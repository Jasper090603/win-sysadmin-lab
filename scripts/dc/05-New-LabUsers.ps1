#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Step 5: bulk-creates the 25 lab users from data\users.csv plus a separate help desk account.

.DESCRIPTION
    - Each user goes into OU=<Department> and joins GG_<Department>
    - Random 16-character temporary password, must change at first logon
    - Safe to re-run: existing accounts are skipped
    - Temporary passwords are written to output\initial-passwords.csv (LAB ONLY: output\ is git-ignored)

    The help desk account (default hd.jsingh) is yours: use it to practise resetting passwords
    with delegated rights only, the way a junior admin would on the job.
#>
[CmdletBinding()]
param(
    [string]$UsersCsv        = (Join-Path $PSScriptRoot '..\..\data\users.csv'),
    [string]$OutputDir       = (Join-Path $PSScriptRoot '..\..\output'),
    [string]$RootOU          = 'JSLab',
    [string]$HelpdeskAccount = 'hd.jsingh',
    [string]$HelpdeskName    = 'Jaskaran Singh (Helpdesk)'
)
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
. (Join-Path $PSScriptRoot '..\common\LabHelpers.ps1')

$domain  = Get-ADDomain
$usersDN = "OU=Users,OU=$RootOU,$($domain.DistinguishedName)"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$credFile = Join-Path $OutputDir 'initial-passwords.csv'

$users   = Import-Csv $UsersCsv
$created = New-Object System.Collections.Generic.List[object]

foreach ($u in $users) {
    $sam = ConvertTo-LabSamAccountName -FirstName $u.FirstName -LastName $u.LastName
    if (Get-ADUser -Filter "SamAccountName -eq '$sam'") {
        Write-Host "  = $sam exists, skipping"
        continue
    }
    $password = New-LabPassword
    $params = @{
        Name                  = "$($u.FirstName) $($u.LastName)"
        GivenName             = $u.FirstName
        Surname               = $u.LastName
        DisplayName           = "$($u.FirstName) $($u.LastName)"
        SamAccountName        = $sam
        UserPrincipalName     = "$sam@$($domain.DNSRoot)"
        EmailAddress          = "$sam@$($domain.DNSRoot)"
        Department            = $u.Department
        Title                 = $u.Title
        Company               = 'JSLab'
        Path                  = "OU=$($u.Department),$usersDN"
        AccountPassword       = (ConvertTo-SecureString $password -AsPlainText -Force)
        ChangePasswordAtLogon = $true
        Enabled               = $true
    }
    New-ADUser @params
    Add-ADGroupMember -Identity "GG_$($u.Department)" -Members $sam
    $created.Add([pscustomobject]@{ SamAccountName = $sam; TempPassword = $password })
    Write-Host "  + $sam  ($($u.Department), $($u.Title))"
}

# --- Your help desk account ----------------------------------------------------------------
if (-not (Get-ADUser -Filter "SamAccountName -eq '$HelpdeskAccount'")) {
    $password = New-LabPassword
    New-ADUser -Name $HelpdeskName -SamAccountName $HelpdeskAccount `
        -UserPrincipalName "$HelpdeskAccount@$($domain.DNSRoot)" -Department 'IT' -Title 'IT Intern (Helpdesk)' `
        -Company 'JSLab' -Path "OU=IT,$usersDN" -Enabled $true -ChangePasswordAtLogon $true `
        -AccountPassword (ConvertTo-SecureString $password -AsPlainText -Force)
    Add-ADGroupMember -Identity 'GG_IT_Helpdesk' -Members $HelpdeskAccount
    Add-ADGroupMember -Identity 'GG_IT' -Members $HelpdeskAccount
    $created.Add([pscustomobject]@{ SamAccountName = $HelpdeskAccount; TempPassword = $password })
    Write-Host "  + $HelpdeskAccount (help desk, delegated rights only)"
}

if ($created.Count -gt 0) {
    $created | Export-Csv -Path $credFile -NoTypeInformation -Append
    Write-Host "`n$($created.Count) accounts created. Temporary passwords: $credFile" -ForegroundColor Green
    Write-Warning 'Lab only. In production, temporary passwords go to the user through a verified channel, never a file.'
}
else {
    Write-Host 'No new accounts needed.' -ForegroundColor Yellow
}
