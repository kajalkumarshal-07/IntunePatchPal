param(
    [string]$TargetErrorCode = ""
)

$ErrorActionPreference = "Stop"
$logFile = "$env:TEMP\IntuneDetection.log"

$ErrorCodeMap = @{
    '-2147024784' = 'DiskSpace'
    '-2147021879' = 'RebootPending'
    '-2147010798' = 'CorruptComponentStore'
    '-2147023436' = 'WUTimeout'
    '-2145107951' = 'WUServerMissing'
    '-2147012886' = 'DNSFailure'
    '-2147012855' = 'NetworkTimeout'
    '-2147012867' = 'ServerConnectionFailed'
    '-2145124320' = 'NoInteractiveUser'
    '-2145124341' = 'OperationCancelled'
    '-2147467259' = 'UnspecifiedError'
    '-2147467260' = 'OperationAborted'
    '-2016409844' = 'ExecutionTimeout'
    '-2147024891' = 'LowMemory'
    '-2016409966' = 'PolicyConflict'
    '-2145124305' = 'DownloadFailed'
    '-2146777998' = 'WURegistryCorrupt'
    '-2147023890' = 'CorruptDisk'
    '-2147010815' = 'AssemblyNotFound'
    '-2147024809' = 'CorruptMetadata'
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $logFile -Append
}

function Exit-Compliant {
    Write-Log "Compliant - no remediation needed"
    exit 0
}

function Exit-NonCompliant {
    param([string]$Code, [string]$Reason)
    Write-Log "Non-compliant: $Reason (code: $Code)"
    Write-Output "Non-compliant|$Code|$Reason"
    exit 1
}

try {
    Write-Log "Detection started"
    $os = Get-CimInstance Win32_OperatingSystem
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3 AND DeviceID='C:'"

    if ($TargetErrorCode) {
        switch ($TargetErrorCode) {
            '-2147024784' {
                if ($disk.FreeSpace -lt 5GB) { Exit-NonCompliant $TargetErrorCode "Free space: $([math]::Round($disk.FreeSpace/1GB,2)) GB" }
            }
            '-2147021879' {
                $pending = Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations"
                if ($pending) { Exit-NonCompliant $TargetErrorCode "Pending file rename operations exist" }
                $pendingReboot = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" -Name RebootRequired -ErrorAction SilentlyContinue
                if ($pendingReboot) { Exit-NonCompliant $TargetErrorCode "Windows Update reports reboot required" }
            }
            '-2147010798' {
                $health = DISM /Online /Cleanup-Image /CheckHealth | Select-String "component store corrupt"
                if ($health) { Exit-NonCompliant $TargetErrorCode "Component store is corrupt" }
            }
            '-2145107951' {
                $wuKey = Get-ItemProperty "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate" -Name WUServer -ErrorAction SilentlyContinue
                if (-not $wuKey) { Exit-NonCompliant $TargetErrorCode "WUServer policy is missing" }
            }
            '-2147023436' {
                $bits = Get-Service bits -ErrorAction SilentlyContinue
                if ($bits.Status -ne 'Running') { Exit-NonCompliant $TargetErrorCode "BITS service is not running" }
            }
            '-2147012886' {
                $wuServer = (Get-ItemProperty "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate" -Name WUServer -ErrorAction SilentlyContinue).WUServer
                if ($wuServer) {
                    try { Resolve-DnsName ($wuServer -replace 'https?://' -replace '/.*') -ErrorAction Stop } catch { Exit-NonCompliant $TargetErrorCode "DNS resolution failed for: $wuServer" }
                }
            }
            '-2147024891' {
                if ($os.FreePhysicalMemory -lt 1MB) { Exit-NonCompliant $TargetErrorCode "Low physical memory: $($os.FreePhysicalMemory) KB" }
            }
            '-2145124305' {
                $bitsJobs = Get-BitsTransfer -ErrorAction SilentlyContinue | Where-Object { $_.JobState -eq 'Error' }
                if ($bitsJobs) { Exit-NonCompliant $TargetErrorCode "BITS jobs in error state" }
            }
            '-2147023890' {
                $chkdskPending = Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations"
                $volumeDirty = (Get-CimInstance Win32_Volume -Filter "DriveLetter='C:'").DirtyBitSet
                if ($volumeDirty) { Exit-NonCompliant $TargetErrorCode "Volume is dirty, chkdsk required" }
            }
            default { Exit-Compliant }
        }
        Exit-Compliant
    }

    Write-Log "No target error code specified. Running full scan..."

    $pendingReboot = Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations"
    if ($pendingReboot) {
        Exit-NonCompliant '-2147021879' "Pending reboot detected"
    }

    if ($disk.FreeSpace -lt 5GB) {
        Exit-NonCompliant '-2147024784' "Low disk space: $([math]::Round($disk.FreeSpace/1GB,2)) GB free"
    }

    if ($os.FreePhysicalMemory -lt 1MB) {
        Exit-NonCompliant '-2147024891' "Low memory: $($os.FreePhysicalMemory) KB free"
    }

    $health = DISM /Online /Cleanup-Image /CheckHealth | Select-String "component store corrupt"
    if ($health) {
        Exit-NonCompliant '-2147010798' "Component store is corrupt"
    }

    $wuKey = Get-ItemProperty "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate" -Name WUServer -ErrorAction SilentlyContinue
    if (-not $wuKey) {
        Exit-NonCompliant '-2145107951' "WUServer policy is missing"
    }

    $bits = Get-Service bits -ErrorAction SilentlyContinue
    if ($bits.Status -ne 'Running') {
        Exit-NonCompliant '-2147023436' "BITS service is not running"
    }

    Exit-Compliant
}
catch {
    Write-Log "Detection error: $_"
    Write-Output "Error: $_"
    exit 1
}
