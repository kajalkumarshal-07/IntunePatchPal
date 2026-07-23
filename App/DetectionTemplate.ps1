param(
    [string]$TargetErrorCode = ""
)

$ErrorActionPreference = "Stop"
$logFile = "$env:TEMP\IntuneAppDetection.log"

$ErrorCodeMap = @{
    '1601' = 'InstallServiceFailed'
    '1602' = 'UserCancelled'
    '1603' = 'FatalInstallError'
    '1618' = 'AnotherInstallRunning'
    '1619' = 'PackageOpenFailed'
    '1620' = 'PackageInvalid'
    '1632' = 'TempDirUnwritable'
    '1638' = 'ProductVersionConflict'
    '1639' = 'InvalidCommandLine'
    '1641' = 'RebootRequired'
    '1642' = 'PatchTargetNotFound'
    '-2016281111' = 'DetectionScriptFailed'
    '-2016344807' = 'RequirementNotMet'
    '-2016281109' = 'ScriptExecutionFailed'
    '-2016281112' = 'ScriptTimedOut'
    '-2016281113' = 'FilePathNotFound'
    '-2016281114' = 'RegistryKeyNotFound'
    '-2147024894' = 'FileNotFound'
    '-2147024784' = 'DiskSpace'
    '-2147021879' = 'RebootPending'
    '-2147024891' = 'LowMemory'
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

try {
    Write-Log "App detection started"
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3 AND DeviceID='C:'"
    $os = Get-CimInstance Win32_OperatingSystem
    $pendingReboot = Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations"
    $msiRunning = Get-Process msiexec -ErrorAction SilentlyContinue

    if ($TargetErrorCode) {
        switch ($TargetErrorCode) {
            '-2147024784' { if ($disk.FreeSpace -lt 5GB) { Exit-NonCompliant $TargetErrorCode "Free space: $([math]::Round($disk.FreeSpace/1GB,2)) GB" } }
            '-2147021879' { if ($pendingReboot) { Exit-NonCompliant $TargetErrorCode "Pending reboot" } }
            '1618' { if (($msiRunning | Measure-Object).Count -gt 1) { Exit-NonCompliant $TargetErrorCode "Another msiexec instance running" } }
            '1632' { if ($disk.FreeSpace -lt 1GB) { Exit-NonCompliant $TargetErrorCode "Temp dir may be unwritable, free: $([math]::Round($disk.FreeSpace/1GB,2)) GB" } }
            '1638' { Exit-NonCompliant $TargetErrorCode "Product version conflict detected" }
            '-2147024894' { Exit-NonCompliant $TargetErrorCode "File not found during install" }
            '-2147024891' { if ($os.FreePhysicalMemory -lt 1MB) { Exit-NonCompliant $TargetErrorCode "Low memory" } }
            '1641' { if ($pendingReboot) { Exit-NonCompliant $TargetErrorCode "Reboot required by installer" } }
            default { Exit-Compliant }
        }
        Exit-Compliant
    }

    Write-Log "Running full scan for app install readiness..."

    if ($pendingReboot) { Exit-NonCompliant '-2147021879' "Pending reboot detected" }
    if (($msiRunning | Measure-Object).Count -gt 1) { Exit-NonCompliant '1618' "Another install already in progress" }
    if ($disk.FreeSpace -lt 5GB) { Exit-NonCompliant '-2147024784' "Low disk: $([math]::Round($disk.FreeSpace/1GB,2)) GB" }
    if ($os.FreePhysicalMemory -lt 1MB) { Exit-NonCompliant '-2147024891' "Low memory: $($os.FreePhysicalMemory) KB" }

    $tempPath = [System.IO.Path]::GetTempPath()
    $testFile = Join-Path $tempPath "intune_test.tmp"
    try { [System.IO.File]::WriteAllText($testFile, "test"); [System.IO.File]::Delete($testFile) }
    catch { Exit-NonCompliant '1632' "Temp directory is not writable: $tempPath" }

    Exit-Compliant
}
catch {
    Write-Log "Detection error: $_"
    Write-Output "Error: $_"
    exit 1
}
