@echo off
:: ============================================================
:: LoginSpeedDiagnostic.bat
:: Launcher for the AD Login Speed Diagnostic tool.
:: Run this from CMD or double-click. Requires Windows + AD domain.
:: ============================================================

title AD Login Speed Diagnostic

:: Check whether we are running as administrator (advisory only – not required)
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo NOTE: Running as a standard user.
    echo       Some sections ^(Security log, GP timing, Winlogon events^) require
    echo       administrator rights and will be skipped automatically.
    echo       For full results, right-click this file and choose "Run as administrator".
    echo.
) else (
    echo Running with administrator privileges – full data collection enabled.
    echo.
)

:: Check whether PowerShell is available
where powershell.exe >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: PowerShell is not available or not in PATH.
    echo        Please install PowerShell or ensure it is in your system PATH.
    pause
    exit /b 2
)

:: Check execution policy (advisory only)
for /f "usebackq delims=" %%P in (`powershell.exe -NoProfile -Command "Get-ExecutionPolicy"`) do set "EXEC_POLICY=%%P"
if /i "%EXEC_POLICY%"=="Restricted" (
    echo NOTE: Current PowerShell execution policy is Restricted.
    echo       The launcher will use -ExecutionPolicy Bypass to run the script.
    echo.
)

:: Determine script directory
set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%LoginSpeedDiagnostic.ps1"

if not exist "%PS_SCRIPT%" (
    echo ERROR: LoginSpeedDiagnostic.ps1 not found in %SCRIPT_DIR%
    pause
    exit /b 1
)

echo Starting AD Login Speed Diagnostic...
echo Results will be saved to %SCRIPT_DIR%LoginSpeedReport.txt
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -OutputPath "%SCRIPT_DIR%LoginSpeedReport.txt"
set "PS_EXIT=%ERRORLEVEL%"

if %PS_EXIT% neq 0 (
    echo.
    echo WARNING: The diagnostic script exited with code %PS_EXIT%.
    echo          Check the report for error details.
)

echo.
echo Done. Report saved to: %SCRIPT_DIR%LoginSpeedReport.txt
pause
