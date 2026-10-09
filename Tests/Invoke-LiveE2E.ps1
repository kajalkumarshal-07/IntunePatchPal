#Requires -Version 5.1
<#
    Live end-to-end harness for the IntuneRemediations pipeline.

    Steps:
      1. Sign in with the AAD device code flow (delegated, tenant scoped)
      2. Diagnose the tenant: Intune data present, do Intune device ids map to
         Entra directory objects, is the Remediations API reachable
      3. Run both runbooks with -DryRun (no directory changes)
      4. Wait for a GO file before applying (skip with -AutoApply)
      5. Apply both runbooks and verify every group/member they created

    Run:   powershell -ExecutionPolicy Bypass -File Tests\Invoke-LiveE2E.ps1 -TenantId <tenant>
    Apply: create the GO file next to the log after reviewing phase A output.

    Exit codes: 0 = complete, 2 = phase A done, no approval received, 1 = failed.
#>
param(
    # Expected Entra tenant id; the run aborts if sign-in lands elsewhere.
    [string]$TenantId = 'organizations',
    [string]$LogPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'IntuneRemediations-E2E.log'),
    # Client id used for device-code sign-in. Defaults to a dedicated app
    # registration (IntuneRemediations-E2E) in this tenant. First-party apps
    # (e.g. d3590ed6 = Microsoft Graph Command Line Tools) CANNOT be used here:
    # they hit AADSTS65002 (first-party-to-first-party preauthorization).
    [string]$ClientId = 'b0503117-8d91-4498-b03a-fc3fd640f6c1',
    [switch]$AutoApply,
    [int]$ApprovalTimeoutSeconds = 1800
)

$ErrorActionPreference = 'Stop'
# Background-safe: a broken console/trace listener must never abort a run
# (WMI-/task-spawned processes inherit no usable console handle).
[System.Diagnostics.Trace]::Listeners.Clear()
$ProgressPreference = 'SilentlyContinue'
$repo = Split-Path -Parent $PSScriptRoot
$goFile = Join-Path (Split-Path -Parent $LogPath) 'IntuneRemediations-E2E-GO'

function Log {
    # File only - this harness runs detached (no reliable console), and a
    # failed console write must never be able to abort a run.
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $script:LogPath -Value $line } catch { }
}

function Decode-Jwt {
    param([string]$Jwt)
    $p = ($Jwt -split '\.')[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
}

function Connect-Interactive {
    # Device code sign-in via raw REST, then Connect-MgGraph -AccessToken.
    # The SDK's own -UseDeviceCode path is broken in background runs: on any
    # token failure Azure.Identity emits an EventSource event whose listener
    # (routed into the cmdlet's async runtime) throws and MASKS the real
    # error as "EventSourceException: An error occurred when writing to a
    # listener". Raw REST keeps every AADSTS error visible in the log.
    param([string[]]$Scopes, [string]$ExpectedTenantId)
    Import-Module Microsoft.Graph.Authentication -Force

    $clientId = $ClientId   # dedicated app registration (see param block)
    $tenant = if ($ExpectedTenantId -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { $ExpectedTenantId } else { 'organizations' }
    $scopeStr = (@('openid', 'offline_access') + $Scopes) -join ' '
    $tokenUrl = "https://login.microsoftonline.com/$tenant/oauth2/v2.0"
    $body = @{ client_id = $clientId; scope = $scopeStr }

    $tokenFile = Join-Path (Split-Path -Parent $script:LogPath) 'IntuneRemediations-E2E.token'
    $accessToken = $null

    function Save-TokenCache {
        param([string]$Access, [string]$Refresh)
        $obj = @{ access_token = $Access }
        if ($Refresh) { $obj.refresh_token = $Refresh }
        try { Set-Content -LiteralPath $tokenFile -Value ($obj | ConvertTo-Json -Compress) -Encoding ASCII } catch { }
    }

    # A still-valid token from an earlier run in this session skips the
    # sign-in prompt entirely (retries must not nag the operator). When the
    # access token has aged out but a refresh_token survives in the cache,
    # refresh silently instead of prompting again.
    if (Test-Path -LiteralPath $tokenFile) {
        try {
            $cached = Get-Content -LiteralPath $tokenFile -Raw | ConvertFrom-Json
            $cj = Decode-Jwt $cached.access_token
            $have = @([string]$cj.scp -split ' ')
            $missing = @($Scopes | Where-Object { $_ -notin $have })
            if ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -lt ([long]$cj.exp - 300) -and $missing.Count -eq 0) {
                $accessToken = $cached.access_token
                Log 'Reusing cached access token - no sign-in required.'
            }
            elseif ($cached.refresh_token) {
                Log 'Cached access token stale - trying refresh_token...'
                try {
                    $rt = Invoke-RestMethod -Method Post -Uri "$tokenUrl/token" -Body @{
                        grant_type    = 'refresh_token'
                        client_id     = $clientId
                        refresh_token = $cached.refresh_token
                        scope         = $scopeStr
                    } -TimeoutSec 30
                    $cj2 = Decode-Jwt $rt.access_token
                    $have2 = @([string]$cj2.scp -split ' ')
                    $missing2 = @($Scopes | Where-Object { $_ -notin $have2 })
                    if ($missing2.Count -eq 0) {
                        $accessToken = $rt.access_token
                        Save-TokenCache -Access $accessToken -Refresh $rt.refresh_token
                        Log 'Access token refreshed - no sign-in required.'
                    }
                    else { Log "Refreshed token still missing scopes: $($missing2 -join ', ')" }
                }
                catch { Log "Token refresh failed: $($_.Exception.Message)" }
            }
            else { Log "Cached token rejected (expired or missing: $($missing -join ', '))." }
        }
        catch { Log "Cached token unusable: $($_.Exception.Message)" }
    }

    if (-not $accessToken) {
    $dc = Invoke-RestMethod -Method Post -Uri "$tokenUrl/devicecode" -Body $body -TimeoutSec 30
    Log ('DEVICE-CODE: To sign in, use a web browser to open the page {0} and enter the code {1} to authenticate.' -f $dc.verification_uri, $dc.user_code)
    Log "DEVICE-CODE: (issued, expires in $($dc.expires_in)s)"

    $deadline = [DateTime]::UtcNow.AddSeconds([int]$dc.expires_in)
    $start = [DateTime]::UtcNow
    $interval = [Math]::Max(5, [int]$dc.interval)
    $token = $null
    $lastBeat = Get-Date
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $token = Invoke-RestMethod -Method Post -Uri "$tokenUrl/token" -Body @{
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                device_code = $dc.device_code
                client_id   = $clientId
            } -TimeoutSec 30
            break
        }
        catch {
            $raw = $_.ErrorDetails.Message
            $code = $null
            try { $code = ($raw | ConvertFrom-Json).error } catch { }
            if ($code -eq 'authorization_pending') {
                if ((Get-Date) - $lastBeat -ge [TimeSpan]::FromSeconds(30)) {
                    Log "still waiting for sign-in ($([int]([DateTime]::UtcNow - $start).TotalSeconds)s elapsed)"
                    $lastBeat = Get-Date
                }
                continue
            }
            if ($code -eq 'slow_down') { $interval += 5; continue }
            if ($code -eq 'authorization_declined') { throw 'Sign-in was declined in the browser.' }
            if ($code -eq 'expired_token') { throw 'Device code expired before sign-in completed.' }
            throw "Token poll failed: $(if ($raw) { $raw } else { $_.Exception.Message })"
        }
    }
    if (-not $token) { throw 'Device code expired before sign-in completed.' }
        $accessToken = $token.access_token
        Save-TokenCache -Access $accessToken -Refresh $token.refresh_token
    }

    # Decode tid/upn from the JWT so the tenant assertion cannot silently pass.
    $claims = Decode-Jwt $accessToken
    Log "Token active: tid=$($claims.tid) scp=$($claims.scp)"

    $sec = ConvertTo-SecureString $accessToken -AsPlainText -Force
    Connect-MgGraph -AccessToken $sec -NoWelcome -ErrorAction Stop
    $ctx = Get-MgContext
    if (-not $ctx) { throw 'Connect-MgGraph produced no context.' }
    Log "Connected: Tenant=$($ctx.TenantId) Account=$($ctx.Account) AuthType=$($ctx.AuthType)"
    Log "Granted scopes: $((@($ctx.Scopes) | Sort-Object) -join ', ')"
    if ($ExpectedTenantId -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        if ($claims.tid -ne $ExpectedTenantId) {
            throw "Signed into tenant $($claims.tid), expected $ExpectedTenantId."
        }
    }
    return $ctx
}

function Invoke-Runbook {
    param([string]$Path, [hashtable]$Params, [string]$Label)
    Log "=== $Label ==="
    $ok = $true
    try {
        & $Path @Params 2>&1 | ForEach-Object { Log ('  | ' + [string]$_) }
    }
    catch {
        $ok = $false
        Log "  !! $Label FAILED: $($_.Exception.Message)"
        $detail = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
        elseif ($_.Exception.InnerException) { $detail = $_.Exception.InnerException.Message }
        if ($detail -match '"message":\s*"([^"]+)"') { $detail = $Matches[1] }
        if ($detail) { Log "     detail: $detail" }
    }
    Log "=== $Label finished (ok=$ok) ==="
    return $ok
}

function Probe {
    param([string]$Name, [scriptblock]$Block)
    try { Log ('  - ' + $Name + ' => ' + [string](& $Block)) }
    catch { Log ('  - ' + $Name + ' => ERROR: ' + $_.Exception.Message) }
}

function GraphGet {
    # Invoke-MgGraphRequest returns the raw JSON document; collection rows
    # live under .value. Unwrap and follow @odata.nextLink up to MaxPages
    # times so counts are real, not "1 wrapper object".
    param([string]$Uri, [int]$MaxPages = 1)
    $rows = @()
    $page = 0
    while ($Uri -and $page -lt $MaxPages) {
        $doc = Invoke-MgGraphRequest -Uri $Uri
        if ($null -ne $doc.value) { $rows += @($doc.value) } else { $rows += @($doc) }
        $Uri = $doc.'@odata.nextLink'
        $page++
    }
    return ,$rows
}

function GraphReportPost {
    # Report actions return JSON as application/octet-stream, which
    # Invoke-MgGraphRequest refuses to parse - route through a temp file.
    param([string]$Uri, [string]$Body)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('e2e-report-' + [guid]::NewGuid().ToString('n') + '.json')
    try {
        Invoke-MgGraphRequest -Method POST -Uri $Uri -Body $Body -ContentType 'application/json' -OutputFilePath $tmp -ErrorAction Stop | Out-Null
        $text = [System.IO.File]::ReadAllText($tmp)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json)
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function ConvertReportRows {
    # Rehydrate report Schema/Values pairs into named objects.
    param($Report)
    if ($null -eq $Report) { return @() }
    $cols = @()
    try { $cols = @($Report.Schema) } catch { return @() }
    if ($cols.Count -eq 0) { return @() }
    $index = @{}
    for ($i = 0; $i -lt $cols.Count; $i++) {
        $name = [string]$cols[$i].Column
        if ($name -and -not $index.ContainsKey($name)) { $index[$name] = $i }
    }
    $rows = @()
    foreach ($raw in @($Report.Values)) {
        if ($null -eq $raw) { continue }
        $arr = @($raw)
        $obj = [ordered]@{}
        foreach ($k in $index.Keys) {
            $vi = $index[$k]
            if ($arr.Count -gt $vi) { $obj[$k] = $arr[$vi] } else { $obj[$k] = $null }
        }
        $rows += [pscustomobject]$obj
    }
    return ,$rows
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
Remove-Item -LiteralPath $goFile -ErrorAction SilentlyContinue
Set-Content -LiteralPath $LogPath -Value ''

try {
    # ------------------------------------------------------------------ login
    Log "Repo: $repo"
    Log "Phase: sign-in ($TenantId)"
    $scopes = @(
        'DeviceManagementManagedDevices.Read.All',
        'DeviceManagementApps.Read.All',
        'DeviceManagementConfiguration.ReadWrite.All',
        'Group.ReadWrite.All',
        'Directory.Read.All'
    )
    $null = Connect-Interactive -Scopes $scopes -ExpectedTenantId $TenantId

    # ------------------------------------------------------------ diagnostics
    # Each section is deliberately non-fatal: diagnostics must never abort
    # the run before phase A.
    Log 'Phase: tenant diagnostics'
    Probe 'me' { (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/me?`$select=userPrincipalName").userPrincipalName }

    try {
        $md = GraphGet -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$select=id,azureADDeviceId,deviceName,osVersion,complianceState&$top=50'
        Log "  - managedDevices => $(@($md).Count)"
        foreach ($d in @($md | Select-Object -First 3)) {
            Log ("      device: name={0} os={1} intuneId={2} aadDeviceId={3}" -f $d.deviceName, $d.osVersion, $d.id, $d.azureADDeviceId)
        }
        if (@($md).Count -gt 0) {
            $idMaps = 0
            foreach ($d in @($md | Select-Object -First 3)) {
                if ($d.id -ne $d.azureADDeviceId) { $idMaps++ }
            }
            Log "  - Intune id != Entra id on $idMaps of first $([Math]::Min(3, @($md).Count)) device(s) - id mapping matters"
        }
    }
    catch { Log "  - managedDevices ERROR: $($_.Exception.Message)" }

    try {
        # windowsUpdateStates was retired; the replacement is the summary +
        # per-policy update alerts reports (PolicyId eq restriction each).
        $sum = GraphReportPost -Uri 'https://graph.microsoft.com/beta/deviceManagement/reports/getWindowsUpdateAlertSummaryReport' -Body '{"name":"WindowsUpdateAlertSummary"}'
        $sumRows = @(ConvertReportRows -Report $sum)
        Log "  - update alert summary report => policies=$($sumRows.Count)"
        $wuPolicies = @($sumRows | Where-Object { [string]$_.PolicyId } | Select-Object -First 10)
        $states = @()
        foreach ($sp in $wuPolicies) {
            try {
                $b = @{ name = 'WindowsUpdateAlertsPerPolicyPerDevice'; filter = "PolicyId eq '$([string]$sp.PolicyId)'" } | ConvertTo-Json -Compress
                $rep = GraphReportPost -Uri 'https://graph.microsoft.com/beta/deviceManagement/reports/getWindowsUpdateAlertsPerPolicyPerDeviceReport' -Body $b
                $states += @(ConvertReportRows -Report $rep)
            }
            catch { Log "      alert report error for policy $($sp.PolicyId): $($_.Exception.Message)" }
        }
        $failed = @($states | Where-Object { $_.DeviceId })
        Log "  - update alerts => total=$(@($states).Count) withDeviceId=$(@($failed).Count)"
        foreach ($s in @($failed | Select-Object -First 5)) {
            $resolved = 'n/a'
            try {
                $o = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/directoryObjects/$($s.DeviceId)?`$select=id"
                $resolved = $o.'@odata.type'
            }
            catch { $resolved = "NOT a directory object ($($_.Exception.Message))" }
            Log ("      alert: code={0} deviceId={1} device={2} -> {3}" -f $s.AlertMessage, $s.DeviceId, $s.DeviceName, $resolved)
        }
    }
    catch { Log "  - update alerts reports ERROR: $($_.Exception.Message)" }

    try {
        $apps = GraphGet -Uri 'https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps?$select=id,displayName' -MaxPages 2
        Log "  - mobileApps (first 2 pages) => $(@($apps).Count)"
        $failedApps = @(ConvertReportRows -Report (GraphReportPost -Uri 'https://graph.microsoft.com/beta/deviceManagement/reports/getFailedMobileAppsReport' -Body '{"name":"FailedMobileApps"}'))
        Log "  - failed-mobile-apps report => $(@($failedApps).Count) app(s) with failures"
        $appFailed = 0
        $appCodes = @{}
        foreach ($a in @($failedApps | Select-Object -First 25)) {
            try {
                $b = @{ filter = "(ApplicationId eq '$([string]$a.ApplicationId)')"; top = 1000; skip = 0 } | ConvertTo-Json -Compress
                $rows = ConvertReportRows -Report (GraphReportPost -Uri 'https://graph.microsoft.com/beta/deviceManagement/reports/retrieveDeviceAppInstallationStatusReport' -Body $b)
                $appFailed += @($rows | Where-Object { $_.DeviceId }).Count
                foreach ($r in $rows) { if ($r.ErrorCode) { $appCodes[[string]$r.ErrorCode] = $true } }
            }
            catch { Log "      statuses error for '$($a.DisplayName)': $($_.Exception.Message)" }
        }
        Log "  - install-status report (first $([Math]::Min(25, @($failedApps).Count)) failing apps) => rows=$appFailed distinctCodes=$(@($appCodes.Keys).Count)"
    }
    catch { Log "  - app report endpoints ERROR: $($_.Exception.Message)" }

    try {
        $scripts = GraphGet -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/deviceHealthScripts'
        Log "  - Remediations API (deviceHealthScripts) => reachable, $(@($scripts).Count) script(s) deployed"
    }
    catch {
        if ($_.Exception.Message -match '403|Authorization_Requestdenied|insufficient') {
            Log '  - Remediations API (deviceHealthScripts) => 403 (DeviceManagementScripts.Read.All not granted to the E2E app - informational)'
        }
        else { Log "  - deviceHealthScripts ERROR: $($_.Exception.Message)" }
    }

    # --------------------------------------------------------------- phase A
    $patchParams = @{ Interactive = $true; DryRun = $true }
    $appParams = @{ Interactive = $true; DryRun = $true }
    $a1 = Invoke-Runbook -Path (Join-Path $repo 'IntuneUpdateErrorGroups.ps1') -Params $patchParams -Label 'DRYRUN patch runbook'
    $a2 = Invoke-Runbook -Path (Join-Path $repo 'App\IntuneAppErrorGroups.ps1') -Params $appParams -Label 'DRYRUN app runbook'
    if (-not ($a1 -and $a2)) { throw 'A dry run failed - not proceeding to approval.' }

    # -------------------------------------------------------------- approval
    if ($AutoApply) {
        Log 'Phase: apply (-AutoApply given, no gate)'
    }
    else {
        Log "Phase A complete. Waiting for approval file: $goFile"
        Log "  (create it to apply, or let the $ApprovalTimeoutSeconds s timeout expire)"
        $waited = 0
        $approved = $false
        while ($waited -lt $ApprovalTimeoutSeconds) {
            Start-Sleep -Seconds 10
            $waited += 10
            if (Test-Path -LiteralPath $goFile) { $approved = $true; break }
        }
        if (-not $approved) {
            Log 'No approval received - exiting WITHOUT applying (exit 2).'
            exit 2
        }
        Log 'Approval received - proceeding to apply.'
    }

    # --------------------------------------------------------------- phase B
    $b1 = Invoke-Runbook -Path (Join-Path $repo 'IntuneUpdateErrorGroups.ps1') -Params @{ Interactive = $true } -Label 'APPLY patch runbook'
    $b2 = Invoke-Runbook -Path (Join-Path $repo 'App\IntuneAppErrorGroups.ps1') -Params @{ Interactive = $true } -Label 'APPLY app runbook'

    # ----------------------------------------------------------- verification
    Log 'Phase: verification'
    $groups = GraphGet -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=startswith(displayName,'Intune-')&`$select=id,displayName,description" -MaxPages 5
    Log "  - Intune-* groups in tenant: $(@($groups).Count)"
    foreach ($g in $groups) {
        $managed = if ($g.description -like '*Managed by automation*') { 'managed' } else { 'EXTERNAL' }
        $members = @()
        try {
            $members = GraphGet -Uri "https://graph.microsoft.com/v1.0/groups/$($g.id)/members?`$select=id,displayName" -MaxPages 3
        }
        catch { $members = @() }
        Log ("  - {0} [{1}] members={2}" -f $g.displayName, $managed, @($members).Count)
        foreach ($m in @($members | Select-Object -First 5)) {
            $type = '?'
            try { $type = (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/directoryObjects/$($m.id)?`$select=id").'@odata.type' } catch { $type = 'unresolvable' }
            Log ("      member {0} type={1}" -f $m.id, $type)
        }
    }
    $unmanaged = @($groups | Where-Object { $_.description -notlike '*Managed by automation*' })
    Log "  - unmanaged (must be untouched): $(@($unmanaged).Count)"

    Log 'E2E COMPLETE.'
    if ($b1 -and $b2) { exit 0 }
    exit 1
}
catch {
    Log "E2E FAILED: $($_.Exception.Message)"
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Log "ERROR DETAIL: $($_.ErrorDetails.Message)" }
    if ($_.ScriptStackTrace) { Log $_.ScriptStackTrace }
    exit 1
}
