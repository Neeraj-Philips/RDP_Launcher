@echo off
echo ============================================
echo  Scan Grid Launcher
echo  Copies scan + launches RDP to all machines
echo ============================================
echo.

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0scan\launch-scan-grid.ps1"

pause
