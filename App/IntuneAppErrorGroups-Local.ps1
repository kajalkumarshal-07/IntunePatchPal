param(
    [string]$GroupPrefix = "Intune-AppError",
    [string[]]$TenantId
)

$AppErrorCodes = @{
    '1601' = 'Install service failed'
    '1602' = 'User cancelled installation'
    '1603' = 'Fatal installation error'
    '1605' = 'Install service failure'
    '1606' = 'Installation suspended'
    '1618' = 'Another install already running'
    '1619' = 'Package cannot be opened'
    '1620' = 'Package is invalid'
    '1621' = 'UI failure during install'
    '1622' = 'Log failure'
    '1623' = 'Language not supported'
    '1624' = 'Transform failure'
    '1625' = 'Package rejected'
    '1628' = 'Invalid table'
    '1629' = 'Datatype mismatch'
    '1630' = 'Unsupported type'
    '1631' = 'Create failed'
    '1632' = 'Temp dir unwritable'
    '1633' = 'Platform unsupported'
    '1635' = 'Patch package open failed'
    '1636' = 'Patch package invalid'
    '1638' = 'Product version conflict'
    '1639' = 'Invalid command line'
    '1640' = 'Remote install disallowed'
    '1641' = 'Reboot initiated by install'
    '1642' = 'Patch target not found'
    '-2016281111' = 'Detection script returned not installed'
    '-2016344807' = 'Requirement rule not met'
    '-2016281109' = 'Script execution failed'
    '-2016281112' = 'Script execution timed out'
    '-2016281113' = 'File path not found'
    '-2016281114' = 'Registry key not found'
    '-2147024894' = 'File not found during install'
    '-2147024784' = 'Not enough disk space'
    '-2147021879' = 'Reboot pending'
    '-2147024891' = 'Not enough memory'
}

Write-Output "Installing required modules if missing..."
$requiredModules = @('Microsoft.Graph.Authentication')
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Install-Module $mod -Scope CurrentUser -Force
    }
}

$authParams = @{ Scopes = @(
    'DeviceManagementApps.Read.All',
    'DeviceManagementManagedDevices.Read.All',
    'Group.ReadWrite.All',
    'Directory.Read.All'
) }
if ($TenantId) { $authParams.TenantId = $TenantId[0] }

Connect-MgGraph @authParams

$groupsCreated = 0
$groupsUpdated = 0
$deviceMembershipCount = 0

try {
    Write-Output "Fetching Intune managed apps..."
    $apps = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/mobileApps?`$select=id,displayName,appType,publisher&`$top=500" `
        -OutputType PSObject

    $allFailedStatuses = @()

    foreach ($app in $apps.value) {
        $appName = $app.displayName
        Write-Output "Processing app: $appName"

        try {
            $statuses = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/mobileApps/$($app.id)/deviceStatuses?`$filter=installState eq 'failed'&`$top=500" `
                -OutputType PSObject

            foreach ($s in $statuses.value) {
                $allFailedStatuses += [PSCustomObject]@{
                    deviceId   = $s.deviceId
                    deviceName = $s.deviceName
                    appName    = $appName
                    errorCode  = "$($s.errorCode)"
                }
            }
        }
        catch { Write-Warning "Failed to query $appName : $_" }
    }

    if ($allFailedStatuses.Count -eq 0) {
        Write-Output "No app installation failures found."
        return
    }

    $grouped = $allFailedStatuses | Group-Object errorCode

    foreach ($group in $grouped) {
        $errorCode = $group.Name
        $devices = $group.Group
        $description = if ($AppErrorCodes.ContainsKey($errorCode)) { $AppErrorCodes[$errorCode] } else { "Unknown error code" }
        $groupName = "$GroupPrefix-$errorCode"

        $existingGroup = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$groupName'" `
            -OutputType PSObject

        if ($existingGroup.value.Count -eq 0) {
            Write-Output "Creating group: $groupName ($description)"
            $newGroup = Invoke-MgGraphRequest -Method POST `
                -Uri "https://graph.microsoft.com/v1.0/groups" `
                -Body (@{
                    displayName = $groupName
                    description = "Intune app install failures | Error code: $errorCode | $description | Managed by automation"
                    mailEnabled = $false
                    securityEnabled = $true
                    mailNickname = $groupName -replace '[^a-zA-Z0-9]', ''
                    groupTypes = @()
                } | ConvertTo-Json) `
                -ContentType "application/json" `
                -OutputType PSObject
            $groupId = $newGroup.id
            $groupsCreated++
        }
        else {
            $groupId = $existingGroup.value[0].id
            $groupsUpdated++
            $currentMembers = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members" -OutputType PSObject
            $currentDeviceIds = $currentMembers.value | ForEach-Object { $_.id }
            $targetDeviceIds = $devices | ForEach-Object { $_.deviceId } | Select-Object -Unique
            $toRemove = $currentDeviceIds | Where-Object { $targetDeviceIds -notcontains $_ }
            foreach ($removeId in $toRemove) {
                Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members/$removeId/`$ref"
            }
            Write-Output "Updating group: $groupName ($description) - $(@($targetDeviceIds).Count) devices"
        }

        $deviceIds = $devices | ForEach-Object { $_.deviceId } | Select-Object -Unique
        foreach ($deviceId in $deviceIds) {
            try {
                Invoke-MgGraphRequest -Method POST `
                    -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members/`$ref" `
                    -Body (@{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$deviceId" } | ConvertTo-Json) `
                    -ContentType "application/json"
                $deviceMembershipCount++
            }
            catch { Write-Warning "Failed to add device $deviceId : $_" }
        }
    }

    Write-Output "Done. Groups created: $groupsCreated | Groups updated: $groupsUpdated | Memberships added: $deviceMembershipCount"
}
catch {
    Write-Error "Script failed: $_"
    exit 1
}
