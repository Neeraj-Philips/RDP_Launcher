@echo off
:: ============================================
:: Deploy RDP Launcher to Jump Server
:: ============================================
:: Copies the tool to the jump server via admin share (C$).
:: The jump server gets its own servers.txt with target IPs.
:: ============================================
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\deploy-to-jumpserver.ps1"
if %ERRORLEVEL% neq 0 (
    echo.
    echo Something went wrong. Check output above.
    pause
)
