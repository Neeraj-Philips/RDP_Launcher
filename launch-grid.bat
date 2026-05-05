@echo off
:: ============================================
:: RDP Grid Launcher - Dual Monitor Layout
:: ============================================
:: Launches all servers and auto-arranges them
:: in a grid across your monitors.
:: ============================================
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\rdp-grid.ps1"
if %ERRORLEVEL% neq 0 (
    echo.
    echo Something went wrong. See logs\rdp-grid.log for details.
    pause
)
