#Requires -Version 5.1
<#
    Offline test suite for the IntuneRemediations project.

    What it covers (no tenant / no network needed):
      1. Syntax parse check of every .ps1 file (PS 5.1 parser)
      2. Dot-source safety: loading a script must not execute its main block
      3. Graph helpers: pagination, 429 retry, $batch chunking
      4. Membership sync: read-diff-write add/remove, GUID validation
      5. Detection helpers: pending reboot, stale installer, temp writability

    Run:  powershell -ExecutionPolicy Bypass -File Tests\Run-Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:Passes = 0
$script:Fails = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:Passes++
        Write-Host "  PASS  $Name"
    }
    else {
        $script:Fails++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
    }
}

# --- Mocks (must exist before any helper is invoked) -----------------------

$script:GraphCalls = @()
$script:BatchSizes = @()
$script:BatchOps = @()
$script:RetryArmed = $true
$script:MemberPages = @{}

function Start-Sleep { param($Seconds) }

function Invoke-MgGraphRequest {
    [CmdletBinding()]
    param($Method, $Uri, $Body, $ContentType, $OutputType)
    $script:GraphCalls += [pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body }

    if ($Uri -eq 'https://test.local/retry' -and $script:RetryArmed) {
        $script:RetryArmed = $false
        throw "Response status code does not indicate success: 429 (Too Many Requests)."
    }
    if ($Uri -eq 'https://test.local/retry') { return @{ ok = $true } }

    if ($Uri -eq 'https://test.local/page1') {
        return @{ value = @(@{ id = 'p1a' }, @{ id = 'p1b' }); '@odata.nextLink' = 'https://test.local/page2' }
    }
    if ($Uri -eq 'https://test.local/page2') {
        return @{ value = @(@{ id = 'p2a' }); '@odata.nextLink' = $null }
    }
    if ($Uri -eq 'https://test.local/single') { return @{ id = 'single' } }

    if ($Uri -like '*$batch') {
        $parsed = $Body | ConvertFrom-Json
        $reqs = @($parsed.requests)
        $script:BatchSizes += $reqs.Count
        foreach ($r in $reqs) { $script:BatchOps += $r }
        $responses = @($reqs | ForEach-Object { @{ id = $_.id; status = 204 } })
        return @{ responses = $responses }
    }

    $memberKey = ($Uri -split '\?')[0]
    if ($script:MemberPages.ContainsKey($memberKey)) {
        return @{ value = $script:MemberPages[$memberKey]; '@odata.nextLink' = $null }
    }

    return @{ value = @() }
}

# --- 1. Parse check --------------------------------------------------------

Write-Host '== 1. Parse check (PS 5.1 parser) =='
$files = Get-ChildItem -Path $root -Recurse -Filter '*.ps1'
foreach ($f in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True ($errors.Count -eq 0) "Parse $($f.FullName.Replace($root, '.')) ($($errors.Count) error(s))"
    foreach ($e in $errors) { Write-Host "        $($e.Message) @ line $($e.Extent.StartLineNumber)" -ForegroundColor Red }
}

# --- 2. Dot-source safety --------------------------------------------------

Write-Host '== 2. Dot-source safety (main block must not run) =='
. (Join-Path $root 'IntuneUpdateErrorGroups.ps1')
Assert-True ($null -ne (Get-Command Invoke-ErrorGroupSync -ErrorAction SilentlyContinue)) 'Patch runbook functions load without executing'
. (Join-Path $root 'App\IntuneAppErrorGroups.ps1')
Assert-True ($null -ne (Get-Command Get-FailedAppStatuses -ErrorAction SilentlyContinue)) 'App runbook functions load without executing'
. (Join-Path $root 'DetectionTemplate.ps1')
Assert-True ($null -ne (Get-Command Test-PendingReboot -ErrorAction SilentlyContinue)) 'Patch detection functions load without executing'
. (Join-Path $root 'RemediationTemplate.ps1')
Assert-True ($null -ne (Get-Command Get-RemediationOutcome -ErrorAction SilentlyContinue)) 'Patch remediation functions load without executing'
. (Join-Path $root 'App\DetectionTemplate.ps1')
Assert-True ($null -ne (Get-Command Test-StaleInstaller -ErrorAction SilentlyContinue)) 'App detection functions load without executing'
. (Join-Path $root 'App\RemediationTemplate.ps1')
Assert-True ($null -ne (Get-Command Test-TempWritable -ErrorAction SilentlyContinue)) 'App remediation functions load without executing'

# --- 3. Graph helpers ------------------------------------------------------

Write-Host '== 3. Graph helpers =='

$script:GraphCalls = @()
$r1 = Invoke-GraphGetAll -Uri 'https://test.local/page1'
Assert-True (@($r1).Count -eq 3) "Pagination follows nextLink (got $(@($r1).Count) of 3)"
Assert-True ($script:GraphCalls.Count -eq 2) 'Pagination issued 2 paged GETs'

$script:GraphCalls = @()
$one = Invoke-GraphGetAll -Uri 'https://test.local/single'
Assert-True (@($one).Count -eq 1) 'Single-object response returns 1 item'

$script:RetryArmed = $true
$script:GraphCalls = @()
$retry = Invoke-GraphApi -Method GET -Uri 'https://test.local/retry'
Assert-True ($retry.ok -eq $true) '429 triggers retry and then succeeds'
Assert-True ($script:GraphCalls.Count -eq 2) 'Retry made exactly 2 attempts'

$script:BatchSizes = @()
$script:BatchOps = @()
$requests = @()
for ($i = 1; $i -le 25; $i++) {
    $requests += @{ Id = "$i"; Method = 'POST'; Url = "groups/G/members/`$ref"; BodyObject = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$i" } }
}
$batchResults = @(Invoke-GraphBatch -Requests $requests)
Assert-True (($script:BatchSizes -join ',') -eq '20,5') "Batch chunks 20+5 (got $($script:BatchSizes -join ','))"
Assert-True ($batchResults.Count -eq 25) 'Batch returns one result per request'
Assert-True (($batchResults | Where-Object { $_.Status -eq 204 }).Count -eq 25) 'Batch results carry sub-status codes'

# --- 4. Membership sync ----------------------------------------------------

Write-Host '== 4. Membership sync =='
$gA = '11111111-1111-1111-1111-111111111111'
$gB = '22222222-2222-2222-2222-222222222222'
$gC = '33333333-3333-3333-3333-333333333333'
$gD = '44444444-4444-4444-4444-444444444444'

$script:MemberPages = @{ 'https://graph.microsoft.com/v1.0/groups/TEST1/members' = @(@{ id = $gA }, @{ id = $gB }) }
$script:BatchSizes = @()
$script:BatchOps = @()
$script:Stats.MembersAdded = 0
$script:Stats.MembersRemoved = 0
$script:Stats.InvalidDeviceIds = 0

Sync-GroupMembers -GroupId 'TEST1' -GroupName 'Test-1' -TargetDeviceIds @($gB, $gC, $gD)
$addOps = @($script:BatchOps | Where-Object { $_.method -eq 'POST' })
$delOps = @($script:BatchOps | Where-Object { $_.method -eq 'DELETE' })
Assert-True ($addOps.Count -eq 2) "Diff adds 2 new members (got $($addOps.Count))"
Assert-True ($delOps.Count -eq 1) 'Diff removes 1 stale member'
Assert-True ($script:Stats.MembersAdded -eq 2) 'Stats count 2 adds'
Assert-True ($script:Stats.MembersRemoved -eq 1) 'Stats count 1 removal'
$addBodies = @($addOps | ForEach-Object { "$($_.body.'@odata.id')" }) -join ' '
Assert-True (($addBodies -match $gC) -and ($addBodies -match $gD) -and ($addBodies -notmatch $gB)) 'Add bodies target exactly the missing GUIDs'
Assert-True (@($delOps | Where-Object { $_.url -match [regex]::Escape($gA) }).Count -eq 1) 'Remove URL targets the stale GUID'

$script:MemberPages = @{ 'https://graph.microsoft.com/v1.0/groups/TEST2/members' = @(@{ id = $gA }) }
$script:BatchOps = @()
$script:Stats.InvalidDeviceIds = 0
Sync-GroupMembers -GroupId 'TEST2' -GroupName 'Test-2' -TargetDeviceIds @('not-a-guid')
Assert-True (@($script:BatchOps).Count -eq 0) 'Non-GUID device ids never reach Graph'
Assert-True ($script:Stats.InvalidDeviceIds -eq 1) 'Invalid id is counted'

$script:MemberPages = @{ 'https://graph.microsoft.com/v1.0/groups/TEST3/members' = @(@{ id = $gA }) }
$script:BatchOps = @()
Sync-GroupMembers -GroupId 'TEST3' -GroupName 'Test-3' -TargetDeviceIds @($gA)
Assert-True (@($script:BatchOps).Count -eq 0) 'No-op sync issues no writes'

$script:MemberPages = @{ 'https://graph.microsoft.com/v1.0/groups/TEST4/members' = @(@{ id = $gA }, @{ id = $gB }) }
$script:BatchOps = @()
Sync-GroupMembers -GroupId 'TEST4' -GroupName 'Test-4' -TargetDeviceIds @() -DryRun
Assert-True (@($script:BatchOps).Count -eq 0) 'DryRun performs no writes'
$script:MemberPages = @{}

# --- 5. Detection helpers --------------------------------------------------

Write-Host '== 5. Detection/remediation helpers =='
$pr = Test-PendingReboot
Assert-True (($null -eq $pr) -or ($pr -is [string]) -or ($pr -is [bool])) "Test-PendingReboot returns `$null/string/bool (got: '$pr')"

$stale = Test-StaleInstaller
Assert-True (($null -eq $stale) -or ($stale -is [string])) "Test-StaleInstaller returns `$null or reason (got: '$stale')"

$tw = Test-TempWritable
Assert-True ($null -eq $tw) "Test-TempWritable passes on this machine (got: '$tw')"

$bits = Test-BitsProblem
Assert-True (($null -eq $bits) -or ($bits -is [string])) "Test-BitsProblem returns `$null or reason (got: '$bits')"

$wu = Get-WUServerPolicyState
Assert-True ($null -ne $wu) 'Get-WUServerPolicyState returns a state object'
Assert-True ($wu.ContainsKey('WUServer') -and $wu.ContainsKey('Partial')) 'WUServer state has WUServer + Partial keys'

$oc = Get-RemediationOutcome -Code '-999999999'
Assert-True ($oc.State -eq 'Unknown') 'Unknown remediation code verifies as Unknown (exit 0, no false alarm)'

# --- Summary ---------------------------------------------------------------

Write-Host ''
Write-Host "== Result: $($script:Passes) passed, $($script:Fails) failed =="
if ($script:Fails -gt 0) { exit 1 }
exit 0
