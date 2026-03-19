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

chcp 65001 >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -OutputPath "%SCRIPT_DIR%LoginSpeedReport.txt"

echo.
echo Done. Report saved to: %SCRIPT_DIR%LoginSpeedReport.txt
pause
