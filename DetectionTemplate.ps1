#Requires -Version 5.1
<#
    Proactive Remediation detection (Windows Update / patch errors).

    Exit codes (Intune contract): 0 = compliant, 1 = non-compliant.

    Hardening notes (prod readiness):
      - Pending reboot now reads the PendingFileRenameOperations VALUE
        (Test-Path on a registry value always returns False)
      - Full scan runs only fast checks; DISM is opt-in (-IncludeSlowChecks)
        or targeted, so detection stays quick on every cycle
      - BITS check flags disabled service / errored jobs, not "not running"
        (BITS is Manual-start by design and idle most of the time)
      - WUServer check no longer flags cloud-only devices in full scan;
        targeted mode still flags it because the group assignment provides
        the "WSUS is expected" context
      - DISM result parsing tolerates exit codes + hex markers (locale-safe)
      - Detection errors exit 0 by default (a broken detection should not
        trigger fleet-wide remediation); use -Strict for exit 1
#>
param(
    [string]$TargetErrorCode = "",
    [switch]$RequireWUServer,
    [switch]$IncludeSlowChecks,
    [switch]$Strict
)

$ErrorActionPreference = "Stop"
$logFile = "$env:TEMP\IntuneDetection.log"
$minFreeDiskBytes = 5GB
$minFreeMemKB = 262144   # 256 MB - "critically low", not "under 1 GB"

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

function Test-PendingReboot {
    # Returns a reason string if a reboot is pending, otherwise $null.
    # NOTE: PendingFileRenameOperations is a registry VALUE, not a key -
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

function Get-WUServerPolicyState {
    $p = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate'
    $item = Get-ItemProperty $p -ErrorAction SilentlyContinue
    if (-not $item) { return @{ Present = $false; WUServer = $null; Partial = $false } }
    $server = $null
    if ($item.PSObject.Properties['WUServer']) { $server = $item.WUServer }
    $partial = (-not $server) -and (
        ($null -ne $item.PSObject.Properties['UseWUServer']) -or
        ($null -ne $item.PSObject.Properties['WUStatusServer'])
    )
    return @{ Present = $true; WUServer = $server; Partial = $partial }
}

function Test-ComponentStoreCorrupt {
    # SLOW (DISM). Locale-tolerant: exit code, hex marker, or positive text.
    # EAP is lowered for the native call so redirected stderr cannot become
    # a terminating error under $ErrorActionPreference = 'Stop' (PS 5.1).
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& dism.exe /Online /Cleanup-Image /CheckHealth 2>&1 | Out-String)
        $exit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prevEap }
    $corrupt = $false
    if ($out -match 'No component store corruption') {
        $corrupt = $false
    }
    elseif ($out -match '0x80073712|80073712|-2147010798|component store is corrupt') {
        $corrupt = $true
    }
    elseif ($exit -ne 0) {
        $corrupt = $true
    }
    $tail = (($out.Trim() -split "(`r`n|`n)") | Select-Object -Last 2) -join ' '
    return [pscustomobject]@{ Corrupt = $corrupt; ExitCode = $exit; Detail = $tail }
}

function Test-BitsProblem {
    # Returns a reason string if BITS is broken, otherwise $null.
    # BITS is Manual-start by design - "not running" is normal.
    $svc = Get-Service bits -ErrorAction SilentlyContinue
    if (-not $svc) { return 'BITS service missing' }
    if ($svc.StartType -eq 'Disabled') { return 'BITS service disabled' }
    $errJobs = @(Get-BitsTransfer -ErrorAction SilentlyContinue | Where-Object { $_.JobState -eq 'Error' })
    if ($errJobs.Count -gt 0) { return "BITS jobs in error state: $($errJobs.Count)" }
    return $null
}

# Dot-sourcing only loads the functions (tests); execution requires -File.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    Write-Log "Detection started (target='$TargetErrorCode')"
    $os = Get-CimInstance Win32_OperatingSystem
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3 AND DeviceID='C:'"

    if ($TargetErrorCode) {
        switch ($TargetErrorCode) {
            '-2147024784' {
                if ($disk.FreeSpace -lt $minFreeDiskBytes) { Exit-NonCompliant $TargetErrorCode "Free space: $([math]::Round($disk.FreeSpace/1GB,2)) GB" }
            }
            '-2147021879' {
                $reason = Test-PendingReboot
                if ($reason) { Exit-NonCompliant $TargetErrorCode $reason }
            }
            '-2147010798' {
                $check = Test-ComponentStoreCorrupt
                if ($check.Corrupt) { Exit-NonCompliant $TargetErrorCode "Component store corrupt (dism exit $($check.ExitCode)): $($check.Detail)" }
            }
            '-2145107951' {
                # Targeted mode = group assignment provides the "WSUS expected" context.
                $wu = Get-WUServerPolicyState
                if (-not $wu.WUServer) { Exit-NonCompliant $TargetErrorCode "WUServer policy is missing" }
            }
            '-2147023436' {
                $bits = Test-BitsProblem
                if ($bits) { Exit-NonCompliant $TargetErrorCode $bits }
            }
            '-2145124305' {
                $bits = Test-BitsProblem
                if ($bits) { Exit-NonCompliant $TargetErrorCode $bits }
            }
            '-2147012886' {
                $wu = Get-WUServerPolicyState
                if ($wu.WUServer) {
                    $target = ($wu.WUServer -replace '^https?://', '' -replace '/.*$', '' -replace ':\d+$', '')
                    try { Resolve-DnsName $target -ErrorAction Stop | Out-Null }
                    catch { Exit-NonCompliant $TargetErrorCode "DNS resolution failed for: $target" }
                }
            }
            '-2147024891' {
                if ($os.FreePhysicalMemory -lt $minFreeMemKB) { Exit-NonCompliant $TargetErrorCode "Free memory: $([math]::Round($os.FreePhysicalMemory/1MB,0)) MB (threshold 256 MB)" }
            }
            '-2147023890' {
                $volume = (Get-CimInstance Win32_Volume -Filter "DriveLetter='C:'").DirtyBitSet
                if ($volume) { Exit-NonCompliant $TargetErrorCode "Volume is dirty, chkdsk required" }
            }
            default { Exit-Compliant }
        }
        Exit-Compliant
    }

    Write-Log "No target error code specified. Running fast full scan..."

    $reason = Test-PendingReboot
    if ($reason) { Exit-NonCompliant '-2147021879' "Pending reboot detected ($reason)" }

    if ($disk.FreeSpace -lt $minFreeDiskBytes) {
        Exit-NonCompliant '-2147024784' "Low disk space: $([math]::Round($disk.FreeSpace/1GB,2)) GB free"
    }

    if ($os.FreePhysicalMemory -lt $minFreeMemKB) {
        Exit-NonCompliant '-2147024891' "Low memory: $([math]::Round($os.FreePhysicalMemory/1MB,0)) MB free (threshold 256 MB)"
    }

    $bits = Test-BitsProblem
    if ($bits) { Exit-NonCompliant '-2147023436' $bits }

    # Full scan only flags *partial* WSUS policy (or all missing when
    # -RequireWUServer is set). Cloud-only Intune devices legitimately
    # have no WUServer value and must stay compliant.
    $wu = Get-WUServerPolicyState
    if (($RequireWUServer -and -not $wu.WUServer) -or $wu.Partial) {
        Exit-NonCompliant '-2145107951' "WUServer policy missing/incomplete (RequireWUServer=$RequireWUServer, Partial=$($wu.Partial))"
    }

    if ($IncludeSlowChecks) {
        Write-Log "IncludeSlowChecks set - running DISM CheckHealth..."
        $check = Test-ComponentStoreCorrupt
        if ($check.Corrupt) { Exit-NonCompliant '-2147010798' "Component store corrupt (dism exit $($check.ExitCode))" }
    }

    Exit-Compliant
}
catch {
    Write-Log "Detection error: $_"
    Write-Output "DetectionError|$_"
    if ($Strict) { exit 1 }
    exit 0
}
