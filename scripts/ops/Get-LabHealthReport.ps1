<#
.SYNOPSIS
    Daily domain controller health check: 10 checks, colour-coded HTML report, optional scheduled task.

.DESCRIPTION
    Checks
       1  Core services      NTDS, DNS, Netlogon, KDC, W32Time, DHCP, Server, Spooler running
       2  DCDiag             dcdiag /q reports no failed tests
       3  DNS resolution     domain A record, DC SRV record, external name through the forwarders
       4  DHCP scope         address usage per scope (warn 80%, fail 90%)
       5  Disk space         free space per fixed disk (warn 20%, fail 10%)
       6  Pending reboot     CBS / Windows Update / pending file renames
       7  Patch age          days since the last installed update (warn 35, fail 60)
       8  Locked accounts    users currently locked out
       9  Stale accounts     enabled users with no sign-in for 90 days
      10  Password policy    enabled users with "password never expires"

    Run on DC01. Reports go to output\health\ (the newest 30 are kept).

.EXAMPLE
    .\Get-LabHealthReport.ps1                       # run now
    .\Get-LabHealthReport.ps1 -RegisterDailyTask    # schedule it every day at 07:00 as SYSTEM
#>
[CmdletBinding()]
param(
    [string]$OutputDir        = (Join-Path $PSScriptRoot '..\..\output\health'),
    [int]   $StaleDays        = 90,
    [int]   $PatchWarnDays    = 35,
    [int]   $PatchFailDays    = 60,
    [switch]$RegisterDailyTask,
    [string]$TaskTime         = '07:00',
    [int]   $KeepReports      = 30
)
$ErrorActionPreference = 'Stop'

if ($RegisterDailyTask) {
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $trigger   = New-ScheduledTaskTrigger -Daily -At $TaskTime
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'JSLab - Daily Health Report' -Action $action -Trigger $trigger `
        -Principal $principal -Description 'Runs Get-LabHealthReport.ps1 and writes an HTML report' -Force | Out-Null
    Write-Host "Scheduled 'JSLab - Daily Health Report' daily at $TaskTime (runs as SYSTEM)." -ForegroundColor Green
    return
}

Import-Module ActiveDirectory
$results = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param([string]$Name, [scriptblock]$Test)
    try {
        $r = & $Test
        $results.Add([pscustomobject]@{ Check = $Name; Status = $r[0]; Detail = $r[1] })
    }
    catch {
        $results.Add([pscustomobject]@{ Check = $Name; Status = 'Fail'; Detail = "Check errored: $($_.Exception.Message)" })
    }
}

$domainName = (Get-ADDomain).DNSRoot

# 1 ---------------------------------------------------------------------------------------
Add-Check 'Core services' {
    $names   = 'NTDS', 'DNS', 'Netlogon', 'Kdc', 'W32Time', 'DHCPServer', 'LanmanServer', 'Spooler'
    $svcs    = Get-Service -Name $names -ErrorAction SilentlyContinue
    $down    = @($svcs | Where-Object Status -ne 'Running' | ForEach-Object Name)
    $missing = @($names | Where-Object { $_ -notin $svcs.Name })
    if ($down.Count -or $missing.Count) { 'Fail', "Not running: $(($down + $missing) -join ', ')" }
    else { 'Pass', "$($names.Count) services running" }
}

# 2 ---------------------------------------------------------------------------------------
Add-Check 'DCDiag' {
    $out    = & dcdiag.exe /q /skip:SystemLog 2>&1 | Out-String
    $failed = @([regex]::Matches($out, 'failed test (\w+)') | ForEach-Object { $_.Groups[1].Value })
    if ($failed.Count) { 'Fail', "Failed tests: $($failed -join ', ')" } else { 'Pass', 'No failed tests' }
}

# 3 ---------------------------------------------------------------------------------------
Add-Check 'DNS resolution' {
    $queries = @(
        @{ Name = $domainName;                         Type = 'A'   },
        @{ Name = "_ldap._tcp.dc._msdcs.$domainName";  Type = 'SRV' },
        @{ Name = 'www.microsoft.com';                 Type = 'A'   }
    )
    $bad = foreach ($q in $queries) {
        try   { Resolve-DnsName -Name $q.Name -Type $q.Type -Server 127.0.0.1 -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null }
        catch { "$($q.Name) ($($q.Type))" }
    }
    if ($bad) { 'Fail', "Could not resolve: $($bad -join '; ')" } else { 'Pass', 'Internal records and forwarders OK' }
}

# 4 ---------------------------------------------------------------------------------------
Add-Check 'DHCP scope usage' {
    $stats = @(Get-DhcpServerv4ScopeStatistics)
    if (-not $stats.Count) { return 'Fail', 'No DHCP scopes found' }
    $worst  = ($stats | Measure-Object PercentageInUse -Maximum).Maximum
    $detail = ($stats | ForEach-Object { "$($_.ScopeId): $([math]::Round($_.PercentageInUse))% used, $($_.Free) free" }) -join '; '
    if ($worst -ge 90) { 'Fail', $detail } elseif ($worst -ge 80) { 'Warn', $detail } else { 'Pass', $detail }
}

# 5 ---------------------------------------------------------------------------------------
Add-Check 'Disk space' {
    $disks = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3'
    $low   = 100
    $parts = foreach ($d in $disks) {
        $pct = [math]::Round(($d.FreeSpace / $d.Size) * 100, 1)
        if ($pct -lt $low) { $low = $pct }
        "$($d.DeviceID) $pct% free ($([math]::Round($d.FreeSpace / 1GB, 1)) GB)"
    }
    $detail = $parts -join '; '
    if ($low -lt 10) { 'Fail', $detail } elseif ($low -lt 20) { 'Warn', $detail } else { 'Pass', $detail }
}

# 6 ---------------------------------------------------------------------------------------
Add-Check 'Pending reboot' {
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'Component servicing' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
    $pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($pfro) { $reasons += 'Pending file renames' }
    if ($reasons) { 'Warn', "Reboot pending: $($reasons -join ', '). Schedule it in the maintenance window." }
    else { 'Pass', 'No reboot pending' }
}

# 7 ---------------------------------------------------------------------------------------
Add-Check 'Patch age' {
    $last = Get-HotFix | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if (-not $last) { return 'Warn', 'No installed updates found' }
    $days   = [int]((Get-Date) - $last.InstalledOn).TotalDays
    $detail = "Last update $($last.HotFixID) installed $($last.InstalledOn.ToString('yyyy-MM-dd')) ($days days ago)"
    if ($days -gt $PatchFailDays) { 'Fail', $detail } elseif ($days -gt $PatchWarnDays) { 'Warn', $detail } else { 'Pass', $detail }
}

# 8 ---------------------------------------------------------------------------------------
Add-Check 'Locked-out accounts' {
    $locked = @(Search-ADAccount -LockedOut -UsersOnly)
    if ($locked.Count) { 'Warn', "$($locked.Count) locked: $(($locked.SamAccountName) -join ', '). Check event 4740 for the source." }
    else { 'Pass', 'No accounts locked out' }
}

# 9 ---------------------------------------------------------------------------------------
Add-Check 'Stale accounts' {
    $cutoff = (Get-Date).AddDays(-$StaleDays)
    $stale  = @(Get-ADUser -Filter 'Enabled -eq $true' -Properties LastLogonDate, whenCreated |
        Where-Object {
            ($_.LastLogonDate -and $_.LastLogonDate -lt $cutoff) -or
            (-not $_.LastLogonDate -and $_.whenCreated -lt $cutoff)
        })
    if ($stale.Count) { 'Warn', "$($stale.Count) enabled users idle $StaleDays+ days: $(($stale.SamAccountName | Select-Object -First 10) -join ', ')" }
    else { 'Pass', "No enabled users idle more than $StaleDays days" }
}

# 10 --------------------------------------------------------------------------------------
Add-Check 'Password never expires' {
    $never = @(Get-ADUser -Filter 'Enabled -eq $true -and PasswordNeverExpires -eq $true')
    if ($never.Count) { 'Warn', "$($never.Count) enabled users: $(($never.SamAccountName) -join ', '). Review or document an exception." }
    else { 'Pass', 'None' }
}

# --- Report ----------------------------------------------------------------------------------
$pass = @($results | Where-Object Status -eq 'Pass').Count
$warn = @($results | Where-Object Status -eq 'Warn').Count
$fail = @($results | Where-Object Status -eq 'Fail').Count
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'

$rows = foreach ($r in $results) {
    $check  = [System.Net.WebUtility]::HtmlEncode($r.Check)
    $detail = [System.Net.WebUtility]::HtmlEncode($r.Detail)
    "<tr><td>$check</td><td class='$($r.Status.ToLower())'>$($r.Status)</td><td>$detail</td></tr>"
}

$html = @"
<!doctype html>
<html><head><meta charset="utf-8"><title>$env:COMPUTERNAME health $stamp</title>
<style>
 body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}
 table{border-collapse:collapse;width:100%;max-width:1100px}
 th,td{border:1px solid #ddd;padding:8px;text-align:left;vertical-align:top}
 th{background:#f3f3f3}
 .pass{background:#e6f4ea;font-weight:600}.warn{background:#fff4e5;font-weight:600}.fail{background:#fdecea;font-weight:600}
</style></head><body>
<h2>$env:COMPUTERNAME ($domainName) health report</h2>
<p>$stamp &middot; <b>$pass pass</b> &middot; <b>$warn warn</b> &middot; <b>$fail fail</b></p>
<table><tr><th>Check</th><th>Status</th><th>Detail</th></tr>
$($rows -join "`n")
</table></body></html>
"@

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$file = Join-Path $OutputDir ("HealthReport-{0}.html" -f (Get-Date -Format 'yyyyMMdd-HHmm'))
$html | Set-Content -Path $file -Encoding UTF8

Get-ChildItem $OutputDir -Filter 'HealthReport-*.html' | Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $KeepReports | Remove-Item -Force

$results | Format-Table Check, Status, Detail -AutoSize -Wrap
Write-Host "$pass pass, $warn warn, $fail fail. Report: $file" -ForegroundColor $(if ($fail) { 'Red' } elseif ($warn) { 'Yellow' } else { 'Green' })
if ($fail) { exit 1 }
