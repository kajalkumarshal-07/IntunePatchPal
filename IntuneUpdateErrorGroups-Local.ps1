#Requires -Version 5.1
<#
    Local test wrapper for IntuneUpdateErrorGroups.ps1.
    Installs/uses the Graph module and signs in interactively
    instead of using a managed identity. All logic lives in the
    main runbook script (single source of truth).
#>
param(
    [string]$GroupPrefix = "Intune-PatchError",
    [string[]]$TenantId,
    [switch]$CleanupOrphanedGroups,
    [switch]$DryRun
)

$main = Join-Path $PSScriptRoot 'IntuneUpdateErrorGroups.ps1'
$params = @{
    Interactive            = $true
    GroupPrefix            = $GroupPrefix
    CleanupOrphanedGroups  = $CleanupOrphanedGroups
    DryRun                 = $DryRun
}
if ($TenantId -and $TenantId.Count -gt 0) { $params.TenantId = $TenantId[0] }

try {
    & $main @params
}
catch {
    Write-Error $_
    exit 1
}
exit 0
