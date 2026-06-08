@echo off
:: ============================================
:: RDP Grid Launcher - Auto-Login
:: ============================================
:: Kills existing sessions, launches all servers,
:: auto-logs in, then exits (no window left).
:: ============================================

powershell -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%~dp0scripts\rdp-grid.ps1"
