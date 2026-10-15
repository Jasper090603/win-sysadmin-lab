#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Step 2: promotes DC01 to the first domain controller of a new forest (jslab.internal).

.DESCRIPTION
    Creates the forest and domain, installs AD-integrated DNS and reboots automatically.
    After the reboot, sign in as JSLAB\Administrator (same password as the local Administrator)
    and run 03-Set-DnsDhcp.ps1.

    Why .internal? ICANN reserved the .internal top-level domain for private networks in 2024,
    so it will never collide with a real public domain (unlike the old .local habit).
#>
[CmdletBinding()]
param(
    [string]$DomainName  = 'jslab.internal',
    [string]$NetbiosName = 'JSLAB'
)
$ErrorActionPreference = 'Stop'

$role = (Get-CimInstance Win32_ComputerSystem).DomainRole
if ($role -ge 4) {
    Write-Host 'This server is already a domain controller. Nothing to do.' -ForegroundColor Yellow
    return
}

Write-Host 'The DSRM password is the break-glass password for Directory Services Restore Mode.' -ForegroundColor Cyan
Write-Host 'Store it somewhere safe (a password manager); you need it to restore AD from backup.' -ForegroundColor Cyan
$dsrm = Read-Host -AsSecureString 'DSRM password'

Import-Module ADDSDeployment

Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $NetbiosName `
    -ForestMode 'WinThreshold' `
    -DomainMode 'WinThreshold' `
    -InstallDns `
    -SafeModeAdministratorPassword $dsrm `
    -Force
# The server reboots on its own when promotion finishes.
