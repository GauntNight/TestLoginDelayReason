@echo off
:: ============================================================
:: LoginSpeedDiagnostic.bat
:: Launcher for the AD Login Speed Diagnostic tool.
:: Run this from CMD or double-click. Requires Windows + AD domain.
:: ============================================================

title AD Login Speed Diagnostic

:: Check for admin rights and self-elevate if needed
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
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

echo.
echo Done. Report saved to: %SCRIPT_DIR%LoginSpeedReport.txt
pause
