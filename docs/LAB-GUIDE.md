# Lab guide

Building it takes about two weekends. Each phase ends with a **Checkpoint**. Don't move on until it passes, because most of the learning happens when one doesn't.

| Name | Value |
|---|---|
| Domain | `jslab.internal` (NetBIOS `JSLAB`) |
| Network | `10.10.10.0/24`, gateway/NAT `10.10.10.1` (your laptop) |
| DC01 | `10.10.10.10`: AD DS, DNS, DHCP, File, Print |
| DHCP scope | `10.10.10.100`–`10.10.10.199`, printer reserved at `.150` |
| WKS01 | Windows 11 Enterprise, DHCP |

---

## Phase 0: Prerequisites

- **RAM:** 16 GB is comfortable (DC01 2–4 GB, WKS01 4 GB). With 8 GB, run the VMs one at a time while you build.
- **Disk:** about 80 GB free. **Virtualization** enabled in BIOS/UEFI (Intel VT-x / AMD-V).
- **Hypervisor:** check *Settings > System > About > Edition*.
  - Pro / Enterprise / Education: use Hyper-V. Run `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All` as admin, then reboot.
  - Home: use VirtualBox 7 (Option B below).
- **ISOs** from the Microsoft Evaluation Center:
  - Windows Server 2022 (180-day evaluation)
  - Windows 11 Enterprise (90-day evaluation)
- **Cloud (Phase 10):** Azure for Students. No credit card needed; you verify with your school email.

Copy the repo into each VM once it has internet:

```powershell
Invoke-WebRequest https://github.com/<you>/win-sysadmin-lab/archive/refs/heads/main.zip -OutFile C:\lab.zip
Expand-Archive C:\lab.zip C:\ ; Rename-Item C:\win-sysadmin-lab-main C:\Lab
Get-ChildItem C:\Lab -Recurse | Unblock-File
Set-ExecutionPolicy -Scope Process Bypass -Force
```

---

## Phase 1: Network and VMs

**Option A: Hyper-V.** In an admin PowerShell on your laptop:

```powershell
.\scripts\host\00-New-HyperVLab.ps1 -ServerIso D:\ISO\server2022.iso -ClientIso D:\ISO\win11ent.iso
```

**Option B: VirtualBox 7.**
1. Create the network: `VBoxManage natnetwork add --netname LabNet --network "10.10.10.0/24" --enable --dhcp off`. VirtualBox's NAT gateway is `10.10.10.1`, the same address the scripts expect.
2. Create DC01 (Windows 2022, 2 CPU, 4 GB, 60 GB) and WKS01 (Windows 11 template, 2 CPU, 4 GB, 64 GB, EFI + TPM 2.0 + Secure Boot). Attach both to **NAT Network > LabNet**.

Install Windows Server on DC01 and choose **Standard Evaluation (Desktop Experience)**. Then take a checkpoint (Hyper-V) or snapshot (VirtualBox) named `clean-install`.

**Checkpoint:** DC01 boots to the desktop, and `Get-NetAdapter` shows one adapter `Up`.

---

## Phase 2: Domain controller

On DC01, as the local Administrator:

```powershell
cd C:\Lab\scripts\dc
.\01-Initialize-Server.ps1      # static IP, roles, rename to DC01, reboot
.\02-Install-Forest.ps1         # new forest jslab.internal, reboot
```

Sign in as `JSLAB\Administrator`.

**Checkpoint**

```powershell
Get-ADDomain | Select-Object DNSRoot, NetBIOSName, DomainMode
Get-Service NTDS, DNS, Netlogon, Kdc | Format-Table Name, Status
dcdiag /q                       # no output = no failures
```

---

## Phase 3: DNS and DHCP

```powershell
.\03-Set-DnsDhcp.ps1
```

**Checkpoint**

```powershell
nslookup dc01.jslab.internal                       # 10.10.10.10
nslookup 10.10.10.10                               # dc01.jslab.internal (reverse zone works)
nslookup -type=SRV _ldap._tcp.dc._msdcs.jslab.internal
Get-DhcpServerv4Scope ; Get-DhcpServerv4OptionValue -ScopeId 10.10.10.0
```

In **DHCP console > Scope Options**, find options 003 (router), 006 (DNS) and 015 (domain name), and be ready to explain each one.

---

## Phase 4: Join the workstation

Install Windows 11 on WKS01. When it asks for a Microsoft account, choose *Sign-in options > Domain join instead* (or use a local account).

**Checkpoint before joining:** `ipconfig /all` should show an address in `10.10.10.100-199`, DNS server `10.10.10.10` and connection suffix `jslab.internal`. On DC01, `Get-DhcpServerv4Lease -ScopeId 10.10.10.0` lists the lease. This is DHCP's DORA sequence (Discover, Offer, Request, Acknowledge) working.

```powershell
C:\Lab\scripts\client\Join-LabDomain.ps1         # checks DHCP, DNS and the DC SRV record, then joins
```

**Checkpoint:** WKS01 shows up in AD, and `nslookup wks01` on DC01 resolves through dynamic DNS registration.

> WKS01 lands in the default `Computers` container. Phase 5 redirects future joins to `OU=Workstations`; move this one there after Phase 5: `Get-ADComputer WKS01 | Move-ADObject -TargetPath "OU=Workstations,OU=Computers,OU=JSLab,DC=jslab,DC=internal"`

---

## Phase 5: AD structure, users and delegation

```powershell
.\04-New-ADStructure.ps1    # OUs, 18 groups, help desk delegation, password and lockout policy
.\05-New-LabUsers.ps1       # 25 users + your hd.jsingh help desk account
```

Then install RSAT on WKS01 so you can administer from the workstation, the way you would at work:

```powershell
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0
```

**Checkpoint: test least privilege.** Sign in to WKS01 as `JSLAB\hd.jsingh` and open *Active Directory Users and Computers*.
- Reset `ewong`'s password. This should work.
- Try the same on `Administrator`. This should fail with *Access denied*.
- Try to add yourself to *Domain Admins*. This should also fail.

Write one sentence on why this matters. It's a good interview answer.

---

## Phase 6: File and print

```powershell
.\06-New-FileShares.ps1
.\07-New-LabPrinter.ps1
```

**Map drives with Group Policy Preferences** (by hand, which is how most shops do it):
1. In GPMC, create a GPO `USR - Drive Maps` and link it to `OU=Users,OU=JSLab`.
2. Go to *User Configuration > Preferences > Windows Settings > Drive Maps > New > Mapped Drive*.
   - Location `\\DC01\Finance`, drive letter `F:`, action *Update*, label `Finance`
   - On the *Common* tab, enable *Item-level targeting* > *Security Group* > `JSLAB\GG_Finance`
3. Repeat for the other departments (IT `I:`, HR `H:`, Engineering `E:`, Sales `S:`).

Deploy the printer from the same GPO: *Preferences > Control Panel Settings > Printers > Shared Printer* `\\DC01\Floor1-Printer`.

**Checkpoint:** sign in to WKS01 as `ngagnon` (Finance).
- `F:` is mapped, and you can create a file in it.
- `\\DC01` shows only `Finance`, because access-based enumeration hides the rest.
- `\\DC01\HR` returns *Access denied*.
- `whoami /groups` lists `GG_Finance`.

---

## Phase 7: Patching

```powershell
.\08-New-PatchGPOs.ps1
Add-ADGroupMember GG_Patch_Pilot -Members 'WKS01$'
Restart-Computer -ComputerName WKS01 -Force     # computer group membership only refreshes at boot
```

**Checkpoint** on WKS01:

```powershell
gpresult /r /scope computer              # "WU - Ring 1 Pilot" and "WKS - Baseline" under Applied GPOs
reg query HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate /s
```

Then, from DC01:

```powershell
C:\Lab\scripts\ops\Get-PatchCompliance.ps1     # DC01 and WKS01: missing updates, pending reboot, ring
```

Patch both machines and run it again until both show `Compliant`. Follow **[RB-05](runbooks/RB-05-monthly-patching.md)** for DC01 (checkpoint first, then patch, reboot, and run the health check).

> WSUS still works but Microsoft deprecated it in 2024. New environments use Windows Update for Business rings (what you built here) through Intune or Group Policy.

---

## Phase 8: Service desk simulation

Lock out `wnguyen` first. Leave `pnair` unlocked so you can see how the script handles an unlock request for an account that isn't locked. Run this on WKS01, ignoring the errors:

```powershell
1..5 | ForEach-Object { net use \\DC01\IPC$ /user:JSLAB\wnguyen "Wrong$_" 2>$null }
```

On DC01: `Search-ADAccount -LockedOut`, then find **event 4740** in the Security log. It names the machine the lockout came from.

Work the queue:

```powershell
cd C:\Lab\scripts\ops
.\Invoke-TicketQueue.ps1 -WhatIf      # read what it WOULD do. Agree with each decision?
.\Invoke-TicketQueue.ps1
Import-Csv ..\..\output\ticket-log.csv | Format-Table TicketId, Status, Action -AutoSize
```

Expected result: **10 Resolved, 2 Escalated, 3 NeedsInfo**. For the 3 NeedsInfo tickets, play the requester: fill in the missing field in `tickets.csv` and re-run. Only those tickets get retried.

Do two tickets **by hand** in the GUI following **[RB-02](runbooks/RB-02-password-reset-unlock.md)** and **[RB-03](runbooks/RB-03-access-change.md)**. Interviewers ask how you'd do it in ADUC, not only in PowerShell.

> Optional: track the same 15 tickets in a real tool. Jira Service Management and Freshservice both have free tiers.

---

## Phase 9: Monitoring

```powershell
.\Get-LabHealthReport.ps1                    # writes output\health\HealthReport-<date>.html
.\Get-LabHealthReport.ps1 -RegisterDailyTask # 07:00 every day, runs as SYSTEM
```

**Checkpoint:** the report opens in a browser with 10 rows. Stop the spooler (`Stop-Service Spooler`) and re-run: *Core services* should turn red. Start it again.

---

## Phase 10: Azure and Microsoft Entra ID

1. **Tenant.** Sign up for Azure for Students with a *personal* Microsoft account (outlook.com/hotmail) and verify with your school email. That gives you your own directory where you're Global Administrator. If you sign up with your school login instead, the subscription usually lands in the university's directory, where you can't create users.
2. **Users and groups:**
   ```powershell
   Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Groups, `
       Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Identity.Governance -Scope CurrentUser
   .\scripts\cloud\Sync-EntraLabUsers.ps1 -HelpdeskAdminUpn hd.jsingh@<tenant>.onmicrosoft.com
   ```
   Create `hd.jsingh` in the Entra admin center first. It's your day-to-day admin account; keep Global Administrator for break-glass use only.
3. **Do these by hand** in the Microsoft Entra admin center (entra.microsoft.com):
   - Reset a cloud user's password, then sign in as them in a private browser window. Security defaults will ask you to register MFA. Note what the user sees.
   - Block sign-in for a "leaver" and revoke their sessions.
   - Look at *Sign-in logs* for the failed and successful sign-ins you just created.
4. **Azure RBAC.** In the Azure portal, create resource group `rg-jslab` (free). Under *Access control (IAM) > Add role assignment*, give `mchen` the **Reader** role. Sign in as `mchen` and confirm you can see the group but can't change it.
5. **Optional.** The Microsoft Entra ID P2 trial (30 days, under Billing > Licenses) unlocks group-based licensing, Conditional Access and self-service password reset to explore.
6. **Clean up** when finished: `.\Sync-EntraLabUsers.ps1 -Remove`

---

## Phase 11: Break/fix exercises

Have someone else break the lab, or break it yourself and wait a day. Diagnose before you open the hint.

| # | Break it like this | Symptom |
|---|---|---|
| 1 | `Stop-Service DHCPServer` on DC01, then `ipconfig /release; ipconfig /renew` on WKS01 | Client gets `169.254.x.x` |
| 2 | Set WKS01's DNS to `8.8.8.8` | "An Active Directory Domain Controller could not be contacted", slow logons, GPOs fail |
| 3 | Lock `pnair` with 5 bad passwords | User can't sign in |
| 4 | Remove `ngagnon` from `GG_Finance` | Finance share access denied, or still works until the user signs out |
| 5 | Remove `WKS01$` from `GG_Patch_Pilot` | `gpresult` no longer shows the ring GPO |
| 6 | Delete the `prn-floor1` A record | Printer can't be reached by name |
| 7 | `Stop-Service Spooler` | Nobody can print; health report shows red |
| 8 | Set the DNS forwarder to `10.10.10.250` | Internal names resolve, the internet doesn't |

<details><summary>Hints</summary>

1. `ipconfig /all`: APIPA means no DHCP offer. On DC01: `Get-Service DHCPServer`, the event log, and `Get-DhcpServerInDC` (still authorized?).
2. Domain clients must use the DC for DNS, because public DNS has no `_ldap._tcp.dc._msdcs` SRV records. Fix the DHCP option or the NIC.
3. `Search-ADAccount -LockedOut`, then event 4740 for the source machine, then unlock (RB-02) and ask what device keeps the old password.
4. Group changes reach a user's Kerberos token at the next sign-in. `klist purge` or sign out/in. Check *Effective Access* on the folder.
5. `gpresult /r /scope computer`: look for the GPO under "Denied GPOs (Security filtering)". Fix the membership and reboot.
6. `nslookup prn-floor1`, re-add the A record, and check the DHCP reservation still exists.
7. `Get-Service Spooler`, `Get-Printer`, and clear stuck jobs in `C:\Windows\System32\spool\PRINTERS` with the service stopped.
8. `Resolve-DnsName www.microsoft.com -Server 10.10.10.10` fails while internal names work, so look at `Get-DnsServerForwarder`.
</details>

For each one, write a short note in `docs/break-fix-log.md`: symptom, cause, fix, prevention. That's the ticket-notes habit the job asks for.

---

## Phase 12: Publish it

1. Add screenshots to `docs/screenshots/`: ADUC tree, DHCP leases, `gpresult`, health report, ticket log, Entra groups.
2. Push to GitHub and pin the repo on your profile.
3. Be ready to talk through the questions below without notes.

### Interview questions this lab prepares you for

1. **What's AGDLP and why use it?** Accounts go into Global groups, Global groups go into Domain Local groups, and Domain Local groups get the Permissions. Access changes become group changes, never ACL edits.
2. **Walk me through DHCP.** DORA: Discover, Offer, Request, Acknowledge. The scope hands out the IP plus options 003 (router), 006 (DNS) and 015 (domain).
3. **Why can't a domain client use 8.8.8.8 for DNS?** It finds DCs through SRV records (`_ldap._tcp.dc._msdcs.<domain>`), which only the internal DNS server has.
4. **A user is locked out every morning. What do you do?** Unlock them, then find the source in event 4740 (usually a phone, mapped drive or saved credential with an old password) and fix that.
5. **A GPO isn't applying. How do you troubleshoot?** `gpresult /r` or `/h`: check OU link, security filtering, WMI filter, and whether it's a computer or user setting. Computer group changes need a reboot.
6. **How would you patch a domain controller safely?** Pilot ring first, backup or checkpoint, maintenance window, one DC at a time, then a health check (`dcdiag`, services, replication).
7. **AD DS vs Microsoft Entra ID?** AD DS is on-prem: Kerberos/LDAP, GPO, OUs. Entra ID is cloud identity: OAuth/SAML, Conditional Access, no OUs or GPO. Entra Connect links them in hybrid setups.
8. **Someone calls asking for a password reset. What do you check first?** Their identity (callback to the number on file, manager confirmation). Then reset, force a change at next sign-in, and never send the password over the same channel.
9. **What's adminCount=1?** Accounts protected by AdminSDHolder (members of privileged groups). The help desk shouldn't manage them.
10. **When do you escalate?** Privileged access, anything outside your documented scope, or when you're unsure. Escalate early, with clear notes on what you checked.
