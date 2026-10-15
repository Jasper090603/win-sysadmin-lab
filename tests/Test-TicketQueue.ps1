<#
.SYNOPSIS
    Offline test for Invoke-TicketQueue.ps1. Runs on any machine with PowerShell 7 (Windows, macOS, Linux).

.DESCRIPTION
    Replaces the ActiveDirectory cmdlets with small fakes backed by an in-memory directory
    (the 25 lab users + Administrator), runs the real ticket queue against data\tickets.csv,
    and checks every outcome: statuses, accounts created, groups changed, offboarding,
    dry-run safety and re-run behaviour.

.EXAMPLE
    pwsh ./tests/Test-TicketQueue.ps1
#>
$ErrorActionPreference = 'Stop'
$repo    = Split-Path $PSScriptRoot -Parent
$script  = Join-Path $repo 'scripts/ops/Invoke-TicketQueue.ps1'
$tickets = Join-Path $repo 'data/tickets.csv'
$usersCsv = Join-Path $repo 'data/users.csv'
. (Join-Path $repo 'scripts/common/LabHelpers.ps1')

$DomainDN = 'DC=jslab,DC=internal'
$UsersDN  = "OU=Users,OU=JSLab,$DomainDN"
$GroupsDN = "OU=Groups,OU=JSLab,$DomainDN"

# ------------------------------------------------------------------------------------------
# Fake directory
# ------------------------------------------------------------------------------------------
function Reset-FakeDirectory {
    $global:FakeUsers  = @{}
    $global:FakeGroups = @{}
    $global:FakeOUs    = New-Object System.Collections.Generic.HashSet[string]
    foreach ($d in 'IT', 'Finance', 'HR', 'Engineering', 'Sales') {
        $null = $global:FakeOUs.Add("OU=$d,$UsersDN")
        foreach ($g in "GG_$d", "DL_Share_$($d)_RW", "DL_Share_$($d)_RO") { New-FakeGroup $g }
    }
    $null = $global:FakeOUs.Add("OU=Disabled,OU=JSLab,$DomainDN")
    New-FakeGroup 'GG_IT_Helpdesk'
    $global:FakeGroups['Domain Admins'] = [pscustomobject]@{ Name = 'Domain Admins'; DistinguishedName = "CN=Domain Admins,CN=Users,$DomainDN" }

    foreach ($row in Import-Csv $usersCsv) {
        $sam = ConvertTo-LabSamAccountName $row.FirstName $row.LastName
        New-FakeUser -Sam $sam -OU "OU=$($row.Department),$UsersDN" -Department $row.Department
        Add-FakeMember -Group "GG_$($row.Department)" -Sam $sam
    }
    New-FakeUser -Sam 'Administrator' -OU "CN=Users,$DomainDN" -Department '' -AdminCount 1
    Add-FakeMember -Group 'Domain Admins' -Sam 'Administrator'
    $global:FakeUsers['wnguyen'].LockedOut = $true      # INC-1007 expects a locked account
}

function New-FakeGroup([string]$Name) {
    $global:FakeGroups[$Name] = [pscustomobject]@{ Name = $Name; DistinguishedName = "CN=$Name,$GroupsDN" }
}

function New-FakeUser([string]$Sam, [string]$OU, [string]$Department, [int]$AdminCount = 0) {
    $global:FakeUsers[$Sam] = [pscustomobject]@{
        SamAccountName        = $Sam
        DistinguishedName     = "CN=$Sam,$OU"
        Enabled               = $true
        LockedOut             = $false
        MemberOf              = New-Object System.Collections.Generic.List[string]
        adminCount            = $AdminCount
        Department            = $Department
        Description           = ''
        ChangePasswordAtLogon = $false
        PasswordResets        = 0
    }
}

function Add-FakeMember([string]$Group, [string]$Sam) {
    $global:FakeUsers[$Sam].MemberOf.Add($global:FakeGroups[$Group].DistinguishedName)
}

function Resolve-FakeUser($Id) {
    if ($Id -is [string]) {
        if ($global:FakeUsers.ContainsKey($Id)) { return $global:FakeUsers[$Id] }
        return $global:FakeUsers.Values | Where-Object DistinguishedName -eq $Id
    }
    $global:FakeUsers[$Id.SamAccountName]
}

function Resolve-FakeGroup($Id) {
    if ($Id -is [string]) {
        if ($global:FakeGroups.ContainsKey($Id)) { return $global:FakeGroups[$Id] }
        return $global:FakeGroups.Values | Where-Object DistinguishedName -eq $Id
    }
    $global:FakeGroups[$Id.Name]
}

# ------------------------------------------------------------------------------------------
# Fake ActiveDirectory cmdlets (only the parameters the ticket queue uses)
# ------------------------------------------------------------------------------------------
function global:Get-ADDomain { [pscustomobject]@{ DistinguishedName = $DomainDN; DNSRoot = 'jslab.internal'; NetBIOSName = 'JSLAB' } }

function global:Get-ADUser {
    param([string]$Filter, [string[]]$Properties)
    if ($Filter -match "SamAccountName -eq '([^']+)'") {
        $sam = $Matches[1]
        if ($global:FakeUsers.ContainsKey($sam)) { return $global:FakeUsers[$sam] }
    }
}

function global:Get-ADGroup {
    param([string]$Filter)
    if ($Filter -match "Name -eq '([^']+)'" -and $global:FakeGroups.ContainsKey($Matches[1])) { $global:FakeGroups[$Matches[1]] }
}

function global:Get-ADOrganizationalUnit {
    param([string]$Filter)
    if ($Filter -match "DistinguishedName -eq '([^']+)'" -and $global:FakeOUs.Contains($Matches[1])) {
        [pscustomobject]@{ DistinguishedName = $Matches[1] }
    }
}

function global:New-ADUser {
    param($Name, $GivenName, $Surname, $DisplayName, $SamAccountName, $UserPrincipalName, $Department,
          $Title, $Company, $Path, $Enabled, $ChangePasswordAtLogon, $AccountPassword)
    New-FakeUser -Sam $SamAccountName -OU $Path -Department $Department
    $global:FakeUsers[$SamAccountName].ChangePasswordAtLogon = [bool]$ChangePasswordAtLogon
}

function global:Add-ADGroupMember {
    param($Identity, $Members)
    $g = Resolve-FakeGroup $Identity
    (Resolve-FakeUser $Members).MemberOf.Add($g.DistinguishedName)
}

function global:Remove-ADGroupMember {
    [CmdletBinding(SupportsShouldProcess)]
    param($Identity, $Members)
    $g = Resolve-FakeGroup $Identity
    $null = (Resolve-FakeUser $Members).MemberOf.Remove($g.DistinguishedName)
}

function global:Set-ADAccountPassword {
    param($Identity, [switch]$Reset, $NewPassword)
    (Resolve-FakeUser $Identity).PasswordResets++
}

function global:Set-ADUser {
    param($Identity, $ChangePasswordAtLogon, $Description)
    $u = Resolve-FakeUser $Identity
    if ($PSBoundParameters.ContainsKey('ChangePasswordAtLogon')) { $u.ChangePasswordAtLogon = [bool]$ChangePasswordAtLogon }
    if ($PSBoundParameters.ContainsKey('Description')) { $u.Description = $Description }
}

function global:Unlock-ADAccount  { param($Identity) (Resolve-FakeUser $Identity).LockedOut = $false }
function global:Disable-ADAccount { param($Identity) (Resolve-FakeUser $Identity).Enabled = $false }

function global:Move-ADObject {
    param($Identity, $TargetPath)
    $u = Resolve-FakeUser $Identity
    $u.DistinguishedName = "CN=$($u.SamAccountName),$TargetPath"
}

# ------------------------------------------------------------------------------------------
# Assertions
# ------------------------------------------------------------------------------------------
$script:Passed = 0
$script:Failed = 0
function Assert-That([string]$Name, [bool]$Condition) {
    if ($Condition) { $script:Passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else            { $script:Failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}

$out = Join-Path ([System.IO.Path]::GetTempPath()) ("jslab-test-" + [guid]::NewGuid())

# --- 1. Dry run changes nothing ------------------------------------------------------------
Write-Host "`n[1] Dry run (-WhatIf)" -ForegroundColor Cyan
Reset-FakeDirectory
& $script -TicketCsv $tickets -OutputDir $out -WhatIf *> $null
Assert-That 'no output folder written'          (-not (Test-Path $out))
Assert-That 'no user created'                   (-not $global:FakeUsers.ContainsKey('nlambert'))
Assert-That 'locked account left locked'        ($global:FakeUsers['wnguyen'].LockedOut)
Assert-That 'leaver still enabled'              ($global:FakeUsers['lmartin'].Enabled)

# --- 2. Real run ------------------------------------------------------------------------------
Write-Host "`n[2] Real run" -ForegroundColor Cyan
Reset-FakeDirectory
& $script -TicketCsv $tickets -OutputDir $out *> $null
$log = Import-Csv (Join-Path $out 'ticket-log.csv')
$status = @{}; $log | ForEach-Object { $status[$_.TicketId] = $_.Status }

$expected = [ordered]@{
    'INC-1001' = 'Resolved';  'INC-1002' = 'Resolved';  'INC-1003' = 'NeedsInfo'; 'INC-1004' = 'Resolved'
    'INC-1005' = 'Resolved';  'INC-1006' = 'NeedsInfo'; 'INC-1007' = 'Resolved';  'INC-1008' = 'Resolved'
    'INC-1009' = 'Resolved';  'INC-1010' = 'Escalated'; 'INC-1011' = 'NeedsInfo'; 'INC-1012' = 'Resolved'
    'INC-1013' = 'Resolved';  'INC-1014' = 'Resolved';  'INC-1015' = 'Escalated'
}
foreach ($k in $expected.Keys) { Assert-That "$k is $($expected[$k])" ($status[$k] -eq $expected[$k]) }
Assert-That '15 tickets logged' ($log.Count -eq 15)

$finance = $global:FakeGroups['GG_Finance'].DistinguishedName
Assert-That 'nlambert created in Finance and GG_Finance' (
    $global:FakeUsers['nlambert'].DistinguishedName -like '*OU=Finance*' -and
    $global:FakeUsers['nlambert'].MemberOf -contains $finance)
Assert-That 'new user must change password'      ($global:FakeUsers['rpatel'].ChangePasswordAtLogon)
Assert-That 'ewong password reset once'          ($global:FakeUsers['ewong'].PasswordResets -eq 1)
Assert-That 'wnguyen unlocked'                   (-not $global:FakeUsers['wnguyen'].LockedOut)
Assert-That 'eroy access added then removed'     ($global:FakeUsers['eroy'].MemberOf -notcontains $global:FakeGroups['DL_Share_Sales_RO'].DistinguishedName)
Assert-That 'dpark NOT in Domain Admins'         ($global:FakeUsers['dpark'].MemberOf -notcontains $global:FakeGroups['Domain Admins'].DistinguishedName)
Assert-That 'Administrator password untouched'   ($global:FakeUsers['Administrator'].PasswordResets -eq 0)
$lm = $global:FakeUsers['lmartin']
Assert-That 'lmartin disabled'                   (-not $lm.Enabled)
Assert-That 'lmartin moved to OU=Disabled'       ($lm.DistinguishedName -like '*OU=Disabled*')
Assert-That 'lmartin has no groups left'         ($lm.MemberOf.Count -eq 0)
Assert-That 'lmartin description has ticket id'  ($lm.Description -like '*INC-1013*')

$secrets = Import-Csv (Join-Path $out 'temp-passwords.csv')
Assert-That '4 temp passwords issued (2 new users + 2 resets)' ($secrets.Count -eq 4)
Assert-That 'no password text in the ticket log' (-not (Select-String -Path (Join-Path $out 'ticket-log.csv') -SimpleMatch -Pattern ($secrets[0].TempPassword) -Quiet))

# --- 3. Re-run only retries NeedsInfo tickets ---------------------------------------------------
Write-Host "`n[3] Re-run" -ForegroundColor Cyan
& $script -TicketCsv $tickets -OutputDir $out *> $null
$log2 = Import-Csv (Join-Path $out 'ticket-log.csv')
Assert-That 're-run adds only the 3 NeedsInfo tickets' ($log2.Count -eq 18)
Assert-That 'no duplicate account for INC-1001'        (-not $global:FakeUsers.ContainsKey('nlambert2'))

# --- 4. Password helper ---------------------------------------------------------------------------
Write-Host "`n[4] New-LabPassword" -ForegroundColor Cyan
$pw = 1..200 | ForEach-Object { New-LabPassword }
Assert-That '200 passwords all 16 chars'          (@($pw | Where-Object Length -ne 16).Count -eq 0)
Assert-That 'all meet complexity (upper/lower/digit/symbol)' (@($pw | Where-Object {
    $_ -cmatch '[A-Z]' -and $_ -cmatch '[a-z]' -and $_ -match '\d' -and $_ -match '[^A-Za-z0-9]' }).Count -eq 200)
Assert-That 'no duplicates'                       (@($pw | Sort-Object -Unique).Count -eq 200)

Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n$script:Passed passed, $script:Failed failed" -ForegroundColor $(if ($script:Failed) { 'Red' } else { 'Green' })
if ($script:Failed) { exit 1 }
