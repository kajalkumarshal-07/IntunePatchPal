# Intune Proactive Remediation Templates

## How Proactive Remediations Work

| Script exit code | Status                    |
|------------------|---------------------------|
| 0                | Compliant (no action)     |
| 1 (or non-zero)  | Non-compliant (remediate) |

## Deployment in Intune

1. Go to **Endpoint Manager > Devices > Scripts and remediations**
2. Click **Create > Proactive Remediation**
3. Fill in Name/Description
4. **Detection script**: Upload `DetectionTemplate.ps1`
5. **Remediation script**: Upload `RemediationTemplate.ps1`
6. Set **Run this script using the logged on credentials** (usually No for system context)
7. Schedule **Frequency** and **Grace period**
8. Assign to device groups

## Customizing

Edit the section between `--- CUSTOM DETECTION LOGIC ---` and `--- END CUSTOM LOGIC ---` in both scripts.

### Common detection patterns:

- **Registry check**: `Get-ItemProperty -Path "HKLM:\SOFTWARE\..." -Name "Version" -ErrorAction SilentlyContinue`
- **File version**: `(Get-Item "C:\Program Files\...\app.exe").VersionInfo.FileVersion`
- **Service state**: `Get-Service "wuauserv" | Select-Object -ExpandProperty Status`
- **WMI query**: `Get-CimInstance -ClassName Win32_QuickFixEngineering`

### Remediation notes

- Scripts run as **SYSTEM** by default (no user interaction)
- Use `start-process -WindowStyle Hidden` for silent installers
- Logging goes to `%TEMP%\IntuneDetection.log` / `IntuneRemediation.log`
