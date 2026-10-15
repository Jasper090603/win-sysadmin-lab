# RB-03: Access change (add or remove group membership)

**Use when:** someone needs access to a share or application, or no longer needs it.
**Who can do it:** IT help desk, for `GG_*` and `DL_Share_*` groups only. **Typical time:** 5 minutes.

## Before you start
- [ ] Who approved it? The requester must be the user's manager **and** the data owner must agree. Record both names.
- [ ] Which resource, and read or read/write? Map it to a group:
  | Need | Group |
  |---|---|
  | Read/write on own department share | `GG_<Dept>` (already nested in `DL_Share_<Dept>_RW`) |
  | Read-only on another department's share | `DL_Share_<Dept>_RO` |
  | Read/write on another department's share | `DL_Share_<Dept>_RW` (data owner must approve) |
- [ ] Temporary access? Put the end date in the ticket and create a follow-up ticket to remove it.

**Never** add a user directly to a folder's ACL. **Never** add anyone to Domain Admins, Administrators, Account Operators, Backup Operators, Server Operators, Schema/Enterprise Admins or `GG_IT_Helpdesk` from a help desk ticket. Escalate.

## Steps
ADUC: open the user, go to *Member Of > Add*, enter the group name and click *Check Names*.
```powershell
Add-ADGroupMember DL_Share_Sales_RO -Members eroy
Remove-ADGroupMember DL_Share_Sales_RO -Members eroy -Confirm:$false
```

## Verify
- `Get-ADPrincipalGroupMembership eroy | Select-Object Name`
- The user **signs out and back in**. Group membership is in the Kerberos token issued at sign-in, so the change isn't visible until then.
- On the folder, *Properties > Security > Advanced > Effective Access* for the user shows the expected rights

## Ticket note template
> Added `<user>` to `<group>` (read-only on \\DC01\Sales). Approved by `<manager>`; data owner `<owner>` agreed on `<date>`. User to sign out and in. Removal ticket `<id>` scheduled for `<date>`.

## Escalate if
The group is privileged, isn't `GG_*`/`DL_Share_*`, has no clear owner, or the request skips the manager.
