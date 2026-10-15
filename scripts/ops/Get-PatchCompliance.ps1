<#
.SYNOPSIS
    Patch compliance report for every enabled computer in the domain (servers and workstations).

.DESCRIPTION
    For each machine: OS build, last update installed, days since patching, pending reboot,
    number of missing updates (Windows Update Agent search) and which patch ring it is in.

    Status
      Compliant     no missing updates and no pending reboot
      NonCompliant  missing updates or a reboot is pending
      Review        nothing missing but last update older than -MaxPatchAgeDays
      Unreachable   WinRM failed (machine off, firewall, or WinRM not enabled)

    Output: output\patch\PatchCompliance-<date>.csv and .html

.EXAMPLE
    .\Get-PatchCompliance.ps1                         # all enabled computers in AD
    .\Get-PatchCompliance.ps1 -ComputerName WKS01     # one machine
    .\Get-PatchCompliance.ps1 -SkipUpdateSearch       # fast: skip the missing-update search
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]  $OutputDir       = (Join-Path $PSScriptRoot '..\..\output\patch'),
    [int]     $MaxPatchAgeDays = 35,
    [switch]  $SkipUpdateSearch
)
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

if (-not $ComputerName) {
    $ComputerName = Get-ADComputer -Filter 'Enabled -eq $true' | Sort-Object Name | Select-Object -ExpandProperty Name
}

# Runs on each target machine
$scan = {
    param([bool]$SkipSearch)
    $os   = Get-CimInstance Win32_OperatingSystem
    $cv   = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $last = Get-HotFix | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1

    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
               (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')

    $missing = $null
    $titles  = ''
    if (-not $SkipSearch) {
        try {
            $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
            $found    = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
            $missing  = $found.Updates.Count
            $titles   = (@($found.Updates | ForEach-Object { $_.Title }) | Select-Object -First 5) -join ' | '
        }
        catch {
            $missing = -1
            $titles  = "Update search failed: $($_.Exception.Message)"
        }
    }

    $days = $null
    if ($last) { $days = [int]((Get-Date) - $last.InstalledOn).TotalDays }

    [pscustomobject]@{
        OS             = $os.Caption
        Build          = "$($cv.CurrentBuild).$($cv.UBR)"
        LastUpdate     = if ($last) { $last.HotFixID } else { 'none' }
        LastUpdateDate = if ($last) { $last.InstalledOn.ToString('yyyy-MM-dd') } else { '' }
        DaysSincePatch = $days
        PendingReboot  = $pending
        MissingUpdates = $missing
        MissingTitles  = $titles
        LastBoot       = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')
    }
}

$report = foreach ($c in $ComputerName) {
    Write-Host "Scanning $c ..." -ForegroundColor Cyan
    $ring = (Get-ADComputer $c -Properties MemberOf).MemberOf |
        ForEach-Object { ($_ -split ',')[0] -replace '^CN=', '' } |
        Where-Object { $_ -like 'GG_Patch_*' }
    if (-not $ring) { $ring = 'None' }

    try {
        if ($c -eq $env:COMPUTERNAME) { $r = & $scan ([bool]$SkipUpdateSearch) }
        else { $r = Invoke-Command -ComputerName $c -ScriptBlock $scan -ArgumentList ([bool]$SkipUpdateSearch) }

        $status = 'Compliant'
        if ($r.MissingUpdates -eq -1)                                   { $status = 'Unknown' }
        elseif ($r.MissingUpdates -gt 0 -or $r.PendingReboot)           { $status = 'NonCompliant' }
        elseif ($r.DaysSincePatch -gt $MaxPatchAgeDays)                 { $status = 'Review' }

        [pscustomobject]@{
            Computer = $c; Ring = ($ring -join ','); Status = $status; OS = $r.OS; Build = $r.Build
            LastUpdate = $r.LastUpdate; LastUpdateDate = $r.LastUpdateDate; DaysSincePatch = $r.DaysSincePatch
            PendingReboot = $r.PendingReboot; MissingUpdates = $r.MissingUpdates; MissingTitles = $r.MissingTitles
            LastBoot = $r.LastBoot
        }
    }
    catch {
        [pscustomobject]@{
            Computer = $c; Ring = ($ring -join ','); Status = 'Unreachable'; OS = ''; Build = ''
            LastUpdate = ''; LastUpdateDate = ''; DaysSincePatch = $null; PendingReboot = $null
            MissingUpdates = $null; MissingTitles = $_.Exception.Message; LastBoot = ''
        }
    }
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$base = Join-Path $OutputDir ("PatchCompliance-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmm'))
$report | Export-Csv "$base.csv" -NoTypeInformation

$style = '<style>body{font-family:Segoe UI,Arial;margin:24px}table{border-collapse:collapse}td,th{border:1px solid #ddd;padding:6px}th{background:#f3f3f3}</style>'
$report | Select-Object Computer, Ring, Status, Build, LastUpdateDate, DaysSincePatch, PendingReboot, MissingUpdates, MissingTitles |
    ConvertTo-Html -Title 'Patch compliance' -Head $style -PreContent "<h2>Patch compliance $(Get-Date -Format 'yyyy-MM-dd HH:mm')</h2>" |
    Set-Content "$base.html" -Encoding UTF8

$report | Format-Table Computer, Ring, Status, Build, DaysSincePatch, PendingReboot, MissingUpdates -AutoSize
$compliant = @($report | Where-Object Status -eq 'Compliant').Count
Write-Host "$compliant of $(@($report).Count) machines compliant. Report: $base.html" -ForegroundColor Green
