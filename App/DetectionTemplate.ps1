#Requires -Version 5.1
<#
    Proactive Remediation detection (app installation errors).

    Exit codes (Intune contract): 0 = compliant, 1 = non-compliant.

    Hardening notes (prod readiness):
      - Pending reboot reads the PendingFileRenameOperations VALUE
        (Test-Path on a registry value always returns False)
      - 1618 no longer uses "msiexec count > 1" (msiexec always runs as
        2+ processes per install); it flags *stale* installs (>20 min) or
        an abnormal process count (>4)
      - 1632 checks temp writability directly instead of a disk-space proxy
      - Report-only codes (1638, -2147024894) intentionally stay
        non-compliant so the remediation's guidance lands in the Intune
        report daily - they are packaging issues, not device issues
      - Detection errors exit 0 by default (a broken detection should not
        trigger fleet-wide remediation); use -Strict for exit 1
#>
param(
    [string]$TargetErrorCode = "",
    [switch]$Strict
)

$ErrorActionPreference = "Stop"
$logFile = "$env:TEMP\IntuneAppDetection.log"
$minFreeDiskBytes = 5GB
$minFreeMemKB = 262144   # 256 MB
$staleMsiMinutes = 20

$ErrorCodeMap = @{
    '1601'             = 'InstallServiceFailed'
    '1602'             = 'UserCancelled'
    '1603'             = 'FatalInstallError'
    '1618'             = 'AnotherInstallRunning'
    '1619'             = 'PackageOpenFailed'
    '1620'             = 'PackageInvalid'
    '1632'             = 'TempDirUnwritable'
    '1638'             = 'ProductVersionConflict'
    '1639'             = 'InvalidCommandLine'
    '1641'             = 'RebootRequired'
    '1642'             = 'PatchTargetNotFound'
    '-2016281111'      = 'DetectionScriptFailed'
    '-2016344807'      = 'RequirementNotMet'
    '-2016281109'      = 'ScriptExecutionFailed'
    '-2016281112'      = 'ScriptTimedOut'
    '-2016281113'      = 'FilePathNotFound'
    '-2016281114'      = 'RegistryKeyNotFound'
    '-2147024894'      = 'FileNotFound'
    '-2147024784'      = 'DiskSpace'
    '-2147021879'      = 'RebootPending'
    '-2147024891'      = 'LowMemory'
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $logFile -Append
}

function Exit-Compliant { Write-Log "Compliant"; exit 0 }

function Exit-NonCompliant {
    param([string]$Code, [string]$Reason)
    Write-Log "Non-compliant: $Reason (code: $Code)"
    Write-Output "Non-compliant|$Code|$Reason"
    exit 1
}

function Test-PendingReboot {
    # PendingFileRenameOperations is a registry VALUE, not a key -
    # Test-Path on a value always returns False.
    $sm = Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    if ($sm) {
        $rename = $sm.GetValue('PendingFileRenameOperations', $null)
        $hasRename = ($rename -is [array] -and $rename.Count -gt 0) -or ($rename -isnot [array] -and $rename)
        if ($hasRename) { return 'PendingFileRenameOperations set' }
    }
    $au = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update' -Name RebootRequired -ErrorAction SilentlyContinue
    if ($au -and $au.RebootRequired) { return 'WindowsUpdate RebootRequired value set' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return 'Component Based Servicing RebootPending key present' }
    return $null
}

function Test-StaleInstaller {
    # Returns a reason string when msiexec looks stuck, else $null.
    # A healthy install runs msiexec as 2-3 processes, so a plain count
    # > 1 false-positives on every active install.
    $procs = @(Get-Process msiexec -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $null }
    if ($procs.Count -gt 4) { return "Abnormal msiexec process count: $($procs.Count)" }
    $oldest = ($procs | Sort-Object StartTime | Select-Object -First 1).StartTime
    $age = (Get-Date) - $oldest
    if ($age.TotalMinutes -gt $staleMsiMinutes) {
        return "msiexec running for $([math]::Round($age.TotalMinutes)) min (>$staleMsiMinutes)"
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

# Dot-sourcing only loads the functions (tests); execution requires -File.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    Write-Log "App detection started (target='$TargetErrorCode')"
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3 AND DeviceID='C:'"
    $os = Get-CimInstance Win32_OperatingSystem

    if ($TargetErrorCode) {
        switch ($TargetErrorCode) {
            '-2147024784' { if ($disk.FreeSpace -lt $minFreeDiskBytes) { Exit-NonCompliant $TargetErrorCode "Free space: $([math]::Round($disk.FreeSpace/1GB,2)) GB" } }
            '-2147021879' { $r = Test-PendingReboot; if ($r) { Exit-NonCompliant $TargetErrorCode $r } }
            '1641'        { $r = Test-PendingReboot; if ($r) { Exit-NonCompliant $TargetErrorCode "Installer requested reboot: $r" } }
            '1618'        { $r = Test-StaleInstaller; if ($r) { Exit-NonCompliant $TargetErrorCode $r } }
            '1632'        { $r = Test-TempWritable; if ($r) { Exit-NonCompliant $TargetErrorCode $r } }
            '1638'        { Exit-NonCompliant $TargetErrorCode "Product version conflict (report-only - fix the app package)" }
            '-2147024894' { Exit-NonCompliant $TargetErrorCode "Source file missing (report-only - check app source)" }
            '-2147024891' { if ($os.FreePhysicalMemory -lt $minFreeMemKB) { Exit-NonCompliant $TargetErrorCode "Free memory: $([math]::Round($os.FreePhysicalMemory/1MB,0)) MB (threshold 256 MB)" } }
            default { Exit-Compliant }
        }
        Exit-Compliant
    }

    Write-Log "Running full scan for app install readiness..."

    $reason = Test-PendingReboot
    if ($reason) { Exit-NonCompliant '-2147021879' "Pending reboot detected ($reason)" }

    $stale = Test-StaleInstaller
    if ($stale) { Exit-NonCompliant '1618' $stale }

    if ($disk.FreeSpace -lt $minFreeDiskBytes) { Exit-NonCompliant '-2147024784' "Low disk: $([math]::Round($disk.FreeSpace/1GB,2)) GB" }

    if ($os.FreePhysicalMemory -lt $minFreeMemKB) { Exit-NonCompliant '-2147024891' "Low memory: $([math]::Round($os.FreePhysicalMemory/1MB,0)) MB (threshold 256 MB)" }

    $tempIssue = Test-TempWritable
    if ($tempIssue) { Exit-NonCompliant '1632' $tempIssue }

    Exit-Compliant
}
catch {
    Write-Log "Detection error: $_"
    Write-Output "DetectionError|$_"
    if ($Strict) { exit 1 }
    exit 0
}
