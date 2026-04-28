@echo off
:: Double-click to open the RDP GUI Dashboard
powershell -ExecutionPolicy Bypass -File "%~dp0rdp-gui.ps1"
if %ERRORLEVEL% neq 0 (
    echo.
    echo Something went wrong. See error above.
    pause
)
