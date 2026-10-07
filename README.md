# Intune Patch & App Remediation Pipeline

Automated detection, grouping, and remediation of **Windows Update** and **App installation** failures across your Intune-managed devices.

## Architecture

```
Azure Automation (scheduled daily)
    │
    ├── Graph API: windowsUpdateStates (patch failures)
    │   └── Group by errorCode → AAD groups: Intune-PatchError-{code}
    │
    ├── Graph API: mobileApps/{id}/deviceStatuses (app failures)
    │   └── Group by errorCode → AAD groups: Intune-AppError-{code}
    │
    └── Intune Remediations → targeted at each group
```

## Files

### Shared Infrastructure
| File | Purpose |
|---|---|
| `IntuneUpdateErrorGroups.ps1` | Azure Automation runbook for patch errors (single source of truth) |
| `IntuneUpdateErrorGroups-Local.ps1` | Thin local wrapper: interactive Graph login, runs the main runbook |
| `App\IntuneAppErrorGroups.ps1` | Azure Automation runbook for app errors (single source of truth) |
| `App\IntuneAppErrorGroups-Local.ps1` | Thin local wrapper: interactive Graph login, runs the main runbook |
| `AZURE-AUTOMATION-SETUP.md` | Setup guide for Azure Automation + Graph permissions |

### Patch Remediation (Windows Updates)
| File | Purpose |
|---|---|
| `DetectionTemplate.ps1` | Fast scan for patch error conditions. Exit 0=compliant, 1=needs fix |
| `RemediationTemplate.ps1` | Safe, verifying remediation for all patch error codes |
| `ERROR-REFERENCE.md` | Full error code + remediation reference for patches |

### App Remediation (Win32/MSI/Store Apps)
| File | Purpose |
|---|---|
| `App\DetectionTemplate.ps1` | Scans for common app install blockers |
| `App\RemediationTemplate.ps1` | Targeted remediation for app install errors |
| `App\ERROR-REFERENCE.md` | Full error code + remediation reference for apps |

### Tests
| File | Purpose |
|---|---|
| `Tests\Run-Tests.ps1` | Offline suite: parse checks, Graph pagination/retry/$batch, membership diff, detection helpers. No tenant needed |

### Diagrams
| File | Purpose |
|---|---|
| `poster.svg` | Full pipeline diagram + all error codes with remediations |
| `Workflow-Animated.svg` | Animated pipeline flow chart (open in a browser) |

## Quick Start

```powershell
# 1. Run the offline test suite first (no tenant needed)
.\Tests\Run-Tests.ps1

# 2. Dry-run against your tenant (reads everything, changes nothing)
.\IntuneUpdateErrorGroups-Local.ps1 -DryRun
.\App\IntuneAppErrorGroups-Local.ps1 -DryRun

# 3. Apply for real
.\IntuneUpdateErrorGroups-Local.ps1

# 4. Deploy detection/remediation scripts in Intune
#    as Remediations targeting the created AAD groups
```

## Runbook Parameters

| Parameter | Scripts | Effect |
|---|---|---|
| `-DryRun` | all runbooks | Preview every create/add/remove/delete without writing |
| `-Interactive` | main runbooks only | Sign in with the signed-in user (used by the `-Local` wrappers) |
| `-TenantId <id>` | `-Local` wrappers | Target a specific Entra tenant when interactive |
| `-CleanupOrphanedGroups` | all runbooks | Delete automation-marked groups whose error code no longer occurs (default: just empty them) |
| `-GroupPrefix <prefix>` | all runbooks | Override `Intune-PatchError` / `Intune-AppError` |
| `-AppFilter <text>` | app runbook | Only scan apps whose display name matches |

## Detection / Remediation Contract

| Exit code | Detection means | Remediation means |
|---|---|---|
| 0 | Compliant (no action) | Fixed / nothing to fix (`Verified`, `Unknown`) |
| 1 | Non-compliant (remediation runs) | Not fixed (`Failed`) - visible in Intune's report |

Remediation output lines are `State|Detail` (e.g. `Verified|free space now 12.4 GB`,
`RebootRequired|...`, `ProductVersionConflict|...`) so outcomes land in the Intune report.

### Detection switches (edit defaults before deploying - Intune passes no params)

| Switch | Default | Effect |
|---|---|---|
| `-IncludeSlowChecks` | off | Full scan also runs DISM CheckHealth (targeted scans always may) |
| `-RequireWUServer` | off | Full scan flags a missing WSUS policy (for WSUS-managed estates; cloud-only Intune stays compliant) |
| `-Strict` | off | Detection errors exit 1 instead of 0 (broken detection normally must not trigger remediation) |
| `-AllowChkdsk` | off (patch remediation) | Schedules `chkdsk C: /f` (never `/r`) at next reboot |

## Prod-Safety Behavior

- **Group sync**: paged Graph reads, exponential-backoff retry on 429/5xx, membership
  synced read-diff-write via JSON `$batch` (20 ops/call). Non-GUID device ids are
  counted and skipped; if *all* targets are invalid the group is left untouched.
- **Ownership guard**: groups are only modified when their description carries the
  `Managed by automation` marker - hand-made groups with a matching name are never touched.
- **Stale groups**: groups whose error code no longer occurs are emptied each run
  (deleted only with `-CleanupOrphanedGroups`).
- **Detection**: pending reboot reads the registry *value* (`Test-Path` on a value is
  always False); full scan runs only fast checks; BITS is flagged only when disabled
  or holding errored jobs; DISM output is matched on exit code + hex markers, not
  English-only text.
- **Remediation**: idempotent and non-destructive - temp cleanup is age-limited (24 h),
  no `DISM /ResetBase`, no `chkdsk /r`, no winsock/ip reset, no `pending.xml` deletion,
  no stopping of running services for low memory, no execution-policy changes, and
  msiexec is only killed when demonstrably stuck.

## License Note

Intune **Remediations** (formerly Proactive Remediations) require Windows Enterprise
E3/E5, Education A3/A5, or VDA per user.
