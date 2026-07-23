param(
    [string]$ErrorCode = "",
    [switch]$AutoDetect,
    [int]$RebootTimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"
$logFile = "$env:TEMP\IntuneRemediation.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $logFile -Append
}

function Exit-Success {
    Write-Log "Remediation completed successfully"
    exit 0
}

function Exit-Failure {
    param([string]$Reason)
    Write-Log "Remediation failed: $Reason"
    Write-Output "Failed: $Reason"
    exit 1
}

function Invoke-Remediation {
    param([string]$Code)
    Write-Log "Running remediation for error code: $Code"

    switch ($Code) {

        '-2147024784' {
            Write-Log "Remediating: Not enough disk space"
            cleanmgr /sagerun:1 | Out-Null
            Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
            DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null
        }

        '-2147021879' {
            Write-Log "Remediating: Reboot required"
            Write-Output "RebootRequired"
        }

        '-2147010798' {
            Write-Log "Remediating: Component store corrupted"
            DISM /Online /Cleanup-Image /RestoreHealth | Out-Null
            SFC /ScanNow | Out-Null
        }

        '-2147023436' {
            Write-Log "Remediating: Operation timed out"
            Stop-Service wuauserv, bits, cryptsvc -Force -ErrorAction SilentlyContinue
            Remove-Item "$env:WINDIR\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
            Start-Service wuauserv, bits, cryptsvc
            netsh winhttp reset proxy | Out-Null
        }

        '-2145107951' {
            Write-Log "Remediating: WUServer policy missing"
            gpupdate /force | Out-Null
            $paths = @(
                "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate",
                "HKLM:\Software\Microsoft\Windows\CurrentVersion\WindowsUpdate"
            )
            foreach ($p in $paths) {
                if (Test-Path $p) {
                    Write-Log "Found WU registry key: $p"
                    Get-ItemProperty -Path $p | Out-String | ForEach-Object { Write-Log $_ }
                }
            }
            Restart-Service wuauserv -Force
        }

        '-2147012886' {
            Write-Log "Remediating: DNS resolution failure"
            ipconfig /flushdns | Out-Null
            ipconfig /registerdns | Out-Null
            Clear-DnsClientCache -ErrorAction SilentlyContinue
        }

        '-2147012855' {
            Write-Log "Remediating: Network timeout"
            netsh winsock reset | Out-Null
            netsh int ip reset | Out-Null
            Restart-Service bits, wuauserv -Force
        }

        '-2147012867' {
            Write-Log "Remediating: Server connection failed"
            Restart-Service wuauserv, bits -Force
            netsh winhttp reset proxy | Out-Null
            $proxy = (Get-ItemProperty "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate" -Name WUServer -ErrorAction SilentlyContinue).WUServer
            if ($proxy) { Write-Log "WSUS server configured: $proxy" }
        }

        '-2145124320' {
            Write-Log "Remediating: No interactive user (transient)"
            powercfg /change standby-timeout-ac 0 | Out-Null
            powercfg /change hibernate-timeout-ac 0 | Out-Null
        }

        '-2145124341' {
            Write-Log "Remediating: Operation cancelled"
            Stop-Service wuauserv, bits -Force
            Remove-Item "$env:WINDIR\SoftwareDistribution\*" -Recurse -Force
            Start-Service wuauserv, bits
            wuauclt /resetauthorization /detectnow | Out-Null
        }

        '-2147467259' {
            Write-Log "Remediating: Unspecified error"
            Stop-Service wuauserv, bits, cryptsvc -Force
            Remove-Item "$env:WINDIR\SoftwareDistribution\*" -Recurse -Force
            Remove-Item "$env:WINDIR\System32\catroot2\*" -Recurse -Force
            Start-Service wuauserv, bits, cryptsvc
            regsvr32 /s wuapi.dll; regsvr32 /s wups.dll; regsvr32 /s wuwebv.dll
            regsvr32 /s wups2.dll; regsvr32 /s wucltux.dll
            DISM /Online /Cleanup-Image /RestoreHealth | Out-Null
        }

        '-2147467260' {
            Write-Log "Remediating: Operation aborted"
            Remove-Item "$env:WINDIR\Winsxs\pending.xml" -Force -ErrorAction SilentlyContinue
            regsvr32 /s wuapi.dll; regsvr32 /s wups.dll; regsvr32 /s wuwebv.dll
            wuauclt /detectnow | Out-Null
        }

        '-2016409844' {
            Write-Log "Remediating: Update execution timeout"
            Get-Process msiexec, tiworker, trustedinstaller -ErrorAction SilentlyContinue |
                Where-Object { $_.StartTime -lt (Get-Date).AddHours(-2) } |
                Stop-Process -Force -ErrorAction SilentlyContinue
        }

        '-2147024891' {
            Write-Log "Remediating: Not enough memory"
            $services = Get-Service | Where-Object { $_.Status -eq 'Running' -and $_.StartType -eq 'Manual' }
            foreach ($svc in $services) { Stop-Service $svc -Force -ErrorAction SilentlyContinue }
        }

        '-2016409966' {
            Write-Log "Remediating: Group policy conflict"
            gpresult /h "$env:TEMP\gpresult.html" | Out-Null
            Write-Log "GPO report saved to $env:TEMP\gpresult.html"
        }

        '-2145124305' {
            Write-Log "Remediating: Download failed"
            Stop-Service bits -Force
            Remove-Item "$env:ProgramData\Microsoft\Network\Downloader\*" -Recurse -Force -ErrorAction SilentlyContinue
            Start-Service bits
        }

        '-2146777998' {
            Write-Log "Remediating: WU registry corrupt"
            regsvr32 /s wuapi.dll; regsvr32 /s wups.dll; regsvr32 /s wuwebv.dll
            regsvr32 /s wups2.dll; regsvr32 /s wucltux.dll; regsvr32 /s wudrv.dll
        }

        '-2147023890' {
            Write-Log "Remediating: Corrupted file or disk"
            chkdsk C: /f /r | Out-Null
            Write-Output "Chkdsk scheduled at next reboot"
        }

        '-2147010815' {
            Write-Log "Remediating: Assembly not found"
            DISM /Online /Cleanup-Image /RestoreHealth | Out-Null
            DISM /Online /Enable-Feature /FeatureName:NetFx3 /All | Out-Null
            SFC /ScanNow | Out-Null
        }

        '-2147024809' {
            Write-Log "Remediating: Bad parameter / corrupt metadata"
            Stop-Service wuauserv, bits -Force
            Remove-Item "$env:WINDIR\SoftwareDistribution\*" -Recurse -Force
            Start-Service wuauserv, bits
            regsvr32 /s wuapi.dll; regsvr32 /s wups.dll; regsvr32 /s wuwebv.dll
            wuauclt /resetauthorization /detectnow | Out-Null
        }

        default {
            Exit-Failure "No remediation defined for error code $Code"
        }
    }
}

try {
    Write-Log "Remediation started"

    if ($AutoDetect) {
        Write-Log "Auto-detect mode: scanning for known issues"
        $os = Get-CimInstance Win32_OperatingSystem
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3 AND DeviceID='C:'"
        $pendingReboot = Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations"

        if ($disk.FreeSpace -lt 5GB) { Invoke-Remediation '-2147024784' }
        elseif ($pendingReboot) { Invoke-Remediation '-2147021879' }
        else { Invoke-Remediation '-2147010798' }
    }
    elseif ($ErrorCode) {
        Invoke-Remediation $ErrorCode
    }
    else {
        Exit-Failure "No error code specified. Use -ErrorCode or -AutoDetect"
    }

    Exit-Success
}
catch {
    Write-Log "Remediation error: $_"
    Write-Output "Error: $_"
    exit 1
}
