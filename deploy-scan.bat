@echo off
echo ============================================
echo  Deploy Scan Script to All Machines
echo ============================================
echo.

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0scan\deploy-scan.ps1"

pause
