# ============================================
# RDP Launcher - Auto Run (Scheduled Task)
# ============================================
# Generates .rdp files with embedded encrypted password
# No menus, no GUI - just launches
#
# Usage (Task Scheduler):
#   Program:   powershell.exe
#   Arguments: -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\path\to\rdp-auto.ps1"
# ============================================

Add-Type -AssemblyName System.Security

$delaySeconds = 2
$scriptDir   = $PSScriptRoot
$serverFile  = Join-Path $scriptDir "servers.txt"
$credFile    = Join-Path $scriptDir "credentials.txt"
$rdpFolder   = Join-Path $scriptDir "rdp_sessions"
$logFile     = Join-Path $scriptDir "rdp-auto.log"
$timestamp   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

if (-not (Test-Path $rdpFolder)) { New-Item -ItemType Directory -Path $rdpFolder | Out-Null }

# ===== LOAD SERVERS =====
if (-not (Test-Path $serverFile)) {
    Add-Content -Path $logFile -Value "[$timestamp] ERROR: servers.txt not found"
    exit 1
}
$servers = Get-Content $serverFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne "" -and $_ -notmatch "^\s*#" }

# ===== LOAD CREDENTIALS =====
$username = ""
$password = ""
if (Test-Path $credFile) {
    Get-Content $credFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -match "^Username\s*=\s*(.+)$") { $username = $Matches[1].Trim() }
        if ($line -match "^Password\s*=\s*(.+)$") { $password = $Matches[1].Trim() }
    }
}

if ($username -eq "" -or $password -eq "" -or $username -eq "DOMAIN\your.username") {
    Add-Content -Path $logFile -Value "[$timestamp] ERROR: No credentials in credentials.txt"
    exit 1
}

# ===== ENCRYPT PASSWORD =====
$bytes = [System.Text.Encoding]::Unicode.GetBytes($password)
$encrypted = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
$encPass = ($encrypted | ForEach-Object { '{0:X2}' -f $_ }) -join ''

Add-Content -Path $logFile -Value "[$timestamp] Auto-launch started for $($servers.Count) server(s) as $username"

# ===== LAUNCH =====
foreach ($server in $servers) {
    try {
        $safeName = $server -replace '[^a-zA-Z0-9\.\-]', '_'
        $rdpPath = Join-Path $rdpFolder "$safeName.rdp"
        $content = @"
full address:s:$server
username:s:$username
password 51:b:$encPass
prompt for credentials:i:0
authentication level:i:0
enablecredsspsupport:i:1
use multimon:i:1
"@
        Set-Content -Path $rdpPath -Value $content -Encoding ASCII
        Start-Process "mstsc.exe" -ArgumentList "`"$rdpPath`""
        Add-Content -Path $logFile -Value "[$timestamp]   Launched: $server"
    }
    catch {
        Add-Content -Path $logFile -Value "[$timestamp]   FAILED:  $server - $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $delaySeconds
}

Add-Content -Path $logFile -Value "[$timestamp] Auto-launch complete."
