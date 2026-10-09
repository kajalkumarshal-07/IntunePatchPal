# Intune App Install Error Codes & Remediation Reference

## Graph API Endpoint

```
POST /beta/deviceManagement/reports/retrieveDeviceAppInstallationStatusReport
body: {"filter":"(ApplicationId eq '{appId}')","top":1000,"skip":0}

Rows are filtered client-side on AppInstallState (failed/error) or a
non-zero ErrorCode. (The old mobileApps/{appId}/deviceStatuses GET was
retired from Graph.)
```

## Error Code Reference

### MSI Installer Errors

| Error Code | Hex | Description | Detection | Remediation |
|---|---|---|---|---|
| `1601` | `0x00000641` | Windows Installer service failed | `Get-Service msiserver \| Select-Object Status` | `Start-Service msiserver` |
| `1602` | `0x00000642` | User cancelled installation | Usually user-initiated | No remediation needed. Re-deploy app. |
| `1603` | `0x00000643` | Fatal error during installation | Check MSI log for detailed failure | Restart msiexec, run DISM /RestoreHealth, retry |
| `1618` | `0x00000652` | Another install already running | Get-Process msiexec -Count > 1 | Wait or kill stale msiexec, then retry |
| `1619` | `0x00000653` | Package cannot be opened | File path invalid or corrupted | Re-download/assign the app in Intune |
| `1620` | `0x00000654` | Package is invalid | MSI file corrupted | Re-upload the app package to Intune |
| `1623` | `0x00000657` | Language not supported | `Get-WinSystemLocale` mismatch | Change system locale or get localized package |
| `1625` | `0x00000659` | Package rejected by system | Group policy blocks install | Check `DisableMSI` GPO, software restriction policies |
| `1632` | `0x00000660` | Temp directory unwritable | Test-Path $env:TEMP accessibility | clear $env:TEMP, check disk space |
| `1633` | `0x00000661` | Platform unsupported | 32-bit app on 64-bit only config | Fix detection/requirement rules in Intune |
| `1638` | `0x00000666` | Product version conflict | `Get-WmiObject Win32_Product` shows same version | Uninstall old version before deploying |
| `1639` | `0x00000667` | Invalid command line | Wrong args passed to msiexec | Fix install command in Intune app config |
| `1641` | `0x00000669` | Reboot initiated | `PendingFileRenameOperations` set | `Restart-Computer -Force` |
| `1642` | `0x0000066A` | Patch target not found | Required base MSI not installed | Deploy base app first, then patch |

### Win32 App (Intune) Errors

| Error Code | Hex | Description | Detection | Remediation |
|---|---|---|---|---|
| `-2016281111` | `0x87D10419` | Detection script returned not installed | Run detection script manually | Fix detection logic (file path, version, registry) |
| `-2016344807` | `0x87D30079` | Requirement rule not met | Check OS, architecture, disk space | Adjust requirement rules in Intune |
| `-2016281109` | `0x87D1041B` | Script execution failed | Script syntax/path issue | Test script locally, check execution policy |
| `-2016281112` | `0x87D1041C` | Script execution timed out | Script taking >30 min | Simplify install script, avoid sync waits |
| `-2016281113` | `0x87D1041D` | File path not found | Detection file missing | Update detection path in Intune |
| `-2016281114` | `0x87D1041E` | Registry key not found | Detection reg key missing | Update detection reg path in Intune |

### System Errors

| Error Code | Hex | Description | Detection | Remediation |
|---|---|---|---|---|
| `-2147024784` | `0x80070070` | Not enough disk space | `$disk.FreeSpace -lt 5GB` | Run cleanmgr, clean WinSxS, remove temp files |
| `-2147021879` | `0x800704DD` | Reboot pending | PendingFileRenameOperations | Restart-Computer -Force |
| `-2147024894` | `0x80070002` | File not found | Install source file missing | Check Intune app source path |
| `-2147024891` | `0x80070008` | Not enough memory | FreePhysicalMemory < 1MB | Close services, increase page file |

## Universal App Remediation

```powershell
Stop-Service msiserver -Force -ErrorAction SilentlyContinue
Start-Service msiserver
Remove-Item "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
DISM /Online /Cleanup-Image /RestoreHealth
```

## Permissions Required

Graph API permissions for the runbook:
- `DeviceManagementApps.Read.All`
- `DeviceManagementManagedDevices.Read.All`
- `Group.ReadWrite.All`
- `Directory.Read.All`
