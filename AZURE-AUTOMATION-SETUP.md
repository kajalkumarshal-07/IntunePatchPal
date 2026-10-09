# Azure Automation Setup for Intune Patch Error Groups

## Automated deployment (preferred)

With `az` CLI signed in and a real subscription in the tenant:

```powershell
powershell -ExecutionPolicy Bypass -File Deploy-Azure.ps1
```

Does everything below in order: resource group, Automation account,
system-assigned identity, `Microsoft.Graph.Authentication` module import,
both runbooks (import + publish), Graph app-role grants for the identity,
daily 06:00 schedule linked to both runbooks, and a first dry-run job per
runbook to prove the chain. Only the alert rule and the Intune remediation
assignments remain manual (steps 6-7 below).

## Error-code groups + per-code remediations (automated)

After `Deploy-Azure.ps1`, provision the complete error-code taxonomy and
one Intune remediation per code (25 patch + 24 app):

```powershell
powershell -ExecutionPolicy Bypass -File Deploy-ErrorGroupsAndRemediations.ps1
```

The target tenant is auto-detected from `az account show` (or pass
`-TenantId <guid>`); on a tenant other than the one the cached token
belongs to it opens a normal interactive sign-in instead.

For every code in `ERROR-REFERENCE.md` / `App\ERROR-REFERENCE.md` it:

1. Creates the Entra group `Intune-PatchError-<code>` / `Intune-AppError-<code>`
   (ownership marker in the description - the nightly runbook adopts these
   and curates membership from real Intune failure reports).
2. Bakes the code into `DetectionTemplate.ps1` + `RemediationTemplate.ps1`
   (Intune cannot pass parameters). Codes without a targeted device check
   get a deploy-time injected case: detection reports non-compliant for
   curated group members, remediation writes report-only guidance.
3. Creates the Intune remediation package (run as SYSTEM) and assigns it
   to that group.

First run opens a browser consent once for
`DeviceManagementScripts.ReadWrite.All` (the Remediations API scope -
separate from the configuration scope the runbooks use). Idempotent:
re-running updates script content and re-asserts assignments in place.
`-Lane Patch|App` limits it to one lane; `-SkipRemediations` creates
groups only.

## Architecture

```
Azure Automation (PowerShell runbook)
    │
    ├── Managed Identity (auth to Graph without secrets)
    │
    ├── POST /beta/deviceManagement/reports/*UpdateAlert*Report
    │       └── Devices with failed updates, grouped by alert code
    │
    └── For each error code:
            ├── Create/Update Azure AD Security Group (Intune-PatchError-{code})
            └── Add device members to the group
                    └── Assign Intune Proactive Remediations to these groups
```

## Step 1: Create Azure Automation Account

```powershell
# In Azure Portal or Cloud Shell
az automation account create `
  --name "AA-IntunePatchAutomation" `
  --resource-group "RG-IntuneManagement" `
  --location "eastus" `
  --assign-identity
```

## Step 2: Grant Graph API Permissions

1. In Azure Portal, go to your Automation Account
2. **Account Settings > Identity > System assigned** → copy the **Object ID** (Principal ID)
3. Use the following to grant permissions:

```powershell
# Assign Graph API permissions via Microsoft Graph PowerShell
Connect-MgGraph -Scopes @("AppRoleAssignment.ReadWrite.All", "Application.Read.All")

# Roles needed by IntuneUpdateErrorGroups.ps1 + App\IntuneAppErrorGroups.ps1
$neededRoles = @(
  "Directory.Read.All",                 # read groups + members
  "Group.ReadWrite.All",                # create/modify groups + membership
  "DeviceManagementManagedDevices.Read.All",  # update alert reports (patch runbook)
  "DeviceManagementApps.Read.All"       # app install status reports (app runbook)
)

$appRole = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'" |
  Select-Object -ExpandProperty AppRoles |
  Where-Object { $_.Value -in $neededRoles }

$managedIdentity = Get-MgServicePrincipal -Filter "id eq 'YOUR-MANAGED-IDENTITY-OBJECT-ID'"

foreach ($role in $appRole) {
  New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $managedIdentity.Id `
    -PrincipalId $managedIdentity.Id `
    -ResourceId "00000003-0000-0000-c000-000000000000" `
    -AppRoleId $role.Id
}
```

> Missing `DeviceManagementApps.Read.All` makes only the *app* runbook fail;
> missing `DeviceManagementManagedDevices.Read.All` fails the *patch* runbook.

## Step 3: Import Required Modules

Both runbooks only use `Invoke-MgGraphRequest`, so a single module is enough:

1. In Azure Automation portal: **Shared Resources > Modules > Add module**
2. Search for and import: `Microsoft.Graph.Authentication`

Or via PowerShell:
```powershell
New-AzAutomationModule -ResourceGroupName "RG-IntuneManagement" `
    -AutomationAccountName "AA-IntunePatchAutomation" `
    -Name "Microsoft.Graph.Authentication" `
    -ContentLink "https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Authentication"
```

## Step 4: Import the Runbook

1. In Azure Automation portal: **Process Automation > Runbooks > Create**
2. Type: **PowerShell**
3. Upload `IntuneUpdateErrorGroups.ps1` (and `App\IntuneAppErrorGroups.ps1` as a second runbook)
4. **Publish**

## Step 5: Dry Run, Then Schedule

1. Run the published runbook once with **Start** and parameter `DryRun = true`
   - it reads all failures and prints every group/member change it *would* make
   - inspect the output: created/synced/cleared counts must look sane
2. **Resources > Schedules > Add schedule** (e.g., daily at 6 AM)
3. **Link to runbook** → select `IntuneUpdateErrorGroups`

## Step 6: Alert on Failures

The runbook throws (job = Failed) on fatal errors or any membership failures,
so an alert fires automatically:

1. **Monitor > Alerts > New alert rule** on the Automation Account
2. Condition: **Scheduled job run failures** (all severities)
3. Action group: email / Teams / Logic App of your choice

The summary line in the job output is machine-readable:
`created=0 synced=3 cleared=1 deleted=0 membersAdded=5 membersRemoved=2 membersSkipped=1 invalidDeviceIds=0 failures=0 dryRun=False`

## Step 7: Target Remediations

In Intune:
1. Create your **Remediation** (detection + remediation scripts)
2. On the **Assignments** tab, select the AAD groups named `Intune-PatchError-{code}` / `Intune-AppError-{code}`
3. Schedule as needed

## Local Testing First

```powershell
# Preview only - no directory changes
.\IntuneUpdateErrorGroups-Local.ps1 -DryRun

# Apply
.\IntuneUpdateErrorGroups-Local.ps1
```

The local wrapper prompts for interactive Graph API login (delegated scopes),
uses the same code as the runbook, and prints the same summary line.
