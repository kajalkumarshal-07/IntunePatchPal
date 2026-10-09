#Requires -Version 5.1
<#
    Creates one Entra group AND one Intune remediation per known error code:

      - Group: Intune-PatchError-<code> / Intune-AppError-<code>
        (marker "Managed by automation" - the nightly runbook adopts and
        curates membership from there; empty pre-created groups are safe)
      - Remediation (Intune > Remediations, beta deviceHealthScripts):
        DetectionTemplate.ps1 + RemediationTemplate.ps1 with the code baked
        into the param defaults (Intune cannot pass parameters), assigned
        to that group, running as SYSTEM.

    Codes without a targeted device check get a deploy-time injected case
    (never a repo edit): detection reports non-compliant for curated group
    members, remediation writes report-only guidance. Verified by
    -WhatIf-style baked-content preview and live Graph readback.

    Idempotent: re-running updates script content/assignments in place.

    Auth: reuses the E2E token cache (silent refresh with the full scope
    set). Run Tests\Invoke-LiveE2E.ps1 once first if the cache is gone.
#>
param(
    [ValidateSet('Patch', 'App', 'Both')][string]$Lane = 'Both',
    [switch]$SkipRemediations,
    [string]$TenantId = ''
)

$ErrorActionPreference = 'Stop'
[System.Diagnostics.Trace]::Listeners.Clear()
$ProgressPreference = 'SilentlyContinue'
$repo = $PSScriptRoot

# ---------------------------------------------------------------- auth ----
function Decode-Jwt {
    param([string]$Jwt)
    $p = ($Jwt -split '\.')[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
}

$clientId = 'b0503117-8d91-4498-b03a-fc3fd640f6c1'
$homeTenant = '95907809-e9d7-4181-bc43-ed3f11297890'   # E2E app lives here - cache reuse only
$scopes = @(
    'DeviceManagementManagedDevices.Read.All',
    'DeviceManagementApps.Read.All',
    'DeviceManagementConfiguration.ReadWrite.All',
    'DeviceManagementScripts.ReadWrite.All',
    'Group.ReadWrite.All',
    'Directory.Read.All'
)
$tokenFile = Join-Path ([System.IO.Path]::GetTempPath()) 'IntuneRemediations-E2E.token'
$accessToken = $null

# --- tenant discovery (portable: works on any tenant) ---
if (-not $TenantId) {
    if (Get-Command az -ErrorAction SilentlyContinue) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $TenantId = (& az account show --query tenantId -o tsv 2>$null | Out-String).Trim()
        $ErrorActionPreference = $prev
    }
    if (-not $TenantId -and (Test-Path -LiteralPath $tokenFile)) {
        try {
            $cj0 = Decode-Jwt (Get-Content -LiteralPath $tokenFile -Raw | ConvertFrom-Json).access_token
            $TenantId = [string]$cj0.tid
        }
        catch { }
    }
    if (-not $TenantId) { throw 'Cannot detect the tenant - run az login, or pass -TenantId <guid>.' }
}
$tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0"
Write-Output "auth: target tenant $TenantId"

# --- home-tenant cache reuse (other tenants go straight to interactive) ---
if ($TenantId -eq $homeTenant -and (Test-Path -LiteralPath $tokenFile)) {
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
    Write-Output "auth: opening interactive sign-in for tenant $TenantId (accept the consent prompt once)..."
    Import-Module Microsoft.Graph.Authentication -Force
    $null = Connect-MgGraph -TenantId $TenantId -Scopes $scopes -NoWelcome -ErrorAction Stop
}
else {
    Import-Module Microsoft.Graph.Authentication -Force
    Connect-MgGraph -AccessToken (ConvertTo-SecureString $accessToken -AsPlainText -Force) -NoWelcome -ErrorAction Stop
}
$ctx = Get-MgContext
if (-not $ctx) { throw 'Connect-MgGraph produced no context.' }
Write-Output "auth: connected account=$($ctx.Account) tenant=$($ctx.TenantId)"

# --------------------------------------------------------- graph helper ---
$script:GraphCalls = 0
function Invoke-Graph {
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        $BodyObject = $null
    )
    for ($try = 1; $try -le 4; $try++) {
        $script:GraphCalls++
        try {
            if ($null -ne $BodyObject) {
                return Invoke-MgGraphRequest -Method $Method -Uri $Uri -Body $BodyObject -ContentType 'application/json'
            }
            return Invoke-MgGraphRequest -Method $Method -Uri $Uri
        }
        catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            if ($try -lt 4 -and ($status -eq 429 -or $null -eq $status -or $status -ge 500)) {
                Start-Sleep -Seconds ([Math]::Min(20, 2 * $try))
                continue
            }
            throw
        }
    }
}

function Get-GraphValue {
    # Single-page fetch helper for our small result sets.
    # Unary comma: PowerShell unwraps single-element arrays across function
    # returns - without it a 1-item result arrives as a bare hashtable and
    # indexing [0] becomes a key lookup (null -> "not a guid" downstream).
    param([Parameter(Mandatory)][string]$Uri)
    $resp = Invoke-Graph -Uri $Uri
    $v = $resp['value']
    if ($null -eq $v) { return ,@() }
    return ,@($v | Where-Object { $_ })
}

# ------------------------------------------------------ code catalog -----
function Get-DocCodes {
    # ERROR-REFERENCE.md table rows: | `<code>` | `0x…` | meaning | ...
    param([Parameter(Mandatory)][string]$Path)
    $map = [ordered]@{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -notmatch '^\|\s*`(-?\d+)`') { continue }
        $cols = $line -split '\|'
        $code = $cols[1].Trim().Trim('`')
        $meaning = $cols[3].Trim()
        if ([string]::IsNullOrWhiteSpace($meaning)) { $meaning = "error $code" }
        $meaning = ($meaning -replace '\|', '/').Trim()
        if (-not $map.Contains($code)) { $map[$code] = $meaning }
    }
    return $map
}

# -------------------------------------------------------- bake helper ----
function Get-BakedContent {
    # Bakes the code into the template param default. If the targeted switch
    # has no case for the code, injects one (deploy-time only - repo stays
    # untouched): detection = non-compliant for curated members, remediation
    # = report-only guidance.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ParamOld,
        [Parameter(Mandatory)][string]$ParamNew,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Meaning,
        [Parameter(Mandatory)][ValidateSet('Detection', 'Remediation')][string]$Kind
    )
    $lines = @(Get-Content -LiteralPath $Path)
    $hasCase = [bool]($lines | Where-Object { $_ -match ("'" + [regex]::Escape($Code) + "'\s*\{") })
    $lines = @($lines | ForEach-Object { $_.Replace($ParamOld, $ParamNew) })
    $Meaning = $Meaning -replace "'", ''

    if (-not $hasCase) {
        if ($Kind -eq 'Detection') {
            $inject = @(
                "            '$Code' {"
                "                Exit-NonCompliant `$TargetErrorCode 'Curated group member - Intune failure report drives membership; runbook clears it when fixed'"
                '            }'
            )
            $anchor = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*default \{ Exit-Compliant \}\s*$') { $anchor = $i; break }
            }
            if ($anchor -lt 0) { throw "Detection anchor not found in $Path" }
            $lines = @($lines[0..($anchor - 1)]) + $inject + @($lines[$anchor..($lines.Count - 1)])
        }
        else {
            $failIdx = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match 'Exit-Failure "No remediation defined') { $failIdx = $i; break }
            }
            if ($failIdx -lt 0) { throw "Remediation anchor not found in $Path" }
            $anchor = $failIdx - 1
            while ($anchor -gt 0 -and $lines[$anchor] -notmatch '^\s*default \{\s*$') { $anchor-- }
            if ($anchor -le 0) { throw "Remediation default block not found in $Path" }
            $inject = @(
                "        '$Code' {"
                "            Write-Log 'Remediating: $Meaning (report-only)'"
                "            Write-Output 'ReportOnly|$Meaning - guidance: see ERROR-REFERENCE.md'"
                '        }'
                ''
            )
            $lines = @($lines[0..($anchor - 1)]) + $inject + @($lines[$anchor..($lines.Count - 1)])
        }
    }
    return ($lines -join "`r`n")
}

function Convert-ToB64 {
    param([Parameter(Mandatory)][string]$Text)
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

# ------------------------------------------------------------ deploy -----
$marker = 'Managed by automation'
$laneDefs = @()
if ($Lane -in @('Patch', 'Both')) {
    $laneDefs += [pscustomobject]@{
        Name          = 'Patch'
        Prefix        = 'Intune-PatchError'
        DescPrefix    = 'Intune update patch failures'
        GroupPrefix   = 'Intune-PatchError'
        DetectPath    = Join-Path $repo 'DetectionTemplate.ps1'
        RemediatePath = Join-Path $repo 'RemediationTemplate.ps1'
        DocPath       = Join-Path $repo 'ERROR-REFERENCE.md'
    }
}
if ($Lane -in @('App', 'Both')) {
    $laneDefs += [pscustomobject]@{
        Name          = 'App'
        Prefix        = 'Intune-AppError'
        DescPrefix    = 'Intune app install failures'
        GroupPrefix   = 'Intune-AppError'
        DetectPath    = Join-Path $repo 'App\DetectionTemplate.ps1'
        RemediatePath = Join-Path $repo 'App\RemediationTemplate.ps1'
        DocPath       = Join-Path $repo 'App\ERROR-REFERENCE.md'
    }
}

$beta = 'https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts'
$v1 = 'https://graph.microsoft.com/v1.0'

$existingScripts = @{}
$allScripts = Get-GraphValue -Uri "$beta`?`$top=999"
foreach ($s in $allScripts) { $existingScripts[[string]$s.displayName] = $s }

$stats = [ordered]@{ GroupsCreated = 0; GroupsReused = 0; ScriptsCreated = 0; ScriptsUpdated = 0; Assignments = 0; Injected = 0; Errors = 0 }

foreach ($laneDef in $laneDefs) {
    $codes = Get-DocCodes -Path $laneDef.DocPath
    Write-Output ""
    Write-Output ("=== lane {0}: {1} error codes from {2} ===" -f $laneDef.Name, $codes.Count, (Split-Path $laneDef.DocPath -Leaf))

    $detTemplate = Get-Content -LiteralPath $laneDef.DetectPath -Raw
    $remTemplate = Get-Content -LiteralPath $laneDef.RemediatePath -Raw
    if ($detTemplate -notmatch [regex]::Escape('[string]$TargetErrorCode = ""')) { throw "Param anchor missing in $($laneDef.DetectPath)" }
    if ($remTemplate -notmatch [regex]::Escape('[string]$ErrorCode = ""')) { throw "Param anchor missing in $($laneDef.RemediatePath)" }

    foreach ($code in $codes.Keys) {
        $meaning = $codes[$code]
        $groupName = "$($laneDef.GroupPrefix)-$code"
        try {
            # ---- group (runbook-compatible naming + marker) ----
            $filter = [uri]::EscapeDataString("displayName eq '$groupName'")
            $found = Get-GraphValue -Uri "$v1/groups?`$filter=$filter&`$select=id,displayName&`$top=1"
            if ($found.Count -gt 0) {
                $groupId = [string]$found[0].id
                $stats.GroupsReused++
            }
            else {
                $gBody = @{
                    displayName     = $groupName
                    mailEnabled     = $false
                    mailNickname    = $groupName
                    securityEnabled = $true
                    description     = "$($laneDef.DescPrefix) | Error code: $code | $meaning | $marker"
                }
                $created = Invoke-Graph -Method POST -Uri "$v1/groups" -BodyObject $gBody
                $groupId = [string]$created['id']
                $stats.GroupsCreated++
            }

            if ($SkipRemediations) {
                Write-Output ("  {0,-24} group {1}" -f $code, $groupId)
                continue
            }

            # ---- bake detection + remediation with the code ----
            $det = Get-BakedContent -Path $laneDef.DetectPath -ParamOld '[string]$TargetErrorCode = ""' -ParamNew "[string]`$TargetErrorCode = '$code'" -Code $code -Meaning $meaning -Kind Detection
            $rem = Get-BakedContent -Path $laneDef.RemediatePath -ParamOld '[string]$ErrorCode = ""' -ParamNew "[string]`$ErrorCode = '$code'" -Code $code -Meaning $meaning -Kind Remediation
            foreach ($content in @($det, $rem)) {
                if ($content -notmatch [regex]::Escape("'$code'")) { throw "Bake failed for $code" }
            }

            # ---- remediation package (upsert) ----
            $dispName = "$($laneDef.Name) $code - $meaning"
            if ($dispName.Length -gt 200) { $dispName = $dispName.Substring(0, 200) }
            $pkgDesc = "$marker | group: $groupName | $($laneDef.DescPrefix) code $code"
            $pkgBody = @{
                displayName             = $dispName
                description             = $pkgDesc
                detectionScriptContent  = Convert-ToB64 $det
                remediationScriptContent = Convert-ToB64 $rem
                enforceSignatureCheck   = $false
                runAsAccount            = 'system'
            }
            if ($existingScripts.ContainsKey($dispName)) {
                $scriptId = [string]$existingScripts[$dispName].id
                Invoke-Graph -Method PATCH -Uri "$beta/$scriptId" -BodyObject $pkgBody | Out-Null
                $stats.ScriptsUpdated++
            }
            else {
                $pkgBody['isGlobalScript'] = $false
                $newScript = Invoke-Graph -Method POST -Uri $beta -BodyObject $pkgBody
                $scriptId = [string]$newScript['id']
                $existingScripts[$dispName] = $newScript
                $stats.ScriptsCreated++
            }

            # ---- assign to the group ----
            $assignBody = @{
                deviceHealthScriptAssignments = @(
                    @{
                        target = @{
                            '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                            'groupId'     = $groupId
                        }
                    }
                )
            }
            Invoke-Graph -Method POST -Uri "$beta/$scriptId/assign" -BodyObject $assignBody | Out-Null
            $stats.Assignments++
            Write-Output ("  {0,-24} group={1} script={2} assigned" -f $code, $groupId, $scriptId)
        }
        catch {
            $stats.Errors++
            $detail = ''
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
            elseif ($_.Exception.Message) { $detail = $_.Exception.Message }
            Write-Output ("  {0,-24} ERROR: {1}" -f $code, $detail)
        }
    }
}

Write-Output ''
Write-Output ('=== done: groupsCreated={0} groupsReused={1} scriptsCreated={2} scriptsUpdated={3} assignments={4} graphCalls={5} errors={6} ===' -f `
        $stats.GroupsCreated, $stats.GroupsReused, $stats.ScriptsCreated, $stats.ScriptsUpdated, $stats.Assignments, $script:GraphCalls, $stats.Errors)
if ($stats.Errors -gt 0) { exit 1 }
exit 0
