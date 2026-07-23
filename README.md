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
    └── Intune Proactive Remediations → targeted at each group
```

## Files

### Shared Infrastructure
| File | Purpose |
|---|---|
| `IntuneUpdateErrorGroups.ps1` | Azure Automation runbook for patch errors |
| `IntuneUpdateErrorGroups-Local.ps1` | Local test version for patch errors |
| `App\IntuneAppErrorGroups.ps1` | Azure Automation runbook for app errors |
| `App\IntuneAppErrorGroups-Local.ps1` | Local test version for app errors |
| `AZURE-AUTOMATION-SETUP.md` | Setup guide for Azure Automation + Graph permissions |

### Patch Remediation (Windows Updates)
| File | Purpose |
|---|---|
| `DetectionTemplate.ps1` | Scans for 20 patch error conditions. Exit 0=compliant, 1=needs fix |
| `RemediationTemplate.ps1` | Switch-based remediation for all patch error codes |
| `ERROR-REFERENCE.md` | Full error code + remediation reference for patches |

### App Remediation (Win32/MSI/Store Apps)
| File | Purpose |
|---|---|
| `App\DetectionTemplate.ps1` | Scans for common app install blockers |
| `App\RemediationTemplate.ps1` | Targeted remediation for app install errors |
| `App\ERROR-REFERENCE.md` | Full error code + remediation reference for apps |

### Poster
| File | Purpose |
|---|---|
| `poster.svg` | Full pipeline diagram + all error codes with remediations |

## Quick Start

```powershell
# 1. Test locally
.\IntuneUpdateErrorGroups-Local.ps1

# 2. Or for apps
.\App\IntuneAppErrorGroups-Local.ps1

# 3. Deploy detection/remediation scripts in Intune
#    as Proactive Remediations targeting the created AAD groups
```

## Proactive Remediation Contract

| Exit code | Status |
|---|---|
| 0 | Compliant (no action) |
| 1 | Non-compliant (remediation runs) |
