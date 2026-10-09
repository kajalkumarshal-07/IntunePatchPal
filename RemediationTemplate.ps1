#Requires -Version 5.1
<#
    Proactive Remediation script (Windows Update / patch errors).

    Exit codes (Intune contract): 0 = remediation succeeded (or nothing to
    do), 1 = remediation failed (Intune shows it in the remediation report).

    Hardening notes (prod readiness):
      - Every action is idempotent and non-destructive by default:
        * temp cleanup only touches files older than 24h (SYSTEM-safe)
        * DISM /ResetBase removed (it permanently blocks update uninstalls)
        * chkdsk only scheduled with -AllowChkdsk, and /f only (no /r)
        * low-memory case no longer stops running services
        * no winsock/ip reset (breaks VPN/LSP software), no pending.xml
          deletion (breaks in-progress servicing), no mass regsvr32
      - Post-action verification: Verified/Unknown exits 0, Failed exits 1
        so ops can see remediations that did not fix the problem
      - -AutoDetect no longer defaults to DISM /RestoreHealth; it only
        remediates conditions it can actually observe
    NOTE: Intune cannot pass parameters to remediation scripts. To enable
    chkdsk scheduling in Intune, change the default below to $true.
#>
param(
    [string]$ErrorCode = "",
    [switch]$AutoDetect,
    [switch]$AllowChkdsk
)

$ErrorActionPreference = "Stop"
$logFile = "$env:TEMP\IntuneRemediation.log"
$minFreeDiskBytes = 5GB
$minFreeMemKB = 262144   # 256 MB

$script:AppliedCode = ""
$script:ActionExit = $null

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

function Invoke-Native {
    # Runs a native command without letting redirected stderr become a
    # terminating error under $ErrorActionPreference = 'Stop' (PS 5.1).
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue)) {
        Write-Log "Skipped (not found): $FilePath"
        return [pscustomobject]@{ Output = "not found: $FilePath"; ExitCode = -1 }
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Arguments.Count -gt 0) { $out = (& $FilePath @Arguments 2>&1 | Out-String) }
        else { $out = (& $FilePath 2>&1 | Out-String) }
        return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
    }
    finally { $ErrorActionPreference = $prev }
}

function Clear-AgedTempFiles {
    # Only files older than 1 day - younger files may be in use.
    foreach ($root in @($env:TEMP, "$env:WINDIR\Temp")) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem -Path $root -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Reset-WindowsUpdateCache {
    Stop-Service wuauserv, bits, cryptsvc -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:WINDIR\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service wuauserv, bits, cryptsvc -ErrorAction SilentlyContinue
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

function Get-WUServer {
    (Get-ItemProperty 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate' -Name WUServer -ErrorAction SilentlyContinue).WUServer
}

function Invoke-Remediation {
    param([string]$Code)
    Write-Log "Running remediation for error code: $Code"
    $script:AppliedCode = $Code

    switch ($Code) {

        '-2147024784' {
            Write-Log "Remediating: not enough disk space (age-limited cleanup)"
            Clear-AgedTempFiles
            Remove-Item "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
            $dism = Invoke-Native dism.exe @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
            Write-Log "DISM StartComponentCleanup exit=$($dism.ExitCode) (no /ResetBase - keeps updates uninstallable)"
        }

        '-2147021879' {
            Write-Log "Remediating: reboot required - reporting only (no forced reboot)"
            Write-Output "RebootRequired|Reboot is pending. No reboot forced (org policy)."
        }

        '-2147010798' {
            Write-Log "Remediating: component store corrupted"
            $dism = Invoke-Native dism.exe @('/Online', '/Cleanup-Image', '/RestoreHealth')
            $script:ActionExit = $dism.ExitCode
            Write-Log "DISM RestoreHealth exit=$($dism.ExitCode)"
            $sfc = Invoke-Native sfc.exe @('/scannow')
            Write-Log "SFC exit=$($sfc.ExitCode)"
        }

        '-2147023436' {
            Write-Log "Remediating: operation timed out (BITS/WU reset)"
            $svc = Get-Service bits -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -eq 'Disabled') { Set-Service bits -StartupType Manual }
            Reset-WindowsUpdateCache
            netsh winhttp show proxy | Out-Null
        }

        '-2145107951' {
            Write-Log "Remediating: WUServer policy missing"
            Invoke-Native gpupdate.exe @('/force') | Out-Null
            $p = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate'
            if (Test-Path $p) { Write-Log "WU policy key present: $p" }
            Restart-Service wuauserv -Force -ErrorAction SilentlyContinue
        }

        '-2147012886' {
            Write-Log "Remediating: DNS resolution failure"
            Invoke-Native ipconfig.exe @('/flushdns') | Out-Null
            Invoke-Native ipconfig.exe @('/registerdns') | Out-Null
            Clear-DnsClientCache -ErrorAction SilentlyContinue
        }

        '-2147012855' {
            Write-Log "Remediating: network timeout (DNS + WU restart; no winsock reset - it breaks VPN/LSP)"
            Clear-DnsClientCache -ErrorAction SilentlyContinue
            Reset-WindowsUpdateCache
            Write-Output "NetworkTimeout|If failures persist: manual winsock reset + network adapter restart"
        }

        '-2147012867' {
            Write-Log "Remediating: server connection failed"
            Restart-Service wuauserv, bits, cryptsvc -Force -ErrorAction SilentlyContinue
            $proxy = Invoke-Native netsh.exe @('winhttp', 'show proxy')
            Write-Log "Proxy config: $($proxy.Output.Trim())"
            $wu = Get-WUServer
            if ($wu) { Write-Log "WSUS/WU server configured: $wu" }
        }

        '-2145124320' {
            Write-Log "Remediating: no interactive user - transient, no device changes made"
            $os = Get-CimInstance Win32_OperatingSystem
            Write-Output "Transient|NoInteractiveUser|uptime=$([math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours,1))h - no action taken"
        }

        '-2145124341' {
            Write-Log "Remediating: operation cancelled (WU cache reset + resync)"
            Reset-WindowsUpdateCache
            Invoke-Native wuauclt.exe @('/resetauthorization', '/detectnow') | Out-Null
        }

        '-2147467259' {
            Write-Log "Remediating: unspecified error (full WU reset + RestoreHealth)"
            Stop-Service wuauserv, bits, cryptsvc -Force -ErrorAction SilentlyContinue
            Remove-Item "$env:WINDIR\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$env:WINDIR\System32\catroot2\*" -Recurse -Force -ErrorAction SilentlyContinue
            Start-Service wuauserv, bits, cryptsvc -ErrorAction SilentlyContinue
            $dism = Invoke-Native dism.exe @('/Online', '/Cleanup-Image', '/RestoreHealth')
            $script:ActionExit = $dism.ExitCode
            Write-Log "DISM RestoreHealth exit=$($dism.ExitCode)"
        }

        '-2147467260' {
            Write-Log "Remediating: operation aborted (WU cache reset + resync)"
            Reset-WindowsUpdateCache
            Invoke-Native wuauclt.exe @('/resetauthorization', '/detectnow') | Out-Null
            Write-Output "OperationAborted|If failures persist: inspect CBS.log by hand (pending.xml is never touched here)"
        }

        '-2016409844' {
            Write-Log "Remediating: scan timed out (stuck workers over 2h old)"
            Get-Process msiexec, tiworker -ErrorAction SilentlyContinue |
                Where-Object { $_.StartTime -lt (Get-Date).AddHours(-2) } |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Output "ExecutionTimeout|Stopped msiexec/tiworker older than 2h (trustedinstaller is never touched)"
        }

        '-2147024891' {
            # No service is stopped here: the desktop's answer to a low-memory
            # scan is a retry, not killing whatever the machine is doing.
            Write-Log "Remediating: low memory - reporting the top consumers only"
            $top = (Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 |
                ForEach-Object { "$($_.Name) $([math]::Round($_.WorkingSet64/1MB))MB" }) -join ", "
            $cs = Get-CimInstance Win32_ComputerSystem
            Write-Output "LowMemory|top=$top|pagefile_auto=$($cs.AutomaticManagedPagefile)"
        }

        '-2016409966' {
            Write-Log "Remediating: policy conflict - writing a diagnostic report"
            Invoke-Native gpresult.exe @('/h', "$env:TEMP\gpresult.htm") | Out-Null
            Write-Output "PolicyConflict|Report written to %TEMP%\gpresult.htm for review"
        }

        '-2145124305' {
            Write-Log "Remediating: download failed (BITS queue reset)"
            Stop-Service bits -Force -ErrorAction SilentlyContinue
            Remove-Item "$env:ProgramData\Microsoft\Network\Downloader\*" -Recurse -Force -ErrorAction SilentlyContinue
            Start-Service bits -ErrorAction SilentlyContinue
        }

        '-2146777998' {
            Write-Log "Remediating: WU registry unreadable (policy refresh + cache reset)"
            Invoke-Native gpupdate.exe @('/force') | Out-Null
            Reset-WindowsUpdateCache
        }

        '-2147023890' {
            Write-Log "Remediating: volume is dirty"
            try { $rv = Repair-Volume -DriveLetter C -Scan -ErrorAction Stop; Write-Log "Repair-Volume scan: $rv" }
            catch { Write-Log "Repair-Volume scan unavailable: $_" }
            if ($AllowChkdsk) {
                $chk = Invoke-Native chkdsk.exe @('C:', '/f')
                Write-Log "chkdsk exit=$($chk.ExitCode)"
                Write-Output "ChkdskScheduled|chkdsk C: /f runs at the next reboot"
            }
            else {
                Write-Output "CorruptDisk|Volume dirty. Read-only scan done. Re-run with -AllowChkdsk to schedule 'chkdsk C: /f' (no /r)."
            }
        }

        '-2147010815' {
            Write-Log "Remediating: assembly unreadable (RestoreHealth)"
            $dism = Invoke-Native dism.exe @('/Online', '/Cleanup-Image', '/RestoreHealth')
            $script:ActionExit = $dism.ExitCode
            Write-Log "DISM RestoreHealth exit=$($dism.ExitCode)"
        }

        '-2147024809' {
            Write-Log "Remediating: corrupt metadata (WU cache reset + resync)"
            Reset-WindowsUpdateCache
            Invoke-Native wuauclt.exe @('/resetauthorization', '/detectnow') | Out-Null
        }

        default {
            Exit-Failure "No remediation defined for $Code"
        }
    }
}

function Get-RemediationOutcome {
    # Verified / Unknown exit 0; Failed exits 1. Anything the script cannot
    # prove is Unknown rather than a false success or a false alarm.
    param([string]$Code)
    switch ($Code) {
        '-2147024784' {
            $d = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3 AND DeviceID='C:'"
            if ($d.FreeSpace -ge $minFreeDiskBytes) {
                return [pscustomobject]@{ State = "Verified"; Detail = "free space now $([math]::Round($d.FreeSpace/1GB,2)) GB" }
            }
            return [pscustomobject]@{ State = "Failed"; Detail = "still low on disk space: $([math]::Round($d.FreeSpace/1GB,2)) GB" }
        }
        '-2147023436' {
            $svc = Get-Service bits -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -eq 'Disabled') {
                return [pscustomobject]@{ State = "Failed"; Detail = "BITS is still disabled" }
            }
            $err = @(Get-BitsTransfer -ErrorAction SilentlyContinue | Where-Object { $_.JobState -eq "Error" })
            if ($err.Count -gt 0) {
                return [pscustomobject]@{ State = "Failed"; Detail = "BITS still holds $($err.Count) errored job(s)" }
            }
            return [pscustomobject]@{ State = "Verified"; Detail = "BITS enabled, no errored jobs" }
        }
        '-2145124305' {
            $err = @(Get-BitsTransfer -ErrorAction SilentlyContinue | Where-Object { $_.JobState -eq "Error" })
            if ($err.Count -gt 0) {
                return [pscustomobject]@{ State = "Failed"; Detail = "BITS still holds $($err.Count) errored job(s)" }
            }
            return [pscustomobject]@{ State = "Verified"; Detail = "BITS queue cleared" }
        }
        '-2145107951' {
            if (Get-WUServer) { return [pscustomobject]@{ State = "Verified"; Detail = "WUServer policy is set" } }
            return [pscustomobject]@{ State = "Failed"; Detail = "WUServer policy still missing - policy source did not supply it" }
        }
        '-2147012886' {
            $wu = Get-WUServer
            if (-not $wu) { return [pscustomobject]@{ State = "Unknown"; Detail = "no WU server configured to resolve" } }
            $target = ($wu -replace '^https?://', '' -replace '/.*$', '' -replace ':\d+$', '')
            try { Resolve-DnsName $target -ErrorAction Stop | Out-Null; return [pscustomobject]@{ State = "Verified"; Detail = "resolved $target" } }
            catch { return [pscustomobject]@{ State = "Failed"; Detail = "$target still does not resolve" } }
        }
        { $_ -in @('-2147010798', '-2147467259', '-2147010815') } {
            if ($script:ActionExit -eq 0) { return [pscustomobject]@{ State = "Verified"; Detail = "DISM RestoreHealth exit=0" } }
            if ($null -eq $script:ActionExit) { return [pscustomobject]@{ State = "Unknown"; Detail = "no verification available" } }
            return [pscustomobject]@{ State = "Failed"; Detail = "DISM RestoreHealth exit=$($script:ActionExit)" }
        }
        '-2147021879' {
            return [pscustomobject]@{ State = "Unknown"; Detail = "reboot pending - reported, not forced" }
        }
        '-2147023890' {
            if ($AllowChkdsk) { return [pscustomobject]@{ State = "Unknown"; Detail = "chkdsk scheduled for the next reboot" } }
            return [pscustomobject]@{ State = "Failed"; Detail = "volume still dirty - re-run with -AllowChkdsk" }
        }
        default {
            return [pscustomobject]@{ State = "Unknown"; Detail = "action taken; no automated verification for $Code" }
        }
    }
}

# Dot-sourcing only loads the functions (tests); execution requires -File.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    Write-Log "Remediation started (code='$ErrorCode', auto=$AutoDetect)"
    if ($AutoDetect) {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3 AND DeviceID='C:'"
        $os = Get-CimInstance Win32_OperatingSystem
        $bits = Get-Service bits -ErrorAction SilentlyContinue
        if ($disk.FreeSpace -lt $minFreeDiskBytes) { Invoke-Remediation '-2147024784' }
        elseif (Test-PendingReboot) { Invoke-Remediation '-2147021879' }
        elseif ($bits -and $bits.StartType -eq 'Disabled') { Invoke-Remediation '-2147023436' }
        elseif ($os.FreePhysicalMemory -lt $minFreeMemKB) { Invoke-Remediation '-2147024891' }
        else {
            Write-Log "Auto-detect found no known issue"
            Exit-Success "Auto-detect found no known issue"
        }
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
