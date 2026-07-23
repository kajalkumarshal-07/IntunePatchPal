# Intune Patch Error Codes & Remediation Reference

## Detection Script Template

Use this detection logic in your Proactive Remediation detection script:

```powershell
$errorCode = (Get-CimInstance -ClassName Win32_QuickFixEngineering | ...).ReturnValue
# or check WindowsUpdate.log / CBS.log for specific error patterns
```

## Error Code Reference

### Disk & Resource Errors

| Error Code | Hex | Description | Detection | Remediation Script |
|---|---|---|---|---|
| `-2147024784` | `0x80070070` | Not enough disk space | `Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" \| Where-Object { $_.FreeSpace -lt 5GB }` | `cleanmgr /sageset:1` then `cleanmgr /sagerun:1`, remove temp files: `Get-ChildItem "$env:TEMP" -Recurse \| Remove-Item -Force`, clean WinSxS: `DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase` |
| `-2147024891` | `0x80070008` | Not enough memory | Check available RAM: `(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory` | Close non-essential services, increase page file: `wmic computersystem set AutomaticManagedPagefile=False` then set custom size. Reboot if needed. |
| `-2147023890` | `0x80070570` | Corrupted file/disk | `chkdsk /f` required | Schedule `chkdsk C: /f /r`, reboot to run. Then retry updates. |

### Component Store & System Corruption

| Error Code | Hex | Description | Detection | Remediation Script |
|---|---|---|---|---|
| `-2147010798` | `0x80073712` | Component store corrupted | `DISM /Online /Cleanup-Image /CheckHealth` exits non-zero | `DISM /Online /Cleanup-Image /RestoreHealth` then `SFC /ScanNow`. If fails, use `DISM /Online /Cleanup-Image /RestoreHealth /Source:C:\RepairSource\Windows /LimitAccess` |
| `-2147010815` | `0x80073701` | Assembly not found | CBS.log parsing for missing manifests | Run `DISM /Online /Cleanup-Image /RestoreHealth`. If .NET-related, run `dism /online /enable-feature /featurename:NetFx3 /all` or reinstall .NET via `winget install Microsoft.DotNet.*` |
| `-2147010893` | `0x8007371B` | Assembly not installed | CBS.log check for installation failures | Same as above + `sfc /scannow`. For specific packages, use `dism /online /get-packages` to find and reinstall. |

### Network & Connectivity

| Error Code | Hex | Description | Detection | Remediation Script |
|---|---|---|---|---|
| `-2147023436` | `0x800705B4` | Operation timed out | Test network to WSUS/WU: `Test-NetConnection -ComputerName (Get-ItemProperty "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate").WUServer` | Restart BITS service `Restart-Service bits`, clear SoftwareDistribution: `Stop-Service wuauserv bits; Remove-Item "$env:windir\SoftwareDistribution\*" -Recurse; Start-Service wuauserv bits`. Check proxy: `netsh winhttp show proxy`. |
| `-2147012886` | `0x80072EEF` | Unknown name (DNS failure) | `Resolve-DnsName (Get-ItemProperty "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate").WUServer` | Flush DNS: `ipconfig /flushdns; ipconfig /registerdns`. Check hosts file. Set alternate DNS: `netsh interface ip set dns "Ethernet" static 8.8.8.8` |
| `-2147012855` | `0x80072EE2` | Network timeout | `Invoke-WebRequest -Uri "https://ctldl.windowsupdate.com" -TimeoutSec 10` fails | Restart network adapter: `Restart-NetAdapter -Name "Ethernet"`. Reset winsock: `netsh winsock reset`. Check firewall rules for Windows Update. |
| `-2147012867` | `0x80072EFD` | Connection to server failed | Port test to WSUS 8530/443 fails | Check WSUS URL in registry. Verify firewall allows outbound 443/80/8530. Restart `Restart-Service wuauserv`. |
| `-2147024809` | `0x80070057` | Bad parameter / corrupt metadata | Update catalog integrity check | Clear `SoftwareDistribution`, re-register WU: `regsvr32 /s wuapi.dll; regsvr32 /s wups.dll; regsvr32 /s wuwebv.dll`. Then `wuauclt /resetauthorization /detectnow` |

### Policy & Configuration

| Error Code | Hex | Description | Detection | Remediation Script |
|---|---|---|---|---|
| `-2145107951` | `0x80245011` | WUServer policy missing | `Get-ItemProperty "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate" -ErrorAction SilentlyContinue` is null | Apply GPO: `gpupdate /force`. If no GPO, set manual: `New-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate" -Name "WUServer" -Value "http://wsus:8530"`. Restart `wuauserv`. |
| `-2145124320` | `0x80280020` | No interactive user (scan failed) | Check if device is on AC power and connected | Usually transient. Ensure device is not in sleep mode: `powercfg /change standby-timeout-ac 0`. Retry scan: `wuauclt /detectnow`. |
| `-2145124341` | `0x80280013` | Operation cancelled | Check WU history for cancelled state | Clear WU cache: `Stop-Service wuauserv; Remove-Item "$env:windir\SoftwareDistribution\*" -Recurse; Start-Service wuauserv`. Resync: `wuauclt /resetauthorization /detectnow`. |
| `-2016409966` | `0x878A002A` | Group policy conflict (SCCM) | Multiple WU GPOs detected | Audit applied GPOs: `gpresult /h C:\gpreport.html`. Ensure only one source manages WU (GPO OR Intune OR SCCM, not mixed). Remove conflicting registry keys under `HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate`. |
| `-2146777998` | `0x8024044E` | WU registry value corrupt | WU registry key permissions incorrect | Reset WU registry: `reg delete HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate /v AccountDomainSid /f`. Re-register WU components. |

### Update Execution

| Error Code | Hex | Description | Detection | Remediation Script |
|---|---|---|---|---|
| `-2147021879` | `0x800704DD` | Reboot required | Check `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations` or `Get-WURebootStatus` | `Restart-Computer -Force`. After reboot, verify pending operations cleared. |
| `-2016409844` | `0x878A0018` | Update execution timeout (SCCM) | Check `C:\Windows\CCM\Logs\UpdatesDeployment.log` for timeout errors | Increase deadline in Intune/SCCM. On client: ensure no other installers running. Check `msiexec` processes. |
| `-2016410008` | `0x878A0030` | Update still actionable after apply | CBS.log shows update applied but still detected | Run `DISM /Online /Cleanup-Image /ScanHealth`. For specific KB, run `wusa /uninstall /kb:XXXXX` then reinstall. Check CBS pending operations. |
| `-2145124305` | `0x8028001F` | Download failed | WU failed to download payload | Check disk space. Restart BITS: `Stop-Service bits; Remove-Item "$env:ProgramData\Microsoft\Network\Downloader\*" -Recurse; Start-Service bits`. Check connectivity. |
| `-2145124323` | `0x8024001D` | WU error: corrupt download | WU state corrupt | `wuauclt /resetauthorization /detectnow`. If persists: `netsh winhttp reset proxy`. |

### Generic / Unknown

| Error Code | Hex | Description | Detection | Remediation Script |
|---|---|---|---|---|
| `-2147467259` | `0x80004005` | Unspecified error | Check CBS.log + WindowsUpdate.log for root cause | Run `DISM /Online /Cleanup-Image /RestoreHealth`. Check event logs: `Get-WinEvent -LogName "System" -MaxEvents 50 \| Where-Object { $_.LevelDisplayName -eq "Error" }`. Retry after full reset: clear SfCDownloads, re-register WU DLLs. |
| `-2147467260` | `0x80004004` | Operation aborted | Usually transient, retry | `wuauclt /detectnow` in a loop with retry logic. If persistent, clear SfCDownloads: `Remove-Item "$env:windir\Winsxs\pending.xml" -ErrorAction SilentlyContinue`. |
| `-2016410012` | `0x878A003C` | Updates handler cancelled | User or policy cancelled | Check `UpdatesDeployment.log`. No action needed unless persistent. Ensure deployments are not being expired early. |
| `-2016410026` | `0x878A0046` | Internal updates handler error | Generic handler failure | Restart `CcmExec`: `Restart-Service ccmexec`. Clear `CCM\Cache`: `Remove-Item "$env:windir\CCM\Cache\*" -Recurse`. Force policy refresh: `Invoke-WmiMethod -Namespace root\ccm -Class SMS_CLIENT -Name TriggerSchedule "{00000000-0000-0000-0000-000000000114}"`. |

## Universal Remediation (first-line)

This remediation targets all errors with a general reset:

```powershell
# Universal remediation - run this first, then re-evaluate
Stop-Service wuauserv, bits, cryptsvc -Force
Remove-Item "$env:windir\SoftwareDistribution\*" -Recurse -Force
Remove-Item "$env:windir\System32\catroot2\*" -Recurse -Force
Start-Service wuauserv, bits, cryptsvc
DISM /Online /Cleanup-Image /RestoreHealth
SFC /ScanNow
wuauclt /resetauthorization /detectnow
```

## Wrapping in Detection Script Logic

```powershell
# Detection: does this error code apply to this device?
$errorCodes = @{
  '-2147024784' = 'DiskSpace'
  '-2147021879' = 'RebootPending'
  '-2147010798' = 'CorruptComponentStore'
}

# Map error → remediation script name to deploy
```

In Intune Proactive Remediations, create one remediation per error code or a single remediation that handles all via detection context.
