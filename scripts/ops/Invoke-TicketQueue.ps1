<#
.SYNOPSIS
    Works through a queue of service desk tickets (data\tickets.csv), makes the AD changes and logs every action.

.DESCRIPTION
    Ticket types: NewUser, PasswordReset, UnlockAccount, AddToGroup, RemoveFromGroup, Offboard

    Guard rails (the same judgment calls a junior admin is expected to make):
      - Privileged accounts and groups are never touched. The ticket is marked Escalated with the reason.
      - Access changes need a valid, enabled requester (the approver). Otherwise NeedsInfo.
      - Missing fields or unknown users -> NeedsInfo, with a note saying what to ask for.
      - Errors -> Failed, with the error text, so the next person has something to work from.
      - Tickets already Resolved or Escalated in the log are skipped, so the queue can be re-run safely.

    Output (LAB ONLY: output\ is git-ignored):
      output\ticket-log.csv       one line per ticket: status, action taken, notes, technician
      output\temp-passwords.csv   temporary passwords, kept out of the ticket log on purpose

.EXAMPLE
    .\Invoke-TicketQueue.ps1 -WhatIf     # dry run: shows what would change, writes nothing
.EXAMPLE
    .\Invoke-TicketQueue.ps1             # process the queue for real
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TicketCsv = (Join-Path $PSScriptRoot '..\..\data\tickets.csv'),
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\..\output'),
    [string]$RootOU    = 'JSLab'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\common\LabHelpers.ps1')
if (-not (Get-Command Get-ADUser -ErrorAction SilentlyContinue)) { Import-Module ActiveDirectory }

$DryRun        = [bool]$WhatIfPreference

# Groups the help desk must never change without escalation
$PrivilegedGroups = @(
    'Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators', 'Account Operators',
    'Backup Operators', 'Server Operators', 'Print Operators', 'Group Policy Creator Owners',
    'DnsAdmins', 'Key Admins', 'Enterprise Key Admins', 'GG_IT_Helpdesk'
)
# Groups the help desk may change on approval
$AllowedGroupPattern = '^(GG|DL_Share)_[A-Za-z0-9_]+$'

$domain     = Get-ADDomain
$usersDN    = "OU=Users,OU=$RootOU,$($domain.DistinguishedName)"
$disabledDN = "OU=Disabled,OU=$RootOU,$($domain.DistinguishedName)"

$logPath    = Join-Path $OutputDir 'ticket-log.csv'
$secretPath = Join-Path $OutputDir 'temp-passwords.csv'
if (-not $DryRun) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

# ------------------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------------------
function Get-TicketResult {
    param([string]$Status, [string]$Action, [string]$Notes)
    [pscustomobject]@{ Status = $Status; Action = $Action; Notes = $Notes }
}

function Get-LabUser {
    param([string]$Sam)
    if (-not (Test-LabSamFormat $Sam)) { return $null }
    Get-ADUser -Filter "SamAccountName -eq '$Sam'" -Properties Enabled, LockedOut, MemberOf, adminCount, Department
}

function Test-PrivilegedUser {
    param($User)
    if ($User.adminCount -eq 1) { return $true }        # protected by AdminSDHolder
    foreach ($dn in @($User.MemberOf)) {
        $cn = ($dn -split ',')[0] -replace '^CN=', ''
        if ($PrivilegedGroups -contains $cn) { return $true }
    }
    $false
}

function Test-Requester {
    param($Ticket)
    $r = Get-LabUser $Ticket.Requester
    [bool]($r -and $r.Enabled)
}

function Get-UniqueSam {
    param([string]$First, [string]$Last)
    $base = ConvertTo-LabSamAccountName -FirstName $First -LastName $Last
    $sam  = $base
    $n    = 2
    while (Get-ADUser -Filter "SamAccountName -eq '$sam'") { $sam = "$base$n"; $n++ }
    $sam
}

function Save-TempPassword {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Lab only: temp passwords are written to a git-ignored file')]
    param([string]$TicketId, [string]$Sam, [string]$Password)
    [pscustomobject]@{ TicketId = $TicketId; SamAccountName = $Sam; TempPassword = $Password; Issued = (Get-Date -Format 's') } |
        Export-Csv -Path $secretPath -NoTypeInformation -Append
}

function Get-GroupName {
    param([string]$DistinguishedName)
    ($DistinguishedName -split ',')[0] -replace '^CN=', ''
}

$NoRequester = 'Requester not found or disabled, so the approval cannot be verified. Contacted requester to confirm.'

# ------------------------------------------------------------------------------------------
# Ticket handlers
# ------------------------------------------------------------------------------------------
function Resolve-NewUser {
    [CmdletBinding(SupportsShouldProcess)]
    param($T)
    if (-not (Test-Requester $T)) { return Get-TicketResult 'NeedsInfo' 'None' $NoRequester }

    $missing = @('FirstName', 'LastName', 'Department') | Where-Object { [string]::IsNullOrWhiteSpace($T.$_) }
    if ($missing) {
        return Get-TicketResult 'NeedsInfo' 'None' "Missing $($missing -join ', '). Asked $($T.Requester) for the details before creating the account."
    }
    if ($T.Department -notmatch '^[A-Za-z]+$' -or
        -not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq 'OU=$($T.Department),$usersDN'")) {
        return Get-TicketResult 'NeedsInfo' 'None' "Department '$($T.Department)' has no OU. Asked $($T.Requester) to confirm the department."
    }

    $sam      = Get-UniqueSam -First $T.FirstName -Last $T.LastName
    $password = New-LabPassword
    $dept     = $T.Department

    if ($PSCmdlet.ShouldProcess($sam, "Create user in OU=$dept and add to GG_$dept")) {
        New-ADUser -Name "$($T.FirstName) $($T.LastName)" -GivenName $T.FirstName -Surname $T.LastName `
            -DisplayName "$($T.FirstName) $($T.LastName)" -SamAccountName $sam `
            -UserPrincipalName "$sam@$($domain.DNSRoot)" -Department $dept -Title $T.Title -Company 'JSLab' `
            -Path "OU=$dept,$usersDN" -Enabled $true -ChangePasswordAtLogon $true `
            -AccountPassword (ConvertTo-SecureString $password -AsPlainText -Force)
        Add-ADGroupMember -Identity "GG_$dept" -Members $sam
        Save-TempPassword -TicketId $T.TicketId -Sam $sam -Password $password
    }
    Get-TicketResult 'Resolved' "Created $sam in OU=$dept; added to GG_$dept" 'Temp password sent to the manager separately; user must change it at first sign-in.'
}

function Resolve-PasswordReset {
    [CmdletBinding(SupportsShouldProcess)]
    param($T)
    $u = Get-LabUser $T.TargetUser
    if (-not $u) {
        return Get-TicketResult 'NeedsInfo' 'None' "No account '$($T.TargetUser)' in AD. Asked the caller for full name and department to find the right account."
    }
    if (Test-PrivilegedUser $u) {
        return Get-TicketResult 'Escalated' 'None' 'Privileged account (admin group or adminCount=1). Help desk does not reset these; escalated to a Domain Admin per RB-02.'
    }
    if (-not $u.Enabled) {
        return Get-TicketResult 'Escalated' 'None' 'Account is disabled. No reset; escalated to the IT Manager to confirm employment status.'
    }

    $password   = New-LabPassword
    $wasLocked  = [bool]$u.LockedOut
    if ($PSCmdlet.ShouldProcess($u.SamAccountName, 'Reset password, force change at next sign-in, unlock if locked')) {
        Set-ADAccountPassword -Identity $u -Reset -NewPassword (ConvertTo-SecureString $password -AsPlainText -Force)
        Set-ADUser -Identity $u -ChangePasswordAtLogon $true
        if ($wasLocked) { Unlock-ADAccount -Identity $u }
        Save-TempPassword -TicketId $T.TicketId -Sam $u.SamAccountName -Password $password
    }
    $extra = ''
    if ($wasLocked) { $extra = '; account also unlocked' }
    Get-TicketResult 'Resolved' "Password reset for $($u.SamAccountName)$extra" 'Identity verified before reset; temp password given by callback; must change at next sign-in.'
}

function Resolve-Unlock {
    [CmdletBinding(SupportsShouldProcess)]
    param($T)
    $u = Get-LabUser $T.TargetUser
    if (-not $u) {
        return Get-TicketResult 'NeedsInfo' 'None' "No account '$($T.TargetUser)' in AD. Asked the caller to confirm their username."
    }
    if (-not $u.LockedOut) {
        return Get-TicketResult 'Resolved' 'No change' 'Account was not locked when checked. Asked user to retry; if it locks again, find the source machine in event 4740 on DC01.'
    }
    if ($PSCmdlet.ShouldProcess($u.SamAccountName, 'Unlock account')) {
        Unlock-ADAccount -Identity $u
    }
    Get-TicketResult 'Resolved' "Unlocked $($u.SamAccountName)" 'If it repeats, check event 4740 on DC01 for the source (often a phone or mapped drive with an old password).'
}

function Resolve-GroupChange {
    [CmdletBinding(SupportsShouldProcess)]
    param($T, [bool]$Add)
    if (-not (Test-Requester $T)) { return Get-TicketResult 'NeedsInfo' 'None' $NoRequester }

    $groupName = $T.Group
    if ([string]::IsNullOrWhiteSpace($groupName)) {
        return Get-TicketResult 'NeedsInfo' 'None' "No group or share given. Asked $($T.Requester) which folder is needed and whether read or read/write."
    }
    if ($PrivilegedGroups -contains $groupName) {
        return Get-TicketResult 'Escalated' 'None' "'$groupName' is a privileged group. Needs IT Manager approval and a separate admin account (least privilege). Escalated."
    }
    if ($groupName -notmatch $AllowedGroupPattern) {
        return Get-TicketResult 'Escalated' 'None' "'$groupName' is outside help desk scope (GG_* and DL_Share_* only). Escalated to the sysadmin queue."
    }
    $g = Get-ADGroup -Filter "Name -eq '$groupName'"
    if (-not $g) {
        return Get-TicketResult 'NeedsInfo' 'None' "Group '$groupName' does not exist. Asked $($T.Requester) to confirm the share name."
    }
    $u = Get-LabUser $T.TargetUser
    if (-not $u) {
        return Get-TicketResult 'NeedsInfo' 'None' "No account '$($T.TargetUser)' in AD. Asked $($T.Requester) to confirm the username."
    }

    $isMember = @($u.MemberOf) -contains $g.DistinguishedName
    if ($Add) {
        if ($isMember) { return Get-TicketResult 'Resolved' 'No change' "$($u.SamAccountName) is already in $groupName." }
        if ($PSCmdlet.ShouldProcess($u.SamAccountName, "Add to $groupName")) {
            Add-ADGroupMember -Identity $g -Members $u
        }
        return Get-TicketResult 'Resolved' "Added $($u.SamAccountName) to $groupName" "Approved by $($T.Requester). User must sign out and back in to pick up the new group (Kerberos token)."
    }
    else {
        if (-not $isMember) { return Get-TicketResult 'Resolved' 'No change' "$($u.SamAccountName) was not in $groupName." }
        if ($PSCmdlet.ShouldProcess($u.SamAccountName, "Remove from $groupName")) {
            Remove-ADGroupMember -Identity $g -Members $u -Confirm:$false
        }
        return Get-TicketResult 'Resolved' "Removed $($u.SamAccountName) from $groupName" "Requested by $($T.Requester). Access ends at the user's next sign-in."
    }
}

function Resolve-Offboard {
    [CmdletBinding(SupportsShouldProcess)]
    param($T)
    if (-not (Test-Requester $T)) { return Get-TicketResult 'NeedsInfo' 'None' $NoRequester }
    $u = Get-LabUser $T.TargetUser
    if (-not $u) {
        return Get-TicketResult 'NeedsInfo' 'None' "No account '$($T.TargetUser)' in AD. Asked $($T.Requester) for the employee's full name."
    }
    if (Test-PrivilegedUser $u) {
        return Get-TicketResult 'Escalated' 'None' 'Privileged account. Offboarding admins needs a Domain Admin (credential rotation, service account review). Escalated.'
    }

    $groups     = @($u.MemberOf)
    $groupNames = ($groups | ForEach-Object { Get-GroupName $_ }) -join ', '
    if ($PSCmdlet.ShouldProcess($u.SamAccountName, "Remove $($groups.Count) groups, scramble password, disable, move to OU=Disabled")) {
        foreach ($dn in $groups) { Remove-ADGroupMember -Identity $dn -Members $u -Confirm:$false }
        Set-ADAccountPassword -Identity $u -Reset -NewPassword (ConvertTo-SecureString (New-LabPassword -Length 32) -AsPlainText -Force)
        Disable-ADAccount -Identity $u
        Set-ADUser -Identity $u -Description "Offboarded $(Get-Date -Format 'yyyy-MM-dd') per $($T.TicketId)"
        Move-ADObject -Identity $u.DistinguishedName -TargetPath $disabledDN
    }
    Get-TicketResult 'Resolved' "Disabled $($u.SamAccountName); removed $($groups.Count) group(s); moved to OU=Disabled" `
        "Groups removed: $groupNames. Keep 30 days, then delete per retention policy. Manager to confirm file handover."
}

function Resolve-Ticket {
    param($T)
    switch ($T.Type) {
        'NewUser'         { return Resolve-NewUser $T }
        'PasswordReset'   { return Resolve-PasswordReset $T }
        'UnlockAccount'   { return Resolve-Unlock $T }
        'AddToGroup'      { return Resolve-GroupChange $T $true }
        'RemoveFromGroup' { return Resolve-GroupChange $T $false }
        'Offboard'        { return Resolve-Offboard $T }
        default           { return Get-TicketResult 'Escalated' 'None' "Unsupported ticket type '$($T.Type)'. Routed to the sysadmin queue." }
    }
}

# ------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------
$alreadyDone = @{}
if (Test-Path $logPath) {
    Import-Csv $logPath | Where-Object { $_.Status -in 'Resolved', 'Escalated' } |
        ForEach-Object { $alreadyDone[$_.TicketId] = $_.Status }
}

$colors = @{ Resolved = 'Green'; Escalated = 'Yellow'; NeedsInfo = 'Cyan'; Failed = 'Red' }
$tickets = Import-Csv $TicketCsv
if ($DryRun) { Write-Host "DRY RUN: nothing will be changed or logged`n" -ForegroundColor Magenta }

$results = foreach ($t in $tickets) {
    if ($alreadyDone.ContainsKey($t.TicketId)) {
        Write-Host ("{0}  already {1}, skipping" -f $t.TicketId, $alreadyDone[$t.TicketId]) -ForegroundColor DarkGray
        continue
    }
    try {
        $r = Resolve-Ticket $t
    }
    catch {
        $r = Get-TicketResult 'Failed' 'Error' "$($_.Exception.Message) Escalated to sysadmin with the error text."
    }

    $target = $t.TargetUser
    if (-not $target) { $target = "$($t.FirstName) $($t.LastName)".Trim() }

    $shown = $r.Action
    if ($r.Status -ne 'Resolved') { $shown = $r.Notes }
    Write-Host ("{0}  {1,-15} {2,-14} {3,-10} {4}" -f $t.TicketId, $t.Type, $target, $r.Status, $shown) -ForegroundColor $colors[$r.Status]

    [pscustomobject]@{
        Timestamp  = (Get-Date -Format 's')
        TicketId   = $t.TicketId
        Type       = $t.Type
        Requester  = $t.Requester
        Target     = $target
        Status     = $r.Status
        Action     = $r.Action
        Notes      = $r.Notes
        Technician = [Environment]::UserName
    }
}

if (-not $results) {
    Write-Host 'Queue is empty: every ticket is already resolved or escalated.' -ForegroundColor Yellow
    return
}

Write-Host ''
$summary = $results | Group-Object Status | Sort-Object Name | ForEach-Object { "$($_.Count) $($_.Name)" }
Write-Host "Summary: $($summary -join ', ')" -ForegroundColor White

if (-not $DryRun) {
    $results | Export-Csv -Path $logPath -NoTypeInformation -Append
    Write-Host "Ticket log : $logPath" -ForegroundColor Green
    if (Test-Path $secretPath) { Write-Host "Temp passwords (lab only): $secretPath" -ForegroundColor Green }
}
