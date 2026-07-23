param(
    [string]$ErrorCode = "",
    [switch]$AutoDetect
)

$ErrorActionPreference = "Stop"
$logFile = "$env:TEMP\IntuneAppRemediation.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $logFile -Append
}

function Exit-Success { Write-Log "Remediation completed"; exit 0 }

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
            Write-Log "Freeing disk space"
            cleanmgr /sagerun:1 | Out-Null
            Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
            DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null
        }

        '-2147021879' {
            Write-Log "Reboot required"
            Write-Output "RebootRequired"
        }

        '1602' {
            Write-Log "User cancelled - no remediation needed"
        }

        '1603' {
            Write-Log "Fatal install error - cleaning up"
            Get-Process msiexec -ErrorAction SilentlyContinue | Stop-Process -Force
            $msiInstallers = Get-ChildItem "$env:WINDIR\Installer\*.msi" -ErrorAction SilentlyContinue
            Remove-Item "$env:WINDIR\Temp\*.msi" -Force -ErrorAction SilentlyContinue
            DISM /Online /Cleanup-Image /RestoreHealth | Out-Null
        }

        '1618' {
            Write-Log "Another install running - waiting for completion"
            $waitStart = Get-Date
            while ((Get-Process msiexec -ErrorAction SilentlyContinue) -and ((Get-Date) - $waitStart).TotalMinutes -lt 15) {
                Write-Log "Waiting for msiexec to finish..."
                Start-Sleep -Seconds 30
            }
            $stillRunning = Get-Process msiexec -ErrorAction SilentlyContinue
            if ($stillRunning) {
                Write-Log "Timed out waiting for msiexec - killing hung process"
                $stillRunning | Where-Object { $_.StartTime -lt (Get-Date).AddHours(-1) } | Stop-Process -Force
            }
        }

        '1619' {
            Write-Log "Package access issue"
            if (Test-Path "$env:WINDIR\Temp") {
                $acl = Get-Acl "$env:WINDIR\Temp"
                Write-Log "Temp folder permissions checked"
            }
        }

        '1632' {
            Write-Log "Temp directory unwritable"
            Remove-Item "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
        }

        '1638' {
            Write-Log "Product version conflict"
            Write-Output "ProductVersionConflict|Check for existing conflicting versions of the same app"
        }

        '-2016281111' {
            Write-Log "Detection script returned not installed"
            Write-Output "DetectionMismatch|Verify detection script logic (file/registry/version check)"
        }

        '-2016344807' {
            Write-Log "Requirement rule not met"
            $os = Get-CimInstance Win32_OperatingSystem
            Write-Output "RequirementNotMet|OS: $($os.Caption) Build: $($os.BuildNumber)"
        }

        '-2016281109' {
            Write-Log "Script execution failed"
            $executionPolicy = Get-ExecutionPolicy
            if ($executionPolicy -eq 'Restricted') {
                Write-Log "Setting execution policy for Intune"
                Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
            }
        }

        '-2016281112' {
            Write-Log "Script execution timed out"
            Write-Output "ScriptTimedOut|Intune script timeout is 30 min. Simplify the install script logic."
        }

        '-2016281113' {
            Write-Log "File path not found in detection"
            Write-Output "FilePathNotFound|Verify the detection file path exists and is accessible"
        }

        '-2016281114' {
            Write-Log "Registry key not found in detection"
            Write-Output "RegistryKeyNotFound|Verify the detection registry path exists"
        }

        '-2147024894' {
            Write-Log "File not found"
            Write-Output "FileNotFound|Check if install source files were deleted or the path is incorrect"
        }

        '1641' {
            Write-Log "Reboot initiated by installer"
            Write-Output "RebootRequired"
        }

        default {
            Exit-Failure "No remediation defined for error code $Code"
        }
    }
}

try {
    Write-Log "App remediation started"

    if ($AutoDetect) {
        Write-Log "Auto-detect mode"
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3 AND DeviceID='C:'"
        $msiRunning = Get-Process msiexec -ErrorAction SilentlyContinue
        $pendingReboot = Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations"

        if ($pendingReboot) { Invoke-Remediation '-2147021879' }
        elseif (($msiRunning | Measure-Object).Count -gt 1) { Invoke-Remediation '1618' }
        elseif ($disk.FreeSpace -lt 1GB) { Invoke-Remediation '-2147024784' }
        else { Invoke-Remediation '1603' }
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
