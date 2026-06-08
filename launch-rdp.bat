@echo off
:: ============================================
:: RDP Launcher - Double-click to open GUI
:: ============================================

:: Validate config exists
if not exist "%~dp0config\servers.txt" (
    echo [ERROR] config\servers.txt not found.
    echo   Copy config\servers.example.txt to config\servers.txt and add server IPs.
    pause
    exit /b 1
)

powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0scripts\rdp-gui.ps1"
if %ERRORLEVEL% neq 0 (
    echo.
    echo [ERROR] GUI launcher failed. See logs\rdp-gui.log for details.
    pause
)
