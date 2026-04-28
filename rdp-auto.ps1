# ============================================
# RDP Launcher - Auto Run (Scheduled Task)
# ============================================
# Reads server list from servers.txt (same folder)
#
# Usage (manual):
#   powershell -ExecutionPolicy Bypass -File .\rdp-auto.ps1
#
# Usage (Task Scheduler):
#   Program:   powershell.exe
#   Arguments: -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\path\to\rdp-auto.ps1"
#   Trigger:   At log on / Daily / etc.
# ============================================

$delaySeconds = 2
$serverFile = Join-Path $PSScriptRoot "servers.txt"

# Load servers from file (skip comments and blanks)
if (-not (Test-Path $serverFile)) {
    Write-Host "ERROR: servers.txt not found at $serverFile" -ForegroundColor Red
    exit 1
}

$servers = Get-Content $serverFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne "" -and $_ -notmatch "^\s*#" }

# ===== LOG =====
$logFile = Join-Path $PSScriptRoot "rdp-auto.log"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Add-Content -Path $logFile -Value "[$timestamp] Auto-launch started for $($servers.Count) server(s)"

# ===== LAUNCH =====
foreach ($server in $servers) {
    try {
        Start-Process "mstsc.exe" -ArgumentList "/v:$server /multimon"
        Add-Content -Path $logFile -Value "[$timestamp]   Launched: $server"
    }
    catch {
        Add-Content -Path $logFile -Value "[$timestamp]   FAILED:  $server — $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $delaySeconds
}

Add-Content -Path $logFile -Value "[$timestamp] Auto-launch complete."
