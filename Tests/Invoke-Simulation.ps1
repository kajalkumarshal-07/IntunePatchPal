#Requires -Version 5.1
<#
    Live group-creation simulation.

    Injects synthetic failure rows into the REAL runbook logic (only the
    report/fetch layer is replaced) and executes it against the live tenant:

      phase 0  preview    -DryRun: would-create lines, nothing written
      phase 1  create     real: creates Intune-* groups with the ownership
                          marker and real directory members
      phase 2  verify     reads groups + members back from Graph
      phase 3  rerun      idempotency: created=0, membersAdded=0
      phase 4  recovery   one code stops failing -> sweep clears its members
      phase 5  final      end state printed (groups stay in the tenant)

    Run:   powershell -ExecutionPolicy Bypass -File Tests\Invoke-Simulation.ps1 -Lane Patch
           powershell -ExecutionPolicy Bypass -File Tests\Invoke-Simulation.ps1 -Lane App
    Auth:  reuses the E2E token cache (silent refresh; launch
           Tests\Invoke-LiveE2E.ps1 once first if the cache is gone).
    Clean: add -Cleanup to delete this lane's groups after the run.
#>
param(
    [ValidateSet('Patch', 'App')][string]$Lane = 'Patch',
    [switch]$Cleanup
)

$ErrorActionPreference = 'Stop'
[System.Diagnostics.Trace]::Listeners.Clear()
$ProgressPreference = 'SilentlyContinue'
$repo = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------- auth ----
function Decode-Jwt {
    param([string]$Jwt)
    $p = ($Jwt -split '\.')[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
}

$clientId = 'b0503117-8d91-4498-b03a-fc3fd640f6c1'
$tenant = '95907809-e9d7-4181-bc43-ed3f11297890'
$scopes = @('Group.ReadWrite.All', 'Directory.Read.All', 'DeviceManagementManagedDevices.Read.All')
$tokenUrl = "https://login.microsoftonline.com/$tenant/oauth2/v2.0"
$tokenFile = Join-Path ([System.IO.Path]::GetTempPath()) 'IntuneRemediations-E2E.token'
$accessToken = $null

if (Test-Path -LiteralPath $tokenFile) {
    try {
        $cached = Get-Content -LiteralPath $tokenFile -Raw | ConvertFrom-Json
        $cj = Decode-Jwt $cached.access_token
        $have = @([string]$cj.scp -split ' ')
        $missing = @($scopes | Where-Object { $_ -notin $have })
        if ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -lt ([long]$cj.exp - 300) -and $missing.Count -eq 0) {
            $accessToken = $cached.access_token
            Write-Output 'auth: reusing cached access token.'
        }
        elseif ($cached.refresh_token) {
            $rt = Invoke-RestMethod -Method Post -Uri "$tokenUrl/token" -Body @{
                grant_type    = 'refresh_token'
                client_id     = $clientId
                refresh_token = $cached.refresh_token
                scope         = (@('openid', 'offline_access') + $scopes) -join ' '
            } -TimeoutSec 30
            $accessToken = $rt.access_token
            try { Set-Content -LiteralPath $tokenFile -Value (@{ access_token = $rt.access_token; refresh_token = $rt.refresh_token } | ConvertTo-Json -Compress) -Encoding ASCII } catch { }
            Write-Output 'auth: refreshed access token.'
        }
    }
    catch { Write-Warning "auth: token cache unusable: $($_.Exception.Message)" }
}
if (-not $accessToken) {
    throw 'No usable token - run Tests\Invoke-LiveE2E.ps1 once to sign in, then retry.'
}

Import-Module Microsoft.Graph.Authentication -Force
Connect-MgGraph -AccessToken (ConvertTo-SecureString $accessToken -AsPlainText -Force) -NoWelcome -ErrorAction Stop
$ctx = Get-MgContext
if (-not $ctx) { throw 'Connect-MgGraph produced no context.' }
Write-Output "auth: connected account=$($ctx.Account) tenant=$($ctx.TenantId)"

# ------------------------------------------------------- load runbook ----
# Dot-source loads the functions; the runbook main block is guarded.
# Its param defaults rebind $DryRun/$GroupPrefix here - capture ours first.
if ($Lane -eq 'Patch') { . (Join-Path $repo 'IntuneUpdateErrorGroups.ps1') }
else { . (Join-Path $repo 'App\IntuneAppErrorGroups.ps1') }
$DryRun = $false

# ----------------------------------------- real directory member target --
# NOTE: @(cmd).value collapses to the single item hashtable here - always
# take ['value'] off the response and wrap it yourself.
$devResp = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/devices?$top=1&$select=id,displayName'
$candidates = @($devResp['value'] | Where-Object { $_ })
if ($candidates.Count -eq 0) {
    $usrResp = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/users?$top=1&$select=id,displayName'
    $candidates = @($usrResp['value'] | Where-Object { $_ })
    if ($candidates.Count -eq 0) { throw 'No directory object available to simulate members.' }
}
$obj = $candidates[0]
if ($obj -is [System.Collections.IDictionary]) {
    $memberId = [string]$obj['id']; $memberName = [string]$obj['displayName']
}
else {
    $memberId = [string]$obj.id; $memberName = [string]$obj.displayName
}
Write-Output "member: $memberName ($memberId)"

# ------------------------------------------------- synthetic fetch -------
# Only the report layer is replaced; grouping/creation/marker/sync/sweep
# all run from the real runbook code.
$script:SimCodes = @()
$script:SimMember = $memberId
$script:SimMemberName = $memberName

if ($Lane -eq 'Patch') {
    function Get-FailedUpdateStates {
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($c in $script:SimCodes) {
            $rows.Add([pscustomobject]@{
                    deviceId    = $script:SimMember
                    deviceName  = "$script:SimMemberName (simulated)"
                    errorCode   = $c.code
                    status      = 'failed'
                    description = $c.desc
                    policyId    = 'simulated-policy'
                })
        }
        return $rows
    }
    $script:AllSimCodes = @(
        @{ code = '-2147012855'; desc = 'Network timeout' },
        @{ code = '-2147010798'; desc = 'Component store corrupted' }
    )
}
else {
    function Get-FailedAppStatuses {
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($c in $script:SimCodes) {
            $rows.Add([pscustomobject]@{
                    deviceId  = $script:SimMember
                    appName   = 'SimulatedApp'
                    errorCode = $c.code
                })
        }
        return $rows
    }
    $script:AllSimCodes = @(
        @{ code = '1618'; desc = 'Another install already running' },
        @{ code = '1603'; desc = 'Fatal installation error' }
    )
}
$script:SimCodes = $script:AllSimCodes

# ------------------------------------------------------------ helpers ----
function Reset-SimStats {
    $script:Stats = @{
        GroupsCreated    = 0
        GroupsSynced     = 0
        GroupsCleared    = 0
        GroupsDeleted    = 0
        MembersAdded     = 0
        MembersRemoved   = 0
        MembersSkipped   = 0
        InvalidDeviceIds = 0
        Failures         = 0
    }
}

function Show-SimStats {
    param([string]$Phase)
    $s = $script:Stats
    Write-Output ("stats[{0}]: created={1} synced={2} cleared={3} deleted={4} membersAdded={5} membersRemoved={6} skipped={7} invalidIds={8} failures={9}" -f `
            $Phase, $s.GroupsCreated, $s.GroupsSynced, $s.GroupsCleared, $s.GroupsDeleted, `
            $s.MembersAdded, $s.MembersRemoved, $s.MembersSkipped, $s.InvalidDeviceIds, $s.Failures)
}

function Show-TenantGroups {
    $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=startswith(displayName,'$GroupPrefix-')&`$select=id,displayName,description"
    $groups = @(Invoke-GraphGetAll -Uri $uri)
    if ($groups.Count -eq 0) {
        Write-Output "tenant: no $GroupPrefix-* groups exist."
        return
    }
    foreach ($g in $groups) {
        $marker = if ($g.description -like '*Managed by automation*') { 'marker=yes' } else { 'marker=NO' }
        Write-Output ("tenant: {0}  [{1}]  id={2}" -f $g.displayName, $marker, $g.id)
        Write-Output ("        desc: {0}" -f $g.description)
        $m = @(Invoke-GraphGetAll -Uri "https://graph.microsoft.com/v1.0/groups/$($g.id)/members?`$select=id,displayName&`$top=999")
        if ($m.Count -eq 0) { Write-Output '        members: 0' }
        else { foreach ($x in $m) { Write-Output "        member: $($x.displayName) ($($x.id))" } }
    }
}

# ======================================================= simulation ======
Write-Output "=== SIMULATION [$Lane] ==="

Reset-SimStats
$DryRun = $true
Write-Output '--- phase 0: dry-run preview (no writes) ---'
Invoke-ErrorGroupSync
Invoke-StaleGroupSweep
Show-SimStats 'preview'
$DryRun = $false

Reset-SimStats
Write-Output '--- phase 1: create (real writes) ---'
Invoke-ErrorGroupSync
Invoke-StaleGroupSweep
Show-SimStats 'create'

Write-Output '--- phase 2: verify from Graph ---'
Show-TenantGroups

Reset-SimStats
Write-Output '--- phase 3: re-run (idempotency) ---'
Invoke-ErrorGroupSync
Invoke-StaleGroupSweep
Show-SimStats 'rerun'

$script:SimCodes = @($script:AllSimCodes[0])
Reset-SimStats
Write-Output '--- phase 4: recovery (second code gone -> sweep clears its members) ---'
Invoke-ErrorGroupSync
Invoke-StaleGroupSweep
Show-SimStats 'recovery'

Write-Output '--- phase 5: final tenant state ---'
Show-TenantGroups

if ($Cleanup) {
    Write-Output '--- cleanup: deleting simulation groups ---'
    $script:SimCodes = @()
    $script:SeenCodes = @{}
    $CleanupOrphanedGroups = $true
    Reset-SimStats
    Invoke-StaleGroupSweep
    Show-SimStats 'cleanup'
}

Write-Output "=== SIMULATION [$Lane] DONE ==="
