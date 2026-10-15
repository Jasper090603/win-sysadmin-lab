# RB-02: Password reset and account unlock

**Use when:** a user forgot their password, it expired, or the account is locked.
**Who can do it:** members of `GG_IT_Helpdesk` (delegated rights only). **Typical time:** 5 minutes.

## 1. Verify identity first
Never reset based on an email or a caller's word alone. Use one of:
- Call back the number on file in AD (not the number they're calling from)
- Have their manager confirm on a ticket
- Check them in person against photo ID

Can't verify? Mark the ticket **NeedsInfo**. Don't reset.

## 2. Check the account
```powershell
Get-ADUser ewong -Properties LockedOut, Enabled, PasswordExpired, PasswordLastSet, adminCount, LastBadPasswordAttempt
```
| Finding | Action |
|---|---|
| `adminCount = 1` or a member of an admin group | **Stop. Escalate** to a Domain Admin |
| `Enabled = False` | **Stop. Escalate** to the IT Manager (they may have left) |
| `LockedOut = True` only | Unlock (step 3b). They probably don't need a reset |
| Forgot or expired | Reset (step 3a) |

## 3a. Reset
ADUC: right-click the user, choose *Reset Password*, tick *User must change password at next logon* and *Unlock the user's account*.
```powershell
Set-ADAccountPassword ewong -Reset -NewPassword (Read-Host -AsSecureString 'Temp password')
Set-ADUser ewong -ChangePasswordAtLogon $true
```
Give the temporary password by phone or in person. Don't send it in the same email or chat thread as the ticket.

## 3b. Unlock
```powershell
Unlock-ADAccount wnguyen
```
**Find the cause** so it doesn't happen again tomorrow. On DC01, look in the Security log for **event 4740**. The *Caller Computer Name* is the source.
```powershell
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4740} -MaxEvents 5 |
    Select-Object TimeCreated, @{n='User';e={$_.Properties[0].Value}}, @{n='Source';e={$_.Properties[1].Value}}
```
Common sources: a phone with an old mail password, a mapped drive with saved credentials, a scheduled task.

## Verify
The user signs in and is prompted to set a new password. `LockedOut` is `False`.

## Ticket note template
> Identity verified by callback to the number on file. Password reset with change at next sign-in; account unlocked. Lockout source per 4740: `<machine>`. Advised user to update the saved password on `<device>`.

## Escalate if
Privileged account, disabled account, repeated lockouts from an unknown machine (possible password-guessing attack), or you can't verify identity.
