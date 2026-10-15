<#
.SYNOPSIS
    Mirrors the lab users and department groups into Microsoft Entra ID with Microsoft Graph PowerShell.

.DESCRIPTION
    Uses the same data\users.csv as the on-prem lab, so the cloud tenant matches AD:
      - SG-<Dept> security groups (cloud-only)
      - one cloud user per CSV row: <sam>@<tenant>.onmicrosoft.com, usage location CA,
        random temp password, must change at first sign-in
      - optional: give your own account the built-in Helpdesk Administrator role (least privilege)
      - -Remove deletes everything this script created (users go to the 30-day recycle bin)

    Run from your laptop or DC01 (needs internet). Sign in with the tenant's Global Administrator.
    Temporary passwords -> output\entra-temp-passwords.csv (LAB ONLY: output\ is git-ignored).

    In a real hybrid setup, Microsoft Entra Connect (or Cloud Sync) would sync AD users instead.
    This script is the cloud-only equivalent so the lab works without a public domain.

.EXAMPLE
    Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Groups, `
        Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Identity.Governance -Scope CurrentUser
    .\Sync-EntraLabUsers.ps1 -HelpdeskAdminUpn 'you@yourtenant.onmicrosoft.com'
.EXAMPLE
    .\Sync-EntraLabUsers.ps1 -Remove
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$UsersCsv  = (Join-Path $PSScriptRoot '..\..\data\users.csv'),
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\..\output'),
    [string]$TenantDomain,               # default: the tenant's default domain (xxx.onmicrosoft.com)
    [string]$HelpdeskAdminUpn,           # optional: account to receive Helpdesk Administrator
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\common\LabHelpers.ps1')

$required = 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Users', 'Microsoft.Graph.Groups',
            'Microsoft.Graph.Identity.DirectoryManagement', 'Microsoft.Graph.Identity.Governance'
$absent = $required | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
if ($absent) { throw "Missing modules: $($absent -join ', '). Install with: Install-Module <name> -Scope CurrentUser" }

$scopes = @('User.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.Read.All')
if ($HelpdeskAdminUpn) { $scopes += 'RoleManagement.ReadWrite.Directory' }
Connect-MgGraph -Scopes $scopes -NoWelcome

if (-not $TenantDomain) {
    $TenantDomain = (Get-MgOrganization).VerifiedDomains | Where-Object IsDefault | Select-Object -ExpandProperty Name
}
Write-Host "Tenant domain: $TenantDomain" -ForegroundColor Cyan

$users       = Import-Csv $UsersCsv
$departments = $users.Department | Sort-Object -Unique
$HelpdeskAdminRoleId = '729827e3-9c14-49f7-bb1b-9608f156bbb8'   # built-in "Helpdesk Administrator" template

function Get-LabUpn { param($Row) "$(ConvertTo-LabSamAccountName -FirstName $Row.FirstName -LastName $Row.LastName)@$TenantDomain" }

# --- Clean-up mode ------------------------------------------------------------------------
if ($Remove) {
    foreach ($row in $users) {
        $upn = Get-LabUpn $row
        $u = Get-MgUser -Filter "userPrincipalName eq '$upn'"
        if ($u -and $PSCmdlet.ShouldProcess($upn, 'Delete user')) { Remove-MgUser -UserId $u.Id; Write-Host "  - $upn" }
    }
    foreach ($d in $departments) {
        $g = Get-MgGroup -Filter "displayName eq 'SG-$d'"
        if ($g -and $PSCmdlet.ShouldProcess("SG-$d", 'Delete group')) { Remove-MgGroup -GroupId $g.Id; Write-Host "  - SG-$d" }
    }
    return
}

# --- Groups -------------------------------------------------------------------------------
$groupIds = @{}
foreach ($d in $departments) {
    $g = Get-MgGroup -Filter "displayName eq 'SG-$d'"
    if (-not $g -and $PSCmdlet.ShouldProcess("SG-$d", 'Create security group')) {
        $g = New-MgGroup -DisplayName "SG-$d" -MailEnabled:$false -MailNickname "sg-$($d.ToLower())" `
                -SecurityEnabled:$true -Description "JSLab $d department (mirrors GG_$d in AD)"
        Write-Host "  + group SG-$d"
    }
    if ($g) { $groupIds[$d] = $g.Id }
}

# --- Users --------------------------------------------------------------------------------
$issued = New-Object System.Collections.Generic.List[object]
foreach ($row in $users) {
    $upn = Get-LabUpn $row
    $u = Get-MgUser -Filter "userPrincipalName eq '$upn'"
    if (-not $u -and $PSCmdlet.ShouldProcess($upn, 'Create user')) {
        $password = New-LabPassword
        $params = @{
            AccountEnabled    = $true
            DisplayName       = "$($row.FirstName) $($row.LastName)"
            GivenName         = $row.FirstName
            Surname           = $row.LastName
            MailNickname      = ($upn -split '@')[0]
            UserPrincipalName = $upn
            Department        = $row.Department
            JobTitle          = $row.Title
            CompanyName       = 'JSLab'
            UsageLocation     = 'CA'          # required before a licence can be assigned
            PasswordProfile   = @{ Password = $password; ForceChangePasswordNextSignIn = $true }
        }
        $u = New-MgUser @params
        $issued.Add([pscustomobject]@{ UserPrincipalName = $upn; TempPassword = $password })
        Write-Host "  + user $upn"
    }
    if ($u -and $groupIds.ContainsKey($row.Department)) {
        $gid     = $groupIds[$row.Department]
        $members = Get-MgGroupMember -GroupId $gid -All | Select-Object -ExpandProperty Id
        if ($members -notcontains $u.Id -and $PSCmdlet.ShouldProcess($upn, "Add to SG-$($row.Department)")) {
            New-MgGroupMember -GroupId $gid -DirectoryObjectId $u.Id
        }
    }
}

# --- Least-privilege admin role for your own account ----------------------------------------
if ($HelpdeskAdminUpn) {
    $me = Get-MgUser -UserId $HelpdeskAdminUpn
    $existing = Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$($me.Id)' and roleDefinitionId eq '$HelpdeskAdminRoleId'"
    if (-not $existing -and $PSCmdlet.ShouldProcess($HelpdeskAdminUpn, 'Assign Helpdesk Administrator')) {
        New-MgRoleManagementDirectoryRoleAssignment -PrincipalId $me.Id -RoleDefinitionId $HelpdeskAdminRoleId -DirectoryScopeId '/' | Out-Null
        Write-Host "  + Helpdesk Administrator -> $HelpdeskAdminUpn"
    }
}

if ($issued.Count) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    $file = Join-Path $OutputDir 'entra-temp-passwords.csv'
    $issued | Export-Csv $file -NoTypeInformation -Append
    Write-Host "$($issued.Count) users created. Temp passwords (lab only): $file" -ForegroundColor Green
}

Write-Host "`nGroup counts:" -ForegroundColor Cyan
foreach ($d in $departments) {
    if ($groupIds.ContainsKey($d)) {
        $count = @(Get-MgGroupMember -GroupId $groupIds[$d] -All).Count
        Write-Host ("  SG-{0,-12} {1} members" -f $d, $count)
    }
}
