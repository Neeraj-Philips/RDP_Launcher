@echo off
:: ============================================
:: RDP Dashboard - Launch on Jump Server
:: ============================================
:: Opens the RDP Session Dashboard GUI.
:: The dashboard manages launching/stopping
:: client RDP sessions via rdp-grid.ps1.
:: ============================================

powershell -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%~dp0scripts\Dashboard.ps1"
