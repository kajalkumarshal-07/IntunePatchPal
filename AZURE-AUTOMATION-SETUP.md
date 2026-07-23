# Azure Automation Setup for Intune Patch Error Groups

## Architecture

```
Azure Automation (PowerShell runbook)
    │
    ├── Managed Identity (auth to Graph without secrets)
    │
    ├── GET /beta/deviceManagement/windowsUpdateStates
    │       └── Devices with failed updates, grouped by errorCode
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

$appRole = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'" | 
  Select-Object -ExpandProperty AppRoles | 
  Where-Object { $_.Value -in @("Device.Read.All", "Group.ReadWrite.All", "DeviceManagementManagedDevices.Read.All") }

$managedIdentity = Get-MgServicePrincipal -Filter "id eq 'YOUR-MANAGED-IDENTITY-OBJECT-ID'"

foreach ($role in $appRole) {
  New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $managedIdentity.Id `
    -PrincipalId $managedIdentity.Id `
    -ResourceId "00000003-0000-0000-c000-000000000000" `
    -AppRoleId $role.Id
}
```

## Step 3: Import Required Modules

In Azure Automation portal:
1. **Shared Resources > Modules > Add module**
2. Search for and import:
   - `Microsoft.Graph.Authentication` (depends on Microsoft.Graph.Core)
   - `Microsoft.Graph.DeviceManagement`

Or via PowerShell:
```powershell
$modules = @(
    @{ Name = "Microsoft.Graph.Authentication"; Version = "2.15.0" },
    @{ Name = "Microsoft.Graph.DeviceManagement"; Version = "2.15.0" }
)
foreach ($m in $modules) {
    New-AzAutomationModule -ResourceGroupName "RG-IntuneManagement" `
        -AutomationAccountName "AA-IntunePatchAutomation" `
        -Name $m.Name `
        -ContentLink "https://www.powershellgallery.com/api/v2/package/$($m.Name)/$($m.Version)"
}
```

## Step 4: Import the Runbook

1. In Azure Automation portal: **Process Automation > Runbooks > Create**
2. Type: **PowerShell**
3. Upload `IntuneUpdateErrorGroups.ps1`
4. **Publish**

## Step 5: Create Schedule

1. **Resources > Schedules > Add schedule**
2. Set recurrence (e.g., daily at 6 AM)
3. **Link to runbook** → select `IntuneUpdateErrorGroups`

## Step 6: Target Proactive Remediations

In Intune:
1. Create your **Proactive Remediation** (detection + remediation scripts)
2. On the **Assignments** tab, select the Azure AD groups named `Intune-PatchError-{code}`
3. Schedule as needed

## Local Testing First

Run the local version to test in your environment:

```powershell
.\IntuneUpdateErrorGroups-Local.ps1
```

This will prompt for interactive Graph API login. Review the groups created and verify memberships.
