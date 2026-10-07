#Requires -Version 5.1
<#
    Proactive Remediation script (app installation errors).

    Exit codes (Intune contract): 0 = remediation succeeded (or nothing to
    do), 1 = remediation failed (Intune shows it in the remediation report).

    Hardening notes (prod readiness):
      - 1603 no longer force-kills every msiexec (that aborts healthy
        installs) - only installs stuck over 30 minutes, and never
        unrelated DISM runs
      - Report-only codes (1638, -2016xxxxx, -2147024894) write guidance
        to the Intune remediation output instead of mutating the device
      - -2016281109 no longer flips the machine's execution policy (IME
        bypasses it anyway, so the change never fixes the error)
      - Temp cleanup only touches files older than 24h
      - Post-action verification: Verified/Unknown exits 0, Failed exits 1
#>
param(
    [string]$ErrorCode = "",
    [switch]$AutoDetect
)

$ErrorActionPreference = "Stop"
$logFile = "$env:TEMP\IntuneAppRemediation.log"
$minFreeDiskBytes = 5GB
$staleMsiMinutes = 20
$killMsiMinutes = 30

$script:AppliedCode = ""

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $logFile -Append
}

function Exit-Success {
    param([string]$Detail = "")
    if ($Detail) { Write-Log "Remediation completed: $Detail" } else { Write-Log "Remediation completed" }
    exit 0
}

function Exit-Failure {
    param([string]$Reason)
    Write-Log "Remediation failed: $Reason"
    Write-Output "Failed|$Reason"
    exit 1
}

function Clear-AgedTempFiles {
    foreach ($root in @($env:TEMP, "$env:WINDIR\Temp")) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem -Path $root -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-PendingReboot {
    $sm = Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    if ($sm) {
        $rename = $sm.GetValue('PendingFileRenameOperations', $null)
        $hasRename = ($rename -is [array] -and $rename.Count -gt 0) -or ($rename -isnot [array] -and $rename)
        if ($hasRename) { return $true }
    }
    $au = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update' -Name RebootRequired -ErrorAction SilentlyContinue
    if ($au -and $au.RebootRequired) { return $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
    return $false
}

function Test-StaleInstaller {
    $procs = @(Get-Process msiexec -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $null }
    if ($procs.Count -gt 4) { return "Abnormal msiexec process count: $($procs.Count)" }
    $oldest = ($procs | Sort-Object StartTime | Select-Object -First 1).StartTime
    $age = (Get-Date) - $oldest
    if ($age.TotalMinutes -gt $staleMsiMinutes) {
        return "msiexec running for $([math]::Round($age.TotalMinutes)) min"
    }
    return $null
}

function Test-TempWritable {
    try {
        $tempPath = [System.IO.Path]::GetTempPath()
        $testFile = Join-Path $tempPath "intune_app_test_$PID.tmp"
        [System.IO.File]::WriteAllText($testFile, "test")
        [System.IO.File]::Delete($testFile)
        return $null
    }
    catch { return "Temp dir not writable: $tempPath ($_)" }
}

function Invoke-Remediation {
    param([string]$Code)
    Write-Log "Running remediation for error code: $Code"
    $script:AppliedCode = $Code

    switch ($Code) {

        '-2147024784' {
            Write-Log "Freeing disk space (age-limited cleanup)"
            Clear-AgedTempFiles
            Remove-Item "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
        }

        '-2147021879' {
            Write-Log "Reboot required - reporting only"
            Write-Output "RebootRequired|Reboot is pending. No reboot forced (org policy)."
        }

        '1641' {
            Write-Log "Installer requested reboot - reporting only"
            Write-Output "RebootRequired|Installer requested a reboot. No reboot forced (org policy)."
        }

        '1602' {
            Write-Log "User cancelled the install - no device action (re-assign if unexpected)"
            Write-Output "UserCancelled|No device fix - re-assign the app if this was not user-initiated"
        }

        '1603' {
            Write-Log "Fatal install error - clearing stale installers only"
            $stale = @(Get-Process msiexec -ErrorAction SilentlyContinue |
                Where-Object { $_.StartTime -lt (Get-Date).AddMinutes(-$killMsiMinutes) })
            if ($stale.Count -gt 0) {
                $stale | Stop-Process -Force -ErrorAction SilentlyContinue
                Write-Output "Killed $($stale.Count) msiexec process(es) older than $killMsiMinutes min"
            }
            Clear-AgedTempFiles
            Write-Output "FatalInstallError|Stale installers cleared. Check the app's MSI log for the root cause."
        }

        '1618' {
            Write-Log "Another install running - waiting up to 15 min"
            $waitStart = Get-Date
            while ((Get-Process msiexec -ErrorAction SilentlyContinue) -and ((Get-Date) - $waitStart).TotalMinutes -lt 15) {
                Write-Log "Waiting for msiexec to finish..."
                Start-Sleep -Seconds 30
            }
            $stillRunning = @(Get-Process msiexec -ErrorAction SilentlyContinue)
            if ($stillRunning.Count -gt 0) {
                $killed = $stillRunning | Where-Object { $_.StartTime -lt (Get-Date).AddHours(-1) }
                if ($killed) {
                    $killed | Stop-Process -Force -ErrorAction SilentlyContinue
                    Write-Output "Timed out waiting - killed $($killed.Count) msiexec process(es) older than 1h"
                }
                else {
                    Write-Output "Install still in progress after 15 min but no process is older than 1h - left running"
                }
            }
        }

        '1619' {
            Write-Log "Package cannot be opened - verifying temp access"
            Clear-AgedTempFiles
            $issue = Test-TempWritable
            if ($issue) { Write-Output "PackageOpenFailed|$issue" }
            else { Write-Output "PackageOpenFailed|Local temp is fine - the package/source path is wrong or corrupt. Re-upload the app in Intune." }
        }

        '1632' {
            Write-Log "Temp directory unwritable - clearing aged temp files"
            Clear-AgedTempFiles
        }

        '1638' {
            Write-Log "Product version conflict - report only"
            Write-Output "ProductVersionConflict|Report only - uninstall the conflicting version or fix supersede rules in Intune."
        }

        '1642' {
            Write-Log "Patch target not found - report only"
            Write-Output "PatchTargetNotFound|Report only - deploy the base app before the patch."
        }

        '-2016281111' {
            Write-Log "Detection reported not installed - report only"
            Write-Output "DetectionMismatch|Report only - verify detection script (file/registry/version) manually."
        }

        '-2016344807' {
            Write-Log "Requirement rule not met - report only"
            $os = Get-CimInstance Win32_OperatingSystem
            Write-Output "RequirementNotMet|Report only - OS: $($os.Caption) Build: $($os.BuildNumber). Fix the requirement rule in Intune."
        }

        '-2016281109' {
            Write-Log "Script execution failed - report only (execution policy is intentionally untouched)"
            Write-Output "ScriptFailed|Report only - test the script locally; check UTF-8 encoding and syntax. Intune bypasses execution policy, so it is not the cause."
        }

        '-2016281112' {
            Write-Log "Script timed out - report only"
            Write-Output "ScriptTimedOut|Report only - the Intune script timeout is 30 min; simplify the install script."
        }

        '-2016281113' {
            Write-Log "Detection file path not found - report only"
            Write-Output "FilePathNotFound|Report only - the detection file path does not exist on the device."
        }

        '-2016281114' {
            Write-Log "Detection registry path not found - report only"
            Write-Output "RegistryKeyNotFound|Report only - the detection registry path does not exist on the device."
        }

        '-2147024894' {
            Write-Log "Source file missing - report only"
            Write-Output "FileNotFound|Report only - the install source is missing or the path is wrong; re-check the Intune app content."
        }

        '-2147024891' {
            Write-Log "Low memory - reporting top consumers only (no service is stopped)"
            $top = (Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 |
                ForEach-Object { "$($_.Name) $([math]::Round($_.WorkingSet64/1MB))MB" }) -join ", "
            Write-Output "LowMemory|top=$top"
        }

        default {
            Exit-Failure "No remediation defined for $Code"
        }
    }
}

function Get-RemediationOutcome {
    param([string]$Code)
    switch ($Code) {
        '-2147024784' {
            $d = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3 AND DeviceID='C:'"
            if ($d.FreeSpace -ge $minFreeDiskBytes) {
                return [pscustomobject]@{ State = "Verified"; Detail = "free space now $([math]::Round($d.FreeSpace/1GB,2)) GB" }
            }
            return [pscustomobject]@{ State = "Failed"; Detail = "still low on disk space: $([math]::Round($d.FreeSpace/1GB,2)) GB" }
        }
        '1632' {
            $issue = Test-TempWritable
            if (-not $issue) { return [pscustomobject]@{ State = "Verified"; Detail = "temp dir writable" } }
            return [pscustomobject]@{ State = "Failed"; Detail = $issue }
        }
        '1618' {
            $stale = Test-StaleInstaller
            if (-not $stale) { return [pscustomobject]@{ State = "Verified"; Detail = "no stale installer" } }
            return [pscustomobject]@{ State = "Failed"; Detail = $stale }
        }
        { $_ -in @('-2147021879', '1641') } {
            return [pscustomobject]@{ State = "Unknown"; Detail = "reboot pending - reported, not forced" }
        }
        default {
            return [pscustomobject]@{ State = "Unknown"; Detail = "action taken; no automated verification for $Code" }
        }
    }
}

# Dot-sourcing only loads the functions (tests); execution requires -File.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    Write-Log "App remediation started (code='$ErrorCode', auto=$AutoDetect)"
    if ($AutoDetect) {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3 AND DeviceID='C:'"
        if (Test-PendingReboot) { Invoke-Remediation '-2147021879' }
        elseif (Test-StaleInstaller) { Invoke-Remediation '1618' }
        elseif (Test-TempWritable) { Invoke-Remediation '1632' }
        elseif ($disk.FreeSpace -lt $minFreeDiskBytes) { Invoke-Remediation '-2147024784' }
        else { Exit-Success "Auto-detect found no known issue" }
    }
    elseif ($ErrorCode) {
        Invoke-Remediation $ErrorCode
    }
    else {
        Exit-Failure "No error code given"
    }

    $outcome = Get-RemediationOutcome -Code $script:AppliedCode
    Write-Output "$($outcome.State)|$($outcome.Detail)"
    if ($outcome.State -eq "Failed") { Exit-Failure $outcome.Detail }
    Exit-Success "$($outcome.State): $($outcome.Detail)"
}
catch {
    Write-Log "Remediation error: $_"
    Exit-Failure "$_"
}
