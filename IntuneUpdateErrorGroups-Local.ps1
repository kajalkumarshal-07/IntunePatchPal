param(
    [string]$GroupPrefix = "Intune-PatchError",
    [string[]]$TenantId
)

$ErrorCodes = @{
    0                   = 'Success'
    '-2147024784'       = 'Not enough disk space'
    '-2147021879'       = 'Reboot required'
    '-2147010798'       = 'Component store corrupted'
    '-2147010815'       = 'Assembly not found'
    '-2147010893'       = 'Assembly not installed'
    '-2147023436'       = 'Operation timed out'
    '-2145124320'       = 'No interactive user'
    '-2145124341'       = 'Operation cancelled'
    '-2145107951'       = 'WUServer policy missing'
    '-2145120257'       = 'Unknown error'
    '-2147467259'       = 'Unspecified error'
    '-2147467260'       = 'Operation aborted'
}

Write-Output "Installing required modules if missing..."
$requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.DeviceManagement')
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Install-Module $mod -Scope CurrentUser -Force
    }
}

$authParams = @{ Scopes = @(
    'DeviceManagementManagedDevices.Read.All',
    'Group.ReadWrite.All',
    'Directory.Read.All'
) }
if ($TenantId) { $authParams.TenantId = $TenantId[0] }

Connect-MgGraph @authParams

$groupsCreated = 0
$groupsUpdated = 0
$deviceCount = 0

try {
    Write-Output "Fetching Windows Update states from Intune..."
    $allStates = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsUpdateStates" `
        -OutputType PSObject

    $failedStates = $allStates.value | Where-Object { $_.status -eq "failed" }

    if (-not $failedStates) {
        Write-Output "No devices with failed updates found."
        return
    }

    $grouped = $failedStates | Group-Object errorCode

    foreach ($group in $grouped) {
        $errorCode = $group.Name
        $devices = $group.Group
        $description = if ($ErrorCodes.ContainsKey($errorCode)) { $ErrorCodes[$errorCode] } else { "Unknown error code" }
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
                    description = "Intune update patch failures | Error code: $errorCode | $description | Managed by automation"
                    mailEnabled = $false
                    securityEnabled = $true
                    mailNickname = $groupName -replace '[^a-zA-Z0-9]', ''
                    groupTypes = @()
                } | ConvertTo-Json) `
                -ContentType "application/json" `
                -OutputType PSObject

            $groupId = $newGroup.id
            $groupsCreated++
        } else {
            $groupId = $existingGroup.value[0].id
            $groupsUpdated++

            $currentMembers = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members" `
                -OutputType PSObject

            $currentDeviceIds = $currentMembers.value | ForEach-Object { $_.id }
            $targetDeviceIds = $devices | ForEach-Object { $_.deviceId } | Select-Object -Unique

            $toRemove = $currentDeviceIds | Where-Object { $targetDeviceIds -notcontains $_ }
            foreach ($removeId in $toRemove) {
                Invoke-MgGraphRequest -Method DELETE `
                    -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members/$removeId/`$ref"
            }

            Write-Output "Updating group: $groupName ($description) - $(@($targetDeviceIds).Count) devices"
        }

        $deviceIds = $devices | ForEach-Object { $_.deviceId } | Select-Object -Unique
        foreach ($deviceId in $deviceIds) {
            try {
                Invoke-MgGraphRequest -Method POST `
                    -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members/`$ref" `
                    -Body (@{
                        '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$deviceId"
                    } | ConvertTo-Json) `
                    -ContentType "application/json"
                $deviceCount++
            } catch {
                Write-Warning "Failed to add device $deviceId : $_"
            }
        }
    }

    Write-Output "Done. Groups created: $groupsCreated | Groups updated: $groupsUpdated | Device memberships added: $deviceCount"
}
catch {
    Write-Error "Script failed: $_"
    exit 1
}
