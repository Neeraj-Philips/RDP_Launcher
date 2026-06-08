@echo off
:: ============================================
:: Deploy RDP Launcher to Jump Server
:: ============================================
:: Copies the tool to the jump server via admin share (C$).
:: The jump server gets its own servers.txt with target IPs.
:: ============================================
echo.
echo   Deploy RDP Launcher to Jump Server
echo   ===================================
echo.

powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0scripts\deploy-to-jumpserver.ps1"
if %ERRORLEVEL% neq 0 (
    echo.
    echo [ERROR] Deployment failed. Check logs\deploy.log for details.
    pause
)
