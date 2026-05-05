@echo off
:: ============================================
:: RDP Launcher — Double-click to open GUI
:: ============================================
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\rdp-gui.ps1"
if %ERRORLEVEL% neq 0 (
    echo.
    echo Something went wrong. See logs\rdp-gui.log for details.
    pause
)
