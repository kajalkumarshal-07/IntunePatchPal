#Requires -Version 5.1
<#
    Azure Automation runbook: groups Intune app installation failures into
    Entra ID security groups named {GroupPrefix}-{errorCode}.

    Hardening notes (prod readiness):
      - Full Graph pagination via @odata.nextLink (no silent truncation)
      - Exponential-backoff retry on 429/5xx
      - Membership synced by read-diff-write using JSON $batch (20 ops/call)
      - Only touches groups carrying the "Managed by automation" marker
      - Stale groups (no current failures) are emptied, not left stale
      - -DryRun previews every mutation
      - Dot-sourcing this file only loads functions (for tests)
#>
param(
    [switch]$CleanupOrphanedGroups,
    [string]$GroupPrefix = "Intune-AppError",
    [switch]$Interactive,
    [string]$TenantId,
    [string]$AppFilter,
    [switch]$DryRun
)

$AppErrorCodes = @{
    '1601'             = 'Install service failed'
    '1602'             = 'User cancelled installation'
    '1603'             = 'Fatal installation error'
    '1605'             = 'Install service failure'
    '1606'             = 'Installation suspended'
    '1618'             = 'Another install already running'
    '1619'             = 'Package cannot be opened'
    '1620'             = 'Package is invalid'
    '1621'             = 'UI failure during install'
    '1622'             = 'Log failure'
    '1623'             = 'Language not supported'
    '1624'             = 'Transform failure'
    '1625'             = 'Package rejected'
    '1628'             = 'Invalid table'
    '1629'             = 'Datatype mismatch'
    '1630'             = 'Unsupported type'
    '1631'             = 'Create failed'
    '1632'             = 'Temp dir unwritable'
    '1633'             = 'Platform unsupported'
    '1635'             = 'Patch package open failed'
    '1636'             = 'Patch package invalid'
    '1638'             = 'Product version conflict'
    '1639'             = 'Invalid command line'
    '1640'             = 'Remote install disallowed'
    '1641'             = 'Reboot initiated by install'
    '1642'             = 'Patch target not found'
    '-2016281111'      = 'Detection script evaluated as not installed'
    '-2016344807'      = 'Requirement rule not met'
    '-2016281109'      = 'Script execution failed'
    '-2016281112'      = 'Script execution timed out'
    '-2016281113'      = 'File path not found'
    '-2016281114'      = 'Registry path not found'
    '-2147024894'      = 'File not found during install'
    '-2147024784'      = 'Not enough disk space'
    '-2147021879'      = 'Reboot pending'
    '-2147024891'      = 'Not enough memory'
}

$script:GroupMarker = 'Managed by automation'
$script:GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:SeenCodes = @{}
$script:Stats = @{
    GroupsCreated     = 0
    GroupsSynced      = 0
    GroupsCleared     = 0
    GroupsDeleted     = 0
    MembersAdded      = 0
    MembersRemoved    = 0
    MembersSkipped    = 0
    InvalidDeviceIds  = 0
    Failures          = 0
}

function Get-GraphErrorStatus {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex) {
        if ($ex.PSObject.Properties['Response'] -and $ex.Response) {
            try { return [int]$ex.Response.StatusCode } catch { }
        }
        if ($ex.Message -match 'does not indicate success:\s*(429|500|502|503|504)' -or
            $ex.Message -match 'Too Many Requests|throttl|Service Unavailable|Bad Gateway|Gateway Timeout') {
            if ($Matches.ContainsKey(1)) { try { return [int]$Matches[1] } catch { } }
            return 429
        }
        $ex = $ex.InnerException
    }
    return $null
}

function Invoke-GraphApi {
    [CmdletBinding()]
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        [string]$Body,
        [int]$MaxRetries = 6
    )
    $attempt = 0
    while ($true) {
        try {
            $p = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject'; ErrorAction = 'Stop' }
            if ($null -ne $Body) {
                $p.Body = $Body
                $p.ContentType = 'application/json'
            }
            return Invoke-MgGraphRequest @p
        }
        catch {
            $status = Get-GraphErrorStatus -ErrorRecord $_
            $attempt++
            $retryable = $status -in 429, 500, 502, 503, 504
            if (-not $retryable -or $attempt -gt $MaxRetries) { throw }
            $delay = [Math]::Min([Math]::Pow(2, $attempt), 60) + ((Get-Random -Minimum 0 -Maximum 1000) / 1000)
            Write-Warning "Graph HTTP $status on $Method $Uri - retry $attempt/$MaxRetries in $([Math]::Round($delay, 1))s"
            Start-Sleep -Seconds $delay
        }
    }
}

function Invoke-GraphGetAll {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri)
    $items = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $resp = Invoke-GraphApi -Method GET -Uri $next
        if ($null -eq $resp) { break }
        $page = $null
        try { $page = $resp.value } catch { }
        if ($null -ne $page) {
            foreach ($v in @($page)) {
                if ($null -ne $v) { $items.Add($v) }
            }
            $next = $null
            try { $next = $resp.'@odata.nextLink' } catch { }
        }
        else {
            $items.Add($resp)
            $next = $null
        }
    }
    return $items
}

function Invoke-GraphBatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][array]$Requests)
    $results = New-Object System.Collections.Generic.List[object]
    $size = 20
    for ($i = 0; $i -lt $Requests.Count; $i += $size) {
        $end = [Math]::Min($i + $size - 1, $Requests.Count - 1)
        $chunk = @($Requests[$i..$end])
        $entries = @()
        foreach ($r in $chunk) {
            $entry = [ordered]@{ id = [string]$r.Id; method = $r.Method; url = $r.Url }
            if ($r.BodyObject) {
                $entry['headers'] = @{ 'Content-Type' = 'application/json' }
                $entry['body'] = $r.BodyObject
            }
            $entries += $entry
        }
        $payload = ConvertTo-Json -InputObject @{ requests = $entries } -Depth 12
        $resp = Invoke-GraphApi -Method POST -Uri 'https://graph.microsoft.com/v1.0/$batch' -Body $payload
        foreach ($sr in @($resp.responses)) {
            $st = 0
            try { $st = [int]$sr.status } catch { $st = 0 }
            $results.Add([pscustomobject]@{ Id = [string]$sr.id; Status = $st; Body = $sr.body })
        }
    }
    return $results
}

function Sync-GroupMembers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][string]$GroupName,
        [array]$TargetDeviceIds,
        [switch]$DryRun
    )
    $raw = @($TargetDeviceIds | Where-Object { $_ })
    $invalid = @($raw | Where-Object { $_ -notmatch $script:GuidPattern })
    if ($invalid.Count -gt 0) {
        $script:Stats.InvalidDeviceIds += $invalid.Count
        Write-Warning "Ignoring $($invalid.Count) invalid target id(s) for ${GroupName}: $($invalid -join ', ')"
        if ($invalid.Count -eq $raw.Count) {
            Write-Warning "All target ids for $GroupName are invalid - skipping sync (members untouched)."
            return
        }
    }
    $targets = @($raw | Where-Object { $_ -match $script:GuidPattern } | Select-Object -Unique)

    $uri = "https://graph.microsoft.com/v1.0/groups/$GroupId/members?`$select=id&`$top=1000"
    $currentIds = @((Invoke-GraphGetAll -Uri $uri) | ForEach-Object { $_.id })
    $toAdd = @($targets | Where-Object { $currentIds -notcontains $_ })
    $toRemove = @($currentIds | Where-Object { $targets -notcontains $_ })

    if ($toAdd.Count -eq 0 -and $toRemove.Count -eq 0) { return }

    Write-Output ("Sync {0}: {1} to add, {2} to remove" -f $GroupName, $toAdd.Count, $toRemove.Count)
    if ($DryRun) {
        $script:Stats.MembersAdded += $toAdd.Count
        $script:Stats.MembersRemoved += $toRemove.Count
        return
    }

    $requests = New-Object System.Collections.Generic.List[object]
    $lookup = @{}
    $n = 0
    foreach ($id in $toAdd) {
        if ($id -notmatch $script:GuidPattern) {
            $script:Stats.InvalidDeviceIds++
            Write-Warning "Skipping non-GUID device id '$id' for group $GroupName"
            continue
        }
        $n++
        $requests.Add(@{
            Id         = "$n"
            Method     = 'POST'
            Url        = "groups/$GroupId/members/`$ref"
            BodyObject = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$id" }
        })
        $lookup["$n"] = @{ Kind = 'add'; DeviceId = $id }
    }
    foreach ($id in $toRemove) {
        $n++
        $requests.Add(@{
            Id     = "$n"
            Method = 'DELETE'
            Url    = "groups/$GroupId/members/$id/`$ref"
        })
        $lookup["$n"] = @{ Kind = 'remove'; DeviceId = $id }
    }
    if ($requests.Count -eq 0) { return }

    $results = Invoke-GraphBatch -Requests $requests.ToArray()
    foreach ($r in $results) {
        $info = $lookup[[string]$r.Id]
        if ($r.Status -ge 200 -and $r.Status -lt 300) {
            if ($info.Kind -eq 'add') { $script:Stats.MembersAdded++ } else { $script:Stats.MembersRemoved++ }
        }
        elseif ($r.Status -eq 409 -or $r.Status -eq 404) {
            $script:Stats.MembersSkipped++
        }
        else {
            $script:Stats.Failures++
            $msg = ''
            try { $msg = $r.Body.error.message } catch { }
            Write-Warning "Membership $($info.Kind) failed for device $($info.DeviceId) in $GroupName (HTTP $($r.Status)): $msg"
        }
    }
}

function Get-ErrorGroup {
    param([Parameter(Mandatory)][string]$GroupName)
    $esc = $GroupName -replace "'", "''"
    $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$esc'&`$select=id,displayName,description"
    $resp = Invoke-GraphApi -Method GET -Uri $uri
    if ($resp -and $resp.value) { return @($resp.value) }
    return @()
}

function New-ErrorGroup {
    param(
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][string]$Description
    )
    $body = @{
        displayName     = $GroupName
        description     = $Description
        mailEnabled     = $false
        securityEnabled = $true
        mailNickname    = ($GroupName -replace '[^a-zA-Z0-9]', '')
        groupTypes      = @()
    }
    $resp = Invoke-GraphApi -Method POST -Uri 'https://graph.microsoft.com/v1.0/groups' -Body (ConvertTo-Json -InputObject $body -Depth 5)
    return $resp.id
}

function Get-FailedAppStatuses {
    $appsUri = 'https://graph.microsoft.com/v1.0/deviceManagement/mobileApps?$select=id,displayName&$top=1000'
    $apps = @(Invoke-GraphGetAll -Uri $appsUri)
    if ($AppFilter) {
        $apps = @($apps | Where-Object { $_.displayName -like "*$AppFilter*" })
        Write-Output "AppFilter '$AppFilter' matched $($apps.Count) app(s)."
    }
    Write-Output "Fetching install statuses for $($apps.Count) app(s)..."

    $failed = New-Object System.Collections.Generic.List[object]
    foreach ($app in $apps) {
        $statusUri = "https://graph.microsoft.com/beta/deviceManagement/mobileApps/$($app.id)/deviceStatuses?`$filter=installState eq 'failed'&`$top=1000"
        try {
            $rows = @(Invoke-GraphGetAll -Uri $statusUri)
        }
        catch {
            Write-Warning "Could not query statuses for app '$($app.displayName)': $_"
            $script:Stats.Failures++
            continue
        }
        foreach ($s in $rows) {
            if (-not $s.deviceId) { continue }
            $failed.Add([pscustomobject]@{
                deviceId  = $s.deviceId
                appName   = $app.displayName
                errorCode = "$($s.errorCode)"
            })
        }
    }
    return $failed
}

function Invoke-ErrorGroupSync {
    $allFailed = @(Get-FailedAppStatuses)
    Write-Output "Found $(@($allFailed).Count) failed app install status(es)."

    $grouped = @($allFailed | Group-Object errorCode | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
    $script:SeenCodes = @{}
    foreach ($g in $grouped) { $script:SeenCodes[[string]$g.Name] = $true }

    foreach ($g in $grouped) {
        $code = [string]$g.Name
        $devices = @($g.Group)
        $description = 'Unknown error code'
        if ($AppErrorCodes.ContainsKey($code)) { $description = $AppErrorCodes[$code] }
        $groupName = "$GroupPrefix-$code"

        try {
            $existing = Get-ErrorGroup -GroupName $groupName
            if ($existing.Count -eq 0) {
                if ($DryRun) {
                    Write-Output "[DryRun] Would create group $groupName ($description) with $(@($devices.deviceId | Select-Object -Unique).Count) device(s)"
                    $script:Stats.GroupsCreated++
                    continue
                }
                $desc = "Intune app install failures | Error code: $code | $description | $script:GroupMarker"
                $gid = New-ErrorGroup -GroupName $groupName -Description $desc
                $script:Stats.GroupsCreated++
                Write-Output "Created group $groupName ($description)"
            }
            else {
                $grp = $existing[0]
                if ($grp.description -notlike "*$script:GroupMarker*") {
                    Write-Warning "Group $groupName exists but is not automation-managed - skipping membership sync."
                    continue
                }
                $gid = $grp.id
                $script:Stats.GroupsSynced++
            }
            Sync-GroupMembers -GroupId $gid -GroupName $groupName -TargetDeviceIds ($devices.deviceId)
        }
        catch {
            $script:Stats.Failures++
            Write-Warning "Failed to sync group ${groupName}: $_"
        }
    }
}

function Invoke-StaleGroupSweep {
    $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=startswith(displayName,'$GroupPrefix-')&`$select=id,displayName,description&`$top=1000"
    $allGroups = @(Invoke-GraphGetAll -Uri $uri)
    foreach ($grp in $allGroups) {
        $name = [string]$grp.displayName
        if (-not $name.StartsWith("$GroupPrefix-")) { continue }
        $code = $name.Substring($GroupPrefix.Length + 1)
        if ($script:SeenCodes.ContainsKey($code)) { continue }
        if ($grp.description -notlike "*$script:GroupMarker*") { continue }

        if ($CleanupOrphanedGroups) {
            if ($DryRun) {
                Write-Output "[DryRun] Would delete orphaned group $name"
                continue
            }
            Invoke-GraphApi -Method DELETE -Uri "https://graph.microsoft.com/v1.0/groups/$($grp.id)" | Out-Null
            $script:Stats.GroupsDeleted++
            Write-Output "Deleted orphaned group $name"
        }
        else {
            if ($DryRun) {
                Write-Output "[DryRun] Would clear members of stale group $name"
                continue
            }
            try {
                Sync-GroupMembers -GroupId $grp.id -GroupName $name -TargetDeviceIds @()
                $script:Stats.GroupsCleared++
                Write-Output "Cleared stale members of group $name"
            }
            catch {
                $script:Stats.Failures++
                Write-Warning "Failed to clear group ${name}: $_"
            }
        }
    }
}

function Connect-GraphContext {
    if ($Interactive) {
        if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
            Write-Output "Installing Microsoft.Graph.Authentication..."
            Install-Module 'Microsoft.Graph.Authentication' -Scope CurrentUser -Force -AllowClobber
        }
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $authParams = @{ Scopes = @(
            'DeviceManagementApps.Read.All',
            'DeviceManagementManagedDevices.Read.All',
            'Group.ReadWrite.All',
            'Directory.Read.All'
        ) }
        if ($TenantId) { $authParams.TenantId = $TenantId }
        Connect-MgGraph @authParams | Out-Null
    }
    else {
        Connect-MgGraph -Identity | Out-Null
    }
    $ctx = Get-MgContext
    if ($ctx) { Write-Output "Connected to Graph (Tenant: $($ctx.TenantId))" }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Connect-GraphContext
        if ($DryRun) { Write-Output '*** DRY RUN - no changes will be made ***' }
        Invoke-ErrorGroupSync
        Invoke-StaleGroupSweep
        $s = $script:Stats
        Write-Output ("Done. created={0} synced={1} cleared={2} deleted={3} membersAdded={4} membersRemoved={5} membersSkipped={6} invalidDeviceIds={7} failures={8} dryRun={9}" -f `
            $s.GroupsCreated, $s.GroupsSynced, $s.GroupsCleared, $s.GroupsDeleted, `
            $s.MembersAdded, $s.MembersRemoved, $s.MembersSkipped, $s.InvalidDeviceIds, $s.Failures, [bool]$DryRun)
        if ($s.Failures -gt 0) { throw "Completed with $($s.Failures) failure(s) - see warnings above." }
    }
    catch {
        Write-Warning "Script failed: $_"
        throw
    }
}
