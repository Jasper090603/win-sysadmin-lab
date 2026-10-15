# RB-01: New user onboarding

**Use when:** HR or a manager raises a ticket for a new starter.
**Who can do it:** IT help desk or sysadmin. **Typical time:** 10 minutes.

## Before you start
- [ ] The ticket comes from HR or the hiring manager (not the new hire)
- [ ] It has first name, last name, department, job title and start date
- [ ] Check the person doesn't already have an account: `Get-ADUser -Filter "Surname -eq 'Lambert'"`
- [ ] Anything missing: set the ticket to **NeedsInfo** and ask the requester. Don't guess a department.

## Steps
**GUI (ADUC)**
1. Go to `JSLab > Users > <Department>` and choose *New > User*.
2. Username follows the standard: first initial + last name (`nlambert`). If it's taken, add 2, 3, and so on.
3. Set a random temporary password and tick *User must change password at next logon*.
4. On the *Organization* tab, fill in Title, Department and Company.
5. On the *Member Of* tab, add `GG_<Department>`. Shares and drive maps follow automatically through AGDLP and GPP.

**PowerShell**
```powershell
.\scripts\ops\Invoke-TicketQueue.ps1      # handles every NewUser ticket in data\tickets.csv
```

## Verify
- `Get-ADUser nlambert -Properties Department, MemberOf` shows the right OU, department and group
- After first sign-in on WKS01: the department drive is mapped and the printer is installed

## Ticket note template
> Created `<sam>` in OU=`<Dept>`, added to GG_`<Dept>`. Temp password given to `<manager>` by phone; user must change it at first sign-in. Drive `<X:>` maps via GPO.

## Escalate if
- The request asks for admin rights or access outside the department (handle that separately under RB-03)
- The department has no OU or group yet (needs a sysadmin to create the structure)
