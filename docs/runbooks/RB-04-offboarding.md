# RB-04: Offboarding a leaver

**Use when:** HR confirms someone is leaving. Do it at the end of their last day, or **immediately** for an involuntary exit.
**Who can do it:** IT help desk (sysadmin for any privileged account). **Typical time:** 15 minutes.

## Before you start
- [ ] The ticket comes from HR or the manager, with the last day and time
- [ ] The account is not privileged (`adminCount` is not 1). If it is, **escalate**: admin offboarding also means rotating shared credentials and reviewing service accounts.
- [ ] The manager has said who receives the person's files and mailbox

## Steps
1. **Record their groups** in the ticket before removing anything, so access can be restored if HR reverses the decision:
   `(Get-ADUser lmartin -Properties MemberOf).MemberOf`
2. **Remove all groups** except Domain Users.
3. **Reset the password** to a long random value, so any cached or saved session dies.
4. **Disable** the account. Don't delete it yet.
5. **Set the description:** `Offboarded 2026-10-09 per INC-1013`
6. **Move it** to `OU=Disabled`.
7. **Cloud:** in the Entra admin center, block sign-in, choose *Revoke sessions*, and remove licences.
8. **Device:** collect the laptop and badge. Disable the computer object if the machine is being reimaged.

`Invoke-TicketQueue.ps1` does steps 1–6 for `Offboard` tickets.

## Verify
- `Get-ADUser lmartin -Properties Enabled, MemberOf, Description` shows Enabled False, no groups, and the description
- A sign-in attempt fails with *account disabled*

## Ticket note template
> Disabled `<sam>`, removed groups: `<list>`, password scrambled, moved to OU=Disabled. Entra sign-in blocked and sessions revoked. Files handed to `<manager>`. Delete after 30 days (`<date>`).

## Retention
Disabled accounts are deleted after 30 days, unless legal hold or HR says otherwise. The stale-account check in the health report catches any that are forgotten.
