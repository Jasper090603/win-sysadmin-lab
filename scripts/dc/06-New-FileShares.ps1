#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Step 6: creates one SMB share per department with NTFS permissions granted only through groups.

.DESCRIPTION
    Share permissions : Authenticated Users = Change, Administrators = Full
    NTFS permissions  : inheritance removed, then
                          SYSTEM / Administrators     Full control
                          DL_Share_<Dept>_RW          Modify
                          DL_Share_<Dept>_RO          Read & execute
    Access-based enumeration is on, so people only see folders they can open.

    Rule of thumb this demonstrates: never put a user directly on an ACL. Grant to a
    domain local group, nest the global group in it, and access changes become group changes.
#>
[CmdletBinding()]
param(
    [string]  $ShareRoot   = 'C:\Shares',
    [string[]]$Departments = @('IT', 'Finance', 'HR', 'Engineering', 'Sales')
)
$ErrorActionPreference = 'Stop'
$netbios = (Get-ADDomain).NetBIOSName

foreach ($d in $Departments) {
    $path = Join-Path $ShareRoot $d
    New-Item -ItemType Directory -Path $path -Force | Out-Null

    $grants = @(
        'NT AUTHORITY\SYSTEM:(OI)(CI)F',
        'BUILTIN\Administrators:(OI)(CI)F',
        "$netbios\DL_Share_$($d)_RW:(OI)(CI)M",
        "$netbios\DL_Share_$($d)_RO:(OI)(CI)RX"
    )
    & icacls.exe $path /inheritance:r /grant:r $grants | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $path (exit $LASTEXITCODE)" }

    if (-not (Get-SmbShare -Name $d -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $d -Path $path `
            -FullAccess 'BUILTIN\Administrators' `
            -ChangeAccess 'NT AUTHORITY\Authenticated Users' `
            -FolderEnumerationMode AccessBased -CachingMode None | Out-Null
        Write-Host "  + \\$($env:COMPUTERNAME)\$d" -ForegroundColor Green
    }
    else {
        Write-Host "  = \\$($env:COMPUTERNAME)\$d exists (NTFS permissions re-applied)"
    }
}

Write-Host "`nNTFS permissions on the Finance share:" -ForegroundColor Cyan
& icacls.exe (Join-Path $ShareRoot 'Finance')
Write-Host 'Map the drives for users with Group Policy Preferences (see docs/LAB-GUIDE.md, Phase 6).' -ForegroundColor Green
