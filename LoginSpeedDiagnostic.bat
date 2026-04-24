@echo off
setlocal EnableDelayedExpansion
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

:: --------------- Environment pre-flight checks (advisory only) ---------------

:: PowerShell version detection
echo Checking PowerShell environment...
for /f "usebackq delims=" %%V in (`powershell.exe -NoProfile -Command "$PSVersionTable.PSVersion.ToString()" 2^>nul`) do set "PS_VER=%%V"
if defined PS_VER (
    echo   PowerShell version: !PS_VER!
    REM Warn if version is below 5.1
    for /f "tokens=1,2 delims=." %%A in ("!PS_VER!") do (
        if %%A LSS 5 (
            echo   WARNING: PowerShell version !PS_VER! is below 5.1. Some diagnostics may not work correctly.
        ) else if %%A EQU 5 if %%B LSS 1 (
            echo   WARNING: PowerShell version !PS_VER! is below 5.1. Some diagnostics may not work correctly.
        )
    )
) else (
    echo   WARNING: Could not detect PowerShell version.
)

:: Check critical cmdlet availability (Get-CimInstance from CimCmdlets)
for /f "usebackq delims=" %%R in (`powershell.exe -NoProfile -Command "if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) { 'Available' } else { 'Missing' }" 2^>nul`) do set "CIM_STATUS=%%R"
if /i "!CIM_STATUS!"=="Available" (
    echo   Get-CimInstance: Available
) else (
    echo   WARNING: Get-CimInstance cmdlet not available. WMI-based diagnostics may fail.
)

:: Language mode check
for /f "usebackq delims=" %%L in (`powershell.exe -NoProfile -Command "$ExecutionContext.SessionState.LanguageMode" 2^>nul`) do set "LANG_MODE=%%L"
if defined LANG_MODE (
    echo   Language mode: !LANG_MODE!
    if /i not "!LANG_MODE!"=="FullLanguage" (
        echo   WARNING: PowerShell is running in !LANG_MODE! mode. Some diagnostics may be restricted.
    )
) else (
    echo   WARNING: Could not detect PowerShell language mode.
)
echo.

:: -------------------------------------------------------------------------

:: Determine script directory
set "SCRIPT_DIR=%~dp0"
set "PS_MODULE=%SCRIPT_DIR%LoginSpeedDiagnostic.psd1"
set "PS_SCRIPT=%SCRIPT_DIR%LoginSpeedDiagnostic.ps1"
set "OUTPUT_PATH=%SCRIPT_DIR%LoginSpeedReport.txt"

:: Check for module manifest or fallback to script
if exist "%PS_MODULE%" (
    echo Module manifest found - using module-based execution.
    echo Starting AD Login Speed Diagnostic...
    echo Results will be saved to %OUTPUT_PATH%
    echo.

    chcp 65001 >nul 2>&1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '%PS_MODULE%' -Force; Invoke-LoginSpeedDiagnostic -OutputPath '%OUTPUT_PATH%'"

    if !errorlevel! neq 0 (
        echo.
        echo WARNING: Module execution failed. Falling back to script mode...
        echo.
        goto :UseScript
    )
) else (
    echo Module manifest not found - using legacy script mode.
    goto :UseScript
)

goto :Complete

:UseScript
if not exist "%PS_SCRIPT%" (
    echo ERROR: Neither LoginSpeedDiagnostic.psd1 nor LoginSpeedDiagnostic.ps1 found in "!SCRIPT_DIR!"
    pause
    exit /b 1
)

echo Starting AD Login Speed Diagnostic...
echo Results will be saved to %OUTPUT_PATH%
echo.

chcp 65001 >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -OutputPath "%OUTPUT_PATH%"

:Complete
echo.
echo Done. Report saved to: %OUTPUT_PATH%
pause
