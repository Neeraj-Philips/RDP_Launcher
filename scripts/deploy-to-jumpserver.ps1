# ============================================
# Deploy RDP Launcher to Jump Server
# ============================================
# Copies the tool to the jump server via the
# admin share (\\server\C$). Uses Windows
# Credential Manager or interactive prompt.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\deploy-to-jumpserver.ps1
# ============================================

#Requires -Version 5.1

$ErrorActionPreference = "Stop"

# ===== LOAD SHARED CONFIG =====
$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir "lib\Config.ps1")

$projectRoot = Split-Path $scriptDir -Parent
$configDir   = Join-Path $projectRoot "config"
$serverFile  = Join-Path $configDir "servers.txt"
$jumpServersFile = Join-Path $configDir "jumpserver-servers.txt"
$logDir      = Join-Path $projectRoot "logs"
$logFile     = Join-Path $logDir "deploy.log"

Initialize-Directories

# ===== LOAD CONFIG =====
$jumpServer = ""
[array]$servers = Get-ValidatedServers -Path $serverFile -LogFile $logFile
if ($servers.Count -gt 0) {
    $jumpServer = $servers[0]
}

$creds = Get-ConfiguredCredentials
$username = $creds.Username
$password = $creds.Password

if (-not $jumpServer) {
    Write-Host "ERROR: No jump server configured in config/servers.txt" -ForegroundColor Red
    Write-Log -Message "No jump server in servers.txt" -LogFile $logFile -Level "ERROR"
    Read-Host "Press Enter to exit"
    exit 1
}

if (-not $username) {
    Write-Host "ERROR: No username configured in config/user.txt" -ForegroundColor Red
    Write-Log -Message "No username in user.txt" -LogFile $logFile -Level "ERROR"
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Deploy RDP Launcher to Jump Server" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Jump Server : $jumpServer"
Write-Host "  Username    : $username"
Write-Host "  Source      : $projectRoot"
Write-Host ""

Write-Log -Message "Deploy started: $jumpServer as $username" -LogFile $logFile

# ===== REMOTE DESTINATION =====
$remotePath = "\\$jumpServer\C`$\RDP_Launcher"

Write-Host "Deploy to: $remotePath" -ForegroundColor Yellow
Write-Host ""

# ===== CONNECT TO REMOTE SHARE =====
Write-Host "Connecting to \\$jumpServer\C`$..." -ForegroundColor Gray

# Use password from config, or prompt if not set
if ($password) {
    $netUser = $username
    $netPassword = $password
} else {
    $cred = Get-Credential -UserName $username -Message "Enter credentials for $jumpServer deployment"
    if ($null -eq $cred) {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
    $netPassword = $cred.GetNetworkCredential().Password
    $netUser = $cred.UserName
}

# Disconnect any existing connection first (avoids error 1219)
try { & net use "\\$jumpServer\C`$" /delete 2>&1 | Out-Null } catch {}

# Connect with credentials
$netResult = & net use "\\$jumpServer\C`$" /user:$netUser $netPassword 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "WARNING: net use with credentials failed, trying current session..." -ForegroundColor Yellow
    Write-Log -Message "net use with creds failed, trying without" -LogFile $logFile -Level "WARN"

    $netResult = & net use "\\$jumpServer\C`$" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Cannot connect to \\$jumpServer\C`$" -ForegroundColor Red
        Write-Host $netResult -ForegroundColor Gray
        Write-Log -Message "net use failed completely: $netResult" -LogFile $logFile -Level "ERROR"
        Read-Host "Press Enter to exit"
        exit 1
    }
}

Write-Host "  Connected" -ForegroundColor Green
Write-Log -Message "Connected to \\$jumpServer\C`$" -LogFile $logFile

# ===== COPY FILES =====
Write-Host "Copying files..." -ForegroundColor Gray

$filesToCopy = @(
    @{ Src = "launch-rdp.bat";                  Dst = "launch-rdp.bat" }
    @{ Src = "launch-grid.bat";                 Dst = "launch-grid.bat" }
    @{ Src = "README.md";                       Dst = "README.md" }
    @{ Src = "scripts\rdp-gui.ps1";             Dst = "scripts\rdp-gui.ps1" }
    @{ Src = "scripts\rdp-auto.ps1";            Dst = "scripts\rdp-auto.ps1" }
    @{ Src = "scripts\rdp-grid.ps1";            Dst = "scripts\rdp-grid.ps1" }
    @{ Src = "scripts\lib\Config.ps1";          Dst = "scripts\lib\Config.ps1" }
    @{ Src = "scripts\lib\RdpUIAutomation.cs";  Dst = "scripts\lib\RdpUIAutomation.cs" }
    @{ Src = "config\servers.example.txt";      Dst = "config\servers.example.txt" }
    @{ Src = "config\user.txt";                 Dst = "config\user.txt" }
)

$errors = 0
$copied = 0
foreach ($f in $filesToCopy) {
    $src = Join-Path $projectRoot $f.Src
    $dst = Join-Path $remotePath $f.Dst
    $dstDir = Split-Path $dst -Parent

    if (-not (Test-Path $src)) {
        Write-Host "  SKIP: $($f.Src) (not found)" -ForegroundColor Yellow
        continue
    }

    try {
        if (-not (Test-Path $dstDir)) {
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        }
        Copy-Item -Path $src -Destination $dst -Force
        Write-Host "  OK: $($f.Src)" -ForegroundColor Green
        $copied++
    }
    catch {
        Write-Host "  FAIL: $($f.Src) - $($_.Exception.Message)" -ForegroundColor Red
        Write-Log -Message "Copy failed: $($f.Src) - $($_.Exception.Message)" -LogFile $logFile -Level "ERROR"
        $errors++
    }
}

# ===== DEPLOY JUMP SERVER'S SERVER LIST =====
Write-Host ""
Write-Host "Deploying server list for jump server..." -ForegroundColor Gray

$remoteServerFile = Join-Path $remotePath "config\servers.txt"
if (Test-Path $jumpServersFile) {
    try {
        $remoteConfigDir = Join-Path $remotePath "config"
        if (-not (Test-Path $remoteConfigDir)) {
            New-Item -ItemType Directory -Path $remoteConfigDir -Force | Out-Null
        }
        Copy-Item -Path $jumpServersFile -Destination $remoteServerFile -Force
        Write-Host "  OK: servers.txt (from jumpserver-servers.txt)" -ForegroundColor Green
        $copied++
    }
    catch {
        Write-Host "  FAIL: servers.txt - $($_.Exception.Message)" -ForegroundColor Red
        Write-Log -Message "Server list deploy failed: $($_.Exception.Message)" -LogFile $logFile -Level "ERROR"
        $errors++
    }
} else {
    Write-Host "  SKIP: config/jumpserver-servers.txt not found" -ForegroundColor Yellow
    Write-Host "  Edit config\servers.txt on the jump server manually." -ForegroundColor Yellow
}

# ===== CREATE EMPTY DIRS =====
foreach ($dir in @("logs", "rdp_sessions")) {
    $remoteDir = Join-Path $remotePath $dir
    if (-not (Test-Path $remoteDir)) {
        try {
            New-Item -ItemType Directory -Path $remoteDir -Force | Out-Null
        }
        catch {
            Write-Log -Message "Failed to create $dir on remote: $($_.Exception.Message)" -LogFile $logFile -Level "WARN"
        }
    }
}

# ===== CLEANUP NET USE =====
& net use "\\$jumpServer\C`$" /delete 2>&1 | Out-Null

# ===== SUMMARY =====
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if ($errors -eq 0) {
    Write-Host "  Deployed successfully! ($copied files)" -ForegroundColor Green
    Write-Log -Message "Deploy complete: $copied files" -LogFile $logFile
} else {
    Write-Host "  Deployed with $errors error(s) ($copied files copied)" -ForegroundColor Yellow
    Write-Log -Message "Deploy complete with errors: $copied ok, $errors failed" -LogFile $logFile -Level "WARN"
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Now RDP into $jumpServer and run:" -ForegroundColor White
Write-Host "    C:\RDP_Launcher\launch-grid.bat" -ForegroundColor White
Write-Host ""
Read-Host "Press Enter to close"
