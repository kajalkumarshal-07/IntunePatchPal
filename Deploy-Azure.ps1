#Requires -Version 5.1
<#
    One-shot Azure deployment for the IntuneRemediations pipeline.

    Creates: resource group, Automation account (system-assigned identity),
    Microsoft.Graph.Authentication module, both runbooks (imported +
    published), Graph app-role grants for the managed identity, a daily
    schedule linked to both runbooks, and a first dry-run job per runbook
    to prove the identity/module/permissions chain end to end.

    Prerequisites:
      - az CLI signed in (az login) with a REAL subscription in the tenant
      - Global Administrator (or equivalent) for the Graph consent grants

    Run:
      powershell -ExecutionPolicy Bypass -File Deploy-Azure.ps1
      powershell -ExecutionPolicy Bypass -File Deploy-Azure.ps1 -SkipDryRunJob

    Manual steps afterwards (printed by this script):
      - Monitor > Alerts: rule on scheduled job run failures
      - Intune: assign remediations to Intune-PatchError-* / Intune-AppError-*
#>
param(
    [string]$SubscriptionId = '',
    [string]$Location = 'eastus',
    [string]$ResourceGroup = 'RG-IntuneManagement',
    [string]$AutomationAccount = 'AA-IntunePatchAutomation',
    [string]$Sku = 'Free',
    [string]$ScheduleName = 'Daily-0600',
    [string]$TimeZone = 'India Standard Time',
    [int]$ScheduleHour = 6,
    [string]$ExpectedTenantId = '',
    [switch]$SkipDryRunJob
)

$ErrorActionPreference = 'Stop'
[System.Diagnostics.Trace]::Listeners.Clear()
$ProgressPreference = 'SilentlyContinue'
$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$Api = '2023-11-01'
$GraphRoles = @(
    'DeviceManagementApps.Read.All'
    'DeviceManagementConfiguration.ReadWrite.All'
    'DeviceManagementManagedDevices.Read.All'
    'Directory.Read.All'
    'Group.ReadWrite.All'
)

function Say { param([string]$Message) Write-Output $Message }

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$ArgList)
    # PS 5.1: redirected native stderr becomes terminating under EAP=Stop -
    # lower it around the call and judge success by exit code only.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & az @ArgList 2>&1 }
    finally { $ErrorActionPreference = $prevEap }
    if ($LASTEXITCODE -ne 0) {
        throw ("az {0} failed:`n{1}" -f ($ArgList[0..([Math]::Min(3, $ArgList.Count - 1))] -join ' '), (($out | Out-String).Trim()))
    }
    return ($out | Out-String).Trim()
}

function Invoke-AzRest {
    param([string]$Method, [Parameter(Mandatory)][string]$Uri, [string]$Body)
    $azArgs = @('rest', '--method', $Method, '--uri', $Uri, '--only-show-errors')
    $bodyFile = $null
    if ($Body) {
        # az.cmd (batch wrapper) strips embedded quotes from inline --body
        # JSON - pass the body via @file so quoting survives.
        $bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) ('az-body-' + [guid]::NewGuid().ToString('N') + '.json')
        Set-Content -LiteralPath $bodyFile -Value $Body -Encoding ASCII
        $azArgs += @('--headers', 'Content-Type=application/json', '--body', ('@' + $bodyFile))
    }
    try { return Invoke-Az -ArgList $azArgs }
    finally { if ($bodyFile) { Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue } }
}

function Get-UriOrNull {
    param([string]$Uri)
    $azArgs = @('rest', '--method', 'get', '--uri', $Uri, '--only-show-errors')
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & az @azArgs 2>&1 }
    finally { $ErrorActionPreference = $prevEap }
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($out | Out-String)
}

# ------------------------------------------------------------ preflight ---
Say '=== step 0: preflight ==='
& az --version --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'az CLI not found - install Azure CLI first.' }

# Query ARM directly: `az account list` can serve a stale cache right after
# a new subscription is created (--refresh below also busts that cache so
# `az account set` accepts the id).
$null = Invoke-Az -ArgList @('account', 'list', '--refresh', '-o', 'none', '--only-show-errors')
$subsJson = Invoke-AzRest -Method get -Uri 'https://management.azure.com/subscriptions?api-version=2020-01-01'
$usable = @(($subsJson | ConvertFrom-Json).value | Where-Object { $_.state -eq 'Enabled' })
if ($usable.Count -eq 0) {
    throw @"
No enabled Azure subscription visible to this login - production deployment needs one.
Create/verify it (2 minutes):
  1. Open https://portal.azure.com -> Subscriptions (sign in with the Intune tenant's Global Administrator account)
  2. Add subscription: Pay-As-You-Go (card required) or Free trial ($200/30 days)
  3. Finish any 'Pending' payment verification
  4. Re-run this script
"@
}
if ($SubscriptionId) {
    $pick = @($usable | Where-Object { $_.subscriptionId -eq $SubscriptionId })
    if (-not $pick) { throw "Subscription $SubscriptionId not found or not Enabled." }
}
else { $SubscriptionId = $usable[0].subscriptionId }

Invoke-Az -ArgList @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
$tenantId = (Invoke-Az -ArgList @('account', 'show', '--query', 'tenantId', '-o', 'tsv'))
if ($ExpectedTenantId -and $tenantId -ne $ExpectedTenantId) {
    throw "Signed-in tenant $tenantId does not match -ExpectedTenantId $ExpectedTenantId. Run az login --tenant $ExpectedTenantId first."
}
Say "tenant: $tenantId"
$subId = $SubscriptionId
$base = "https://management.azure.com/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$AutomationAccount"
Say "subscription: $subId"

# ------------------------------------------------------- resource group ---
Say '=== step 1: resource group ==='
Invoke-Az -ArgList @('group', 'create', '--name', $ResourceGroup, '--location', $Location, '--only-show-errors') | Out-Null
Say "resource group ready: $ResourceGroup ($Location)"

# ----------------------------------------------------- automation account ---
Say '=== step 2: automation account ==='
$accJson = Get-UriOrNull -Uri "$base`?api-version=$Api"
if (-not $accJson) {
    Invoke-Az -ArgList @('automation', 'account', 'create',
        '--name', $AutomationAccount, '--resource-group', $ResourceGroup,
        '--location', $Location, '--sku', $Sku, '--only-show-errors') | Out-Null
    Say "automation account created: $AutomationAccount (sku=$Sku)"
}
else { Say "automation account exists: $AutomationAccount" }

# ---------------------------------------------------- managed identity -----
Say '=== step 3: system-assigned managed identity ==='
$accJson = Get-UriOrNull -Uri "$base`?api-version=$Api"
$principalId = ($accJson | ConvertFrom-Json).identity.principalId
if (-not $principalId) {
    Invoke-AzRest -Method patch -Uri "$base`?api-version=$Api" -Body '{"identity":{"type":"SystemAssigned"}}' | Out-Null
    $accJson = Get-UriOrNull -Uri "$base`?api-version=$Api"
    $principalId = ($accJson | ConvertFrom-Json).identity.principalId
}
if (-not $principalId) { throw 'Could not enable the system-assigned managed identity.' }
Say "identity principalId: $principalId"

# ------------------------------------------------------ graph module -------
Say '=== step 4: Microsoft.Graph.Authentication module ==='
$modUri = "$base/modules/Microsoft.Graph.Authentication?api-version=$Api"
$modJson = Get-UriOrNull -Uri $modUri
if (-not $modJson) {
    $modBody = '{"properties":{"contentLink":{"uri":"https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Authentication"}}}'
    Invoke-AzRest -Method put -Uri $modUri -Body $modBody | Out-Null
    Say 'module import started (pulling from PowerShell Gallery + dependencies)...'
}
$deadline = (Get-Date).AddMinutes(15)
while ($true) {
    $modJson = Get-UriOrNull -Uri $modUri
    $state = $null
    if ($modJson) { $state = ($modJson | ConvertFrom-Json).properties.provisioningState }
    if ($state -in 'Completed', 'Succeeded') { break }
    if ($state -in 'Failed', 'Cancelled') { throw "Module import failed (state=$state) - check portal > Modules." }
    if ((Get-Date) -gt $deadline) { throw "Module import still '$state' after 15 min - check portal > Modules." }
    Start-Sleep -Seconds 15
}
Say 'module ready: Microsoft.Graph.Authentication'

# --------------------------------------------------------- runbooks --------
Say '=== step 5: import + publish runbooks ==='
$runbooks = @(
    @{ Name = 'IntuneUpdateErrorGroups'; Path = (Join-Path $repo 'IntuneUpdateErrorGroups.ps1') },
    @{ Name = 'IntuneAppErrorGroups'; Path = (Join-Path $repo (Join-Path 'App' 'IntuneAppErrorGroups.ps1')) }
)
foreach ($rb in $runbooks) {
    if (-not (Test-Path -LiteralPath $rb.Path)) { throw "Runbook source missing: $($rb.Path)" }
    $rbUri = "$base/runbooks/$($rb.Name)?api-version=$Api"
    if (-not (Get-UriOrNull -Uri $rbUri)) {
        Invoke-Az -ArgList @('automation', 'runbook', 'create',
            '--resource-group', $ResourceGroup, '--automation-account-name', $AutomationAccount,
            '--name', $rb.Name, '--type', 'PowerShell', '--only-show-errors') | Out-Null
    }
    Invoke-Az -ArgList @('automation', 'runbook', 'replace-content',
        '--resource-group', $ResourceGroup, '--automation-account-name', $AutomationAccount,
        '--name', $rb.Name, '--content', ('@' + $rb.Path), '--only-show-errors') | Out-Null
    Invoke-Az -ArgList @('automation', 'runbook', 'publish',
        '--resource-group', $ResourceGroup, '--automation-account-name', $AutomationAccount,
        '--name', $rb.Name, '--only-show-errors') | Out-Null
    Say "published: $($rb.Name)"
}

# --------------------------------------------- graph app-role grants -------
Say '=== step 6: grant Graph roles to the managed identity ==='
$graphFilter = 'https://graph.microsoft.com/v1.0/servicePrincipals?$filter=appId eq ''00000003-0000-0000-c000-000000000000''&$select=id,appRoles'
$graphSp = ((Invoke-AzRest -Method get -Uri $graphFilter) | ConvertFrom-Json).value[0]
if (-not $graphSp) { throw 'Microsoft Graph service principal not found in tenant.' }
$roleIds = @{}
foreach ($r in $graphSp.appRoles) { if ($r.value -in $GraphRoles -and $r.isEnabled) { $roleIds[$r.value] = $r.id } }
$missing = @($GraphRoles | Where-Object { -not $roleIds.ContainsKey($_) })
if ($missing.Count -gt 0) { throw "Graph app roles not found: $($missing -join ', ')" }

$assignUri = "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments?`$select=appRoleId"
$existing = @()
$assignJson = Get-UriOrNull -Uri $assignUri
if ($assignJson) { $existing = @(($assignJson | ConvertFrom-Json).value | ForEach-Object { $_.appRoleId }) }
foreach ($roleName in $GraphRoles) {
    if ($roleIds[$roleName] -in $existing) { Say "  role present: $roleName"; continue }
    $grantBody = (@{ principalId = $principalId; resourceId = $graphSp.id; appRoleId = $roleIds[$roleName] } | ConvertTo-Json -Compress)
    Invoke-AzRest -Method post -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" -Body $grantBody | Out-Null
    Say "  granted: $roleName"
}

# --------------------------------------------------------- schedule --------
Say '=== step 7: daily schedule ==='
$schedUri = "$base/schedules/${ScheduleName}?api-version=$Api"
if (-not (Get-UriOrNull -Uri $schedUri)) {
    $start = (Get-Date).Date.AddDays(1).AddHours($ScheduleHour).ToString('yyyy-MM-dd HH:mm:ss')
    try {
        Invoke-Az -ArgList @('automation', 'schedule', 'create',
            '--resource-group', $ResourceGroup, '--automation-account-name', $AutomationAccount,
            '--name', $ScheduleName, '--frequency', 'Day', '--interval', '1',
            '--start-time', $start, '--time-zone', $TimeZone, '--only-show-errors') | Out-Null
    }
    catch {
        $tzi = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZone)
        $off = $tzi.GetUtcOffset([DateTime]::Now)
        $sign = if ($off.TotalMinutes -ge 0) { '+' } else { '-' }
        $startOff = ((Get-Date).Date.AddDays(1).AddHours($ScheduleHour).ToString('yyyy-MM-dd HH:mm:ss')) +
            (' {0}{1:00}:{2:00}' -f $sign, [math]::Abs($off.Hours), [math]::Abs($off.Minutes))
        Invoke-Az -ArgList @('automation', 'schedule', 'create',
            '--resource-group', $ResourceGroup, '--automation-account-name', $AutomationAccount,
            '--name', $ScheduleName, '--frequency', 'Day', '--interval', '1',
            '--start-time', $startOff, '--only-show-errors') | Out-Null
    }
    Say "schedule created: $ScheduleName (daily ${ScheduleHour}:00, $TimeZone)"
}
else { Say "schedule exists: $ScheduleName" }

# -------------------------------------------------- schedule -> runbooks ----
Say '=== step 8: link schedule to both runbooks ==='
# jobSchedules needs a GUID resource name + name-based (not ARM-id) refs.
function Get-DeterministicGuid {
    param([Parameter(Mandatory)][string]$Text)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try { $hash = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) }
    finally { $md5.Dispose() }
    return [System.Guid]::new($hash)
}
foreach ($rb in $runbooks) {
    $jsGuid = Get-DeterministicGuid -Text "$ScheduleName-$($rb.Name)"
    $jsUri = "$base/jobSchedules/${jsGuid}?api-version=$Api"
    $jsBody = (@{
            properties = @{
                schedule = @{ name = $ScheduleName }
                runbook  = @{ name = $rb.Name }
            }
        } | ConvertTo-Json -Compress -Depth 5)
    Invoke-AzRest -Method put -Uri $jsUri -Body $jsBody | Out-Null
    Say "linked: $($rb.Name) -> $ScheduleName (jobSchedule $jsGuid)"
}

# ------------------------------------------------- first dry-run jobs -------
if (-not $SkipDryRunJob) {
    Say '=== step 9: first dry-run job per runbook (managed identity proof) ==='
    foreach ($rb in $runbooks) {
        $jobId = [guid]::NewGuid().ToString()
        $jobUri = "$base/jobs/${jobId}?api-version=$Api"
        $jobBody = (@{ properties = @{ runbook = @{ name = $rb.Name }; parameters = @{ DryRun = 'true' } } } | ConvertTo-Json -Compress -Depth 5)
        Invoke-AzRest -Method put -Uri $jobUri -Body $jobBody | Out-Null
        Say "job started: $($rb.Name) (dry run, waiting up to 15 min...)"
        $deadline = (Get-Date).AddMinutes(15)
        $status = 'New'
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 15
            $j = Get-UriOrNull -Uri $jobUri
            if (-not $j) { continue }
            $status = ($j | ConvertFrom-Json).properties.status
            if ($status -in 'Completed', 'Failed', 'Stopped', 'Suspended', 'Blocking', 'Terminating') { break }
        }
        if ($status -eq 'Completed') { Say "  job $($rb.Name): Completed (dry run OK)" }
        else {
            Say "  job $($rb.Name): $status"
            $streams = Get-UriOrNull -Uri "$base/jobs/$jobId/streams?api-version=$Api"
            if ($streams) {
                $lines = @(($streams | ConvertFrom-Json).value | Sort-Object { $_.properties.time } | ForEach-Object { $_.properties.text })
                $lines | Select-Object -Last 40 | ForEach-Object { Say "    | $_" }
            }
            if ($status -ne 'Completed') {
                Say "  portal: https://portal.azure.com/#@/resource$base/runbooks"
            }
        }
    }
}

# ------------------------------------------------------------- summary -----
Say ''
Say '=== DEPLOYED ==='
Say "account : $AutomationAccount ($ResourceGroup, $Location)"
Say "identity: $principalId (Graph roles granted: $($GraphRoles.Count))"
Say "schedule: $ScheduleName -> both runbooks (daily ${ScheduleHour}:00 $TimeZone)"
Say ''
Say 'Remaining manual steps:'
Say ' 1. Monitor > Alerts on the Automation Account: condition "scheduled job run failures" + your action group (email/Teams).'
Say ' 2. Intune > Remediations: assign detection+remediation scripts to Intune-PatchError-* / Intune-AppError-* groups.'
Say ' 3. Optional: portal > Runbooks > Start with DryRun=True to preview before tomorrow 06:00.'
