@echo off
title IntunePatchPal - One Click Setup
cd /d "%~dp0"
color 0A
setlocal

echo ============================================================
echo   IntunePatchPal - your fleet's patch buddy - one click setup (any tenant)
echo ============================================================
echo.
echo  Step 1/2  Azure Automation infrastructure
echo            - resource group, automation account + identity
echo            - Graph permissions, runbooks, daily 06:00 schedule
echo            - first dry-run proof job per runbook
echo.
echo  Step 2/2  Error-code groups + Intune remediations
echo            - one Entra group per known error code (patch + app)
echo            - one Intune remediation per code, assigned to its group
echo.
echo  Requirements : Azure CLI, an enabled Azure subscription,
echo                 Global Administrator on the target tenant.
echo  Time         : about 5-10 minutes total.
echo  Consent      : step 2 opens ONE browser window the first time
echo                 (Graph permission) - click Accept.
echo.
echo ============================================================
echo.

rem ------------------------------------------------- az CLI ----
where az >nul 2>&1
if errorlevel 1 (
    echo [1] Azure CLI not found - attempting install via winget...
    winget install -e Microsoft.AzureCLI --accept-source-agreements --accept-package-agreements
    where az >nul 2>&1
    if errorlevel 1 (
        echo.
        echo [ERROR] Azure CLI could not be installed automatically.
        echo Install it manually, then re-run this file:
        echo     winget install -e Microsoft.AzureCLI
        echo.
        pause
        exit /b 1
    )
    echo [1] Azure CLI installed.
    echo     IMPORTANT: open a NEW command window and re-run this file
    echo     so the az command is on PATH.
    echo.
    pause
    exit /b 1
)

rem --------------------------------------------------- sign in ----
az account show >nul 2>&1
if errorlevel 1 (
    echo [2] Not signed in to Azure - a browser window will open now.
    echo     Sign in with an account that is Global Administrator
    echo     of the TARGET tenant ^(has a subscription there^).
    echo.
    az login
    if errorlevel 1 (
        echo [ERROR] az login failed.
        pause
        exit /b 1
    )
    echo.
)

for /f "delims=" %%t in ('az account show --query "tenant.displayName" -o tsv 2^>nul') do set "TENANTNAME=%%t"
echo Signed in to tenant: %TENANTNAME%
az account show --query "{subscription: name, tenant: id}" -o table
echo.

rem ---------------------------------------------- step 1: infra ----
echo ============================================================
echo  STEP 1 of 2 : Azure Automation infrastructure
echo ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0Deploy-Azure.ps1' *>&1 | Tee-Object -FilePath '%TEMP%\Intune-Deploy-Azure.log'"
if errorlevel 1 goto :failed_infra

echo.
echo ============================================================
echo  STEP 2 of 2 : error-code groups + Intune remediations
echo ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0Deploy-ErrorGroupsAndRemediations.ps1' *>&1 | Tee-Object -FilePath '%TEMP%\Intune-Deploy-Remediations.log'"
if errorlevel 1 goto :failed_remediations

goto :done

:failed_infra
echo.
echo [FAILED] Step 1 (infrastructure) reported an error.
echo          Full log: %TEMP%\Intune-Deploy-Azure.log
echo          Fix the message above and re-run this file - it is safe to re-run.
pause
exit /b 1

:failed_remediations
echo.
echo [FAILED] Step 2 (groups + remediations) reported an error.
echo          Full log: %TEMP%\Intune-Deploy-Remediations.log
echo          If a browser consent window appeared, click Accept and re-run.
pause
exit /b 1

:done
echo.
echo ============================================================
echo   [OK] SETUP COMPLETE
echo ============================================================
echo.
echo  What now:
echo   1. Azure portal ^> Automation Accounts ^> your account:
echo      - Runbooks tab      : two published runbooks
echo      - Schedules tab     : Daily-0600 (fires 06:00 your timezone)
echo      - Jobs history      : first dry-run job should be Completed
echo   2. Entra portal ^> Groups : Intune-PatchError-* / Intune-AppError-*
echo   3. Intune portal ^> Apps ^> Remediations : one entry per error code,
echo      each assigned to its matching group (run as SYSTEM).
echo   4. Optional: Azure portal ^> Automation Account ^> Monitor ^> Alerts
echo      ^> add "scheduled job run failures" alert with your email.
echo   5. Devices start appearing in the groups after their first real
echo      failure is reported to Intune ^(runbook syncs nightly 06:00^).
echo.
echo  Logs: %TEMP%\Intune-Deploy-Azure.log
echo        %TEMP%\Intune-Deploy-Remediations.log
echo  Docs: README.md  -  AZURE-AUTOMATION-SETUP.md
echo.
pause
