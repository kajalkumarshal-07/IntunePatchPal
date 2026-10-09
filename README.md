# IntunePatchPal

> **your fleet's patch buddy** — detects, groups, fixes, tidies up

Automated detection, grouping, and remediation of **Windows Update** and **App installation** failures across your Intune-managed devices — deployed with **one click**, on **any tenant**.

```
Azure Automation (daily 06:00)
    │
    ├── Graph reports: update alert failures  → group per code: Intune-PatchError-{code}
    ├── Graph reports: app install failures   → group per code: Intune-AppError-{code}
    │
    └── Intune Remediations: one package per code, assigned to its group
            device fails → enters group → detection runs → remediation fixes → device leaves group
```

---

## Minimum Requirements

| | Requirement | Notes |
|---|---|---|
| **Machine** | Windows 10/11 with PowerShell 5.1 | Built into Windows; the installer runs from any folder |
| **Network** | Outbound HTTPS to `login.microsoftonline.com`, `graph.microsoft.com`, `management.azure.com` | No VPN/private endpoints needed |
| **Azure CLI** | `az` command available | `Install.cmd` auto-installs it via winget if missing |
| **Azure** | An **enabled subscription** in the target tenant | Free trial is fine; the Automation account uses the **Free** SKU (no cost) |
| **Permissions** | **Global Administrator** on the target tenant (or equivalent) | Needed once: admin-consent for Graph permissions + creating the resource group. Afterwards no GA rights are used |
| **Intune** | Tenant has a valid **Intune service** | Devices must be Entra joined/hybrid joined and MDM-enrolled |
| **Device licensing** | **Windows Enterprise E3/E5, Education A3/A5, or VDA per user** | Required for Remediations (formerly Proactive Remediations) to *execute* on devices — confirm in Intune admin center before rollout |
| **Optional** | Python 3.x | Only to regenerate the presentation/poster (`Tests\Build-*.py`) |

No on-prem servers, no SQL, no custom app registrations are required — everything runs on Azure Automation's managed identity plus Intune's built-in remediation engine.

---

## Setup — Step by Step

### Step 1 — Get the files

Copy the whole `IntuneRemediations` folder to the machine you will deploy from (any path works, e.g. `C:\Tools\IntuneRemediations`).

### Step 2 — Run the offline tests (no tenant needed)

Open PowerShell in the folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Tests\Run-Tests.ps1
```

Expected final line:

```
== Result: 57 passed, 0 failed ==
```

If anything fails, stop and fix it before touching the tenant.

### Step 3 — One-click deploy (recommended)

Double-click **`Install.cmd`**.

What it does, in order:

1. **Azure CLI check** — if missing, installs it via `winget` (then asks you to re-open a fresh command window once and re-run).
2. **Sign in** — if not logged in, opens a browser: sign in with an account that is Global Administrator **of the tenant you want to set up**.
3. **Step 1/2 — infrastructure** (`Deploy-Azure.ps1`): creates
   - resource group `RG-IntuneManagement` (region `eastus` by default),
   - Automation account `AA-IntunePatchAutomation` + system-assigned identity, **Free** SKU,
   - 5 Microsoft Graph app-role grants for that identity,
   - both runbooks (imported + published), the `Daily-0600` schedule (06:00 in the configured timezone),
   - a **first dry-run job per runbook** as proof the identity/permissions chain works.
4. **Step 2/2 — content** (`Deploy-ErrorGroupsAndRemediations.ps1`): creates
   - **49 Entra groups** (25 patch + 24 app, e.g. `Intune-PatchError--2147024784`, `Intune-AppError-1603`),
   - **49 Intune remediation packages** (each with the error code baked into detection + remediation, runs as SYSTEM),
   - **49 assignments**, each package scoped to exactly its own group.
   - First run on a tenant pops **one browser consent window** (Graph permission `DeviceManagementScripts.ReadWrite.All`) — click **Accept**.
5. **Summary** — prints OK/FAILED per step, log paths, and a portal checklist.

Typical duration: **5–10 minutes**. Safe to re-run at any time (everything is detected and reused).

Logs: `%TEMP%\Intune-Deploy-Azure.log` and `%TEMP%\Intune-Deploy-Remediations.log`.

> **Manual alternative** (same result, if you prefer commands):
> ```powershell
> az login
> powershell -ExecutionPolicy Bypass -File .\Deploy-Azure.ps1
> powershell -ExecutionPolicy Bypass -File .\Deploy-ErrorGroupsAndRemediations.ps1
> ```
> Useful options: `-TimeZone 'W. Europe Standard Time'`, `-ScheduleHour 6`, `-SubscriptionId <id>`,
> `-ExpectedTenantId <guid>` (refuses to deploy if signed into the wrong tenant),
> `-Lane Patch|App` or `-SkipRemediations`, `-TenantId <guid>`.

### Step 4 — Verify in the portals

| Where | What you should see |
|---|---|
| Azure portal → Automation Accounts → `AA-IntunePatchAutomation` | **Runbooks**: two *Published*; **Schedules**: `Daily-0600`; **Jobs**: first two jobs *Completed* with `*** DRY RUN ***` and `Connected to Graph (Tenant: …, AuthType: ManagedIdentity)` in the output |
| Entra portal → Groups | 49 groups starting with `Intune-PatchError-` / `Intune-AppError-`, description ends with `Managed by automation` |
| Intune portal → Apps → Remediations | 49 entries, one per error code, status *Active*, each assigned to its matching group, *Run this script using the logged-on credentials* = **No** (SYSTEM) |

### Step 5 — Make failures visible (recommended)

- **Alert rule**: Azure portal → your Automation account → **Monitor → Alerts → Add alert rule** → signal *Scheduled job run failures* → action group with your email/Teams. Any real sync error now pages you instead of failing silently.
- **License check**: Intune admin center → confirm Remediations licensing for your user/device groups (see Minimum Requirements).

### Step 6 — First real cycle

Nothing else to do — from here the pipeline runs itself:

1. Devices report update/app failures to Intune as usual.
2. Nightly at **06:00** both runbooks fetch the failure reports, group the failing devices into the matching `Intune-*Error-*` groups, and remove devices whose error cleared.
3. Intune (on its own schedule) runs the per-code detection on each group's members; non-compliant devices get the remediation executed as SYSTEM.
4. The Intune **Remediation reports** show per-device outcomes (`Verified|…`, `Failed|…`); group sizes in Entra mirror current failures per code.

Optional day-1 sanity check — dry-run the runbooks locally (reads only, writes nothing):

```powershell
powershell -ExecutionPolicy Bypass -File .\IntuneUpdateErrorGroups-Local.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File .\App\IntuneAppErrorGroups-Local.ps1 -DryRun
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `az` not recognized after install | Open a **new** command window (PATH refreshed) and re-run `Install.cmd` |
| Consent error `AADSTS65001` / no browser appears | Run step 2's command manually in your own PowerShell window and click **Accept** on the consent prompt, then re-run |
| Wrong tenant deployed | `az login --tenant <guid>` (or `-ExpectedTenantId <guid>` to make the script refuse mismatches), re-run — idempotent |
| Automation job *Failed* | Job output contains the summary line and the exact Graph error; re-run the deploy/runbook, it is safe |
| 403 on app reports | `DeviceManagementApps.Read.All` grant missing — re-run `Deploy-Azure.ps1` (it re-asserts roles) |
| Devices never enter groups | Confirm devices are Entra joined + MDM-enrolled, and that a *real* failure exists for them; groups only fill from live Intune reports |
| Remediation never executes | Licensing (E3/E5/A3/A5/VDA) or the assignment is inactive — check Intune → Remediations → Status |

---

## Files

### Shared Infrastructure
| File | Purpose |
|---|---|
| `Install.cmd` | One-click setup: checks/installs Azure CLI, signs in, runs both deploy scripts, prints a portal checklist |
| `Deploy-Azure.ps1` | Creates the Azure Automation infrastructure (resource group, account + identity, 5 Graph roles, runbooks, schedule, dry-run proof jobs) |
| `Deploy-ErrorGroupsAndRemediations.ps1` | Creates all error-code groups + one baked Intune remediation per code, assigned to its group; tenant auto-detected from `az` (or `-TenantId`) |
| `IntuneUpdateErrorGroups.ps1` | Azure Automation runbook for patch errors (single source of truth) |
| `IntuneUpdateErrorGroups-Local.ps1` | Thin local wrapper: interactive Graph login, runs the main runbook |
| `App\IntuneAppErrorGroups.ps1` | Azure Automation runbook for app errors (single source of truth) |
| `App\IntuneAppErrorGroups-Local.ps1` | Thin local wrapper: interactive Graph login, runs the main runbook |
| `AZURE-AUTOMATION-SETUP.md` | Deep-dive setup guide for Azure Automation + Graph permissions |

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

### Tests & Docs
| File | Purpose |
|---|---|
| `Tests\Run-Tests.ps1` | Offline suite (57 assertions): parse checks, Graph pagination/retry/$batch, membership diff, detection helpers. No tenant needed |
| `Tests\Build-Presentation.py` / `Build-Poster.py` | Regenerate `IntunePatchPal-Presentation.pptx` (26 slides, incl. core-functions walkthrough) and `IntunePatchPal-Poster.pptx` |
| `poster.svg` / `Workflow-Animated.svg` | Full pipeline diagram, animated flow chart (open in a browser) |

---

## Runbook Parameters

| Parameter | Scripts | Effect |
|---|---|---|
| `-DryRun` | all runbooks | Preview every create/add/remove/delete without writing |
| `-Interactive` | main runbooks only | Sign in with the signed-in user (used by the `-Local` wrappers) |
| `-TenantId <id>` | `-Local` wrappers, groups deploy | Target a specific Entra tenant when interactive |
| `-CleanupOrphanedGroups` | all runbooks | Delete automation-marked groups whose error code no longer occurs (default: just empty them) |
| `-GroupPrefix <prefix>` | all runbooks | Override `Intune-PatchError` / `Intune-AppError` |
| `-AppFilter <text>` | app runbook | Only scan apps whose display name matches |
| `-Lane Patch\|App`, `-SkipRemediations` | groups deploy | Limit creation to one lane, or groups only (no Intune packages) |
| `-SubscriptionId`, `-Location`, `-TimeZone`, `-ScheduleHour`, `-ExpectedTenantId` | `Deploy-Azure.ps1` | Name/region/timezone overrides; refuse wrong-tenant deploys |

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
