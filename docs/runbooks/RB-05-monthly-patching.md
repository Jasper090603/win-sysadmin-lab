# RB-05: Monthly patching

**Use when:** Patch Tuesday (second Tuesday of the month), or an out-of-band security update.
**Who can do it:** sysadmin, with the help desk watching for user reports. **Typical time:** 1 hour over the week.

## Schedule
| When | What |
|---|---|
| Patch Tuesday +0 | Read Microsoft's release notes; flag anything actively exploited |
| Day 0–1 | **Ring 1 Pilot** (`GG_Patch_Pilot`) installs automatically at 12:00 |
| Day 1–6 | Watch pilot machines: help desk tickets, `Get-PatchCompliance.ps1`, event logs |
| Day 7 | **Ring 2 Broad** (`GG_Patch_Broad`) receives the same updates (7-day deferral) |
| Maintenance window | Servers, one at a time (below) |

To stop a bad update from reaching Broad, pause it in the `WU - Ring 2 Broad` GPO before day 7, then open a ticket.

## Server / domain controller steps
1. Announce the maintenance window.
2. **Before:** run `.\Get-LabHealthReport.ps1` and confirm it's all green. A health problem after patching should be something new, not something that was already there.
3. Take a backup or snapshot: `VBoxManage snapshot DC01 take "pre-patch-2026-10"` (Hyper-V: `Checkpoint-VM -Name DC01 -SnapshotName "pre-patch"`)
4. Install: *Settings > Windows Update*, or `sconfig` option 6.
5. Reboot. With more than one DC, do one at a time and never all at once.
6. **After:** run `.\Get-LabHealthReport.ps1` and `dcdiag /q`. Confirm DNS, DHCP and sign-ins on WKS01.
7. Run `.\Get-PatchCompliance.ps1` and check the server shows **Compliant**.
8. After a few days without issues, delete the checkpoint. Old checkpoints on a DC are a rollback risk.

## Verify
`Get-PatchCompliance.ps1` shows every machine Compliant, with `DaysSincePatch` under 35.

## Ticket / change note template
> `<Month>` patching: pilot `<date>`, broad `<date>`, DC01 `<date time>`. KBs: `<list>`. Health check green before and after. Issues: none / `<ticket ids>`.

## Roll back if
Sign-ins fail, DNS or DHCP stops, or a line-of-business app breaks. Uninstall the KB (`wusa /uninstall /kb:<id>`) or revert the checkpoint, then open a ticket with the KB number and symptoms.
