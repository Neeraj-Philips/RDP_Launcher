# ============================================
# Deploy RDP Launcher to Jump Server
# ============================================
# Copies the tool to the jump server via the
# existing RDP session's mapped drive, or via
# UNC path / robocopy.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\deploy-to-jumpserver.ps1
# ============================================

#Requires -Version 5.1

$projectRoot = Split-Path $PSScriptRoot -Parent
$configDir   = Join-Path $projectRoot "config"
$credFile    = Join-Path $configDir "credentials.txt"
$serverFile  = Join-Path $configDir "servers.txt"
$jumpServersFile = Join-Path $configDir "jumpserver-servers.txt"

# ===== LOAD CONFIG =====
$jumpServer = ""
if (Test-Path $serverFile) {
    $jumpServer = @(Get-Content $serverFile |
        Where-Object { $_ -and $_ -notmatch "^\s*#" } |
        ForEach-Object { $_.Trim() }) | Select-Object -First 1
}

$username = ""; $password = ""
if (Test-Path $credFile) {
    Get-Content $credFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -match "^Username\s*=\s*(.+)$") { $username = $Matches[1].Trim() }
        if ($line -match "^Password\s*=\s*(.+)$") { $password = $Matches[1].Trim() }
    }
}

if (-not $jumpServer) {
    Write-Host "ERROR: No jump server in config/servers.txt" -ForegroundColor Red
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

# ===== REMOTE DESTINATION =====
$remotePath = "\\$jumpServer\C$\RDP_Launcher"

Write-Host "Deploy to: $remotePath" -ForegroundColor Yellow
Write-Host ""

# ===== CONNECT TO REMOTE SHARE =====
Write-Host "Connecting to \\$jumpServer\C$..." -ForegroundColor Gray

# Store credential for net use
$secPass = ConvertTo-SecureString $password -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($username, $secPass)

# Try net use with credentials
$netResult = & net use "\\$jumpServer\C$" /user:$username $password 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "WARNING: net use failed, trying without auth..." -ForegroundColor Yellow
    Write-Host $netResult -ForegroundColor Gray
}

# ===== COPY FILES =====
Write-Host "Copying files..." -ForegroundColor Gray

$filesToCopy = @(
    @{ Src = "launch-rdp.bat";                  Dst = "launch-rdp.bat" }
    @{ Src = "launch-grid.bat";                 Dst = "launch-grid.bat" }
    @{ Src = "README.md";                       Dst = "README.md" }
    @{ Src = ".gitignore";                      Dst = ".gitignore" }
    @{ Src = "scripts\rdp-gui.ps1";             Dst = "scripts\rdp-gui.ps1" }
    @{ Src = "scripts\rdp-auto.ps1";            Dst = "scripts\rdp-auto.ps1" }
    @{ Src = "scripts\rdp-grid.ps1";            Dst = "scripts\rdp-grid.ps1" }
    @{ Src = "scripts\lib\RdpUIAutomation.cs";  Dst = "scripts\lib\RdpUIAutomation.cs" }
    @{ Src = "config\credentials.example.txt";  Dst = "config\credentials.example.txt" }
    @{ Src = "config\servers.example.txt";       Dst = "config\servers.example.txt" }
)

$errors = 0
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
    } catch {
        Write-Host "  FAIL: $($f.Src) - $($_.Exception.Message)" -ForegroundColor Red
        $errors++
    }
}

# ===== DEPLOY CREDENTIALS =====
Write-Host ""
Write-Host "Deploying credentials..." -ForegroundColor Gray

$remoteCredFile = Join-Path $remotePath "config\credentials.txt"
$remoteCredDir  = Split-Path $remoteCredFile -Parent
try {
    if (-not (Test-Path $remoteCredDir)) {
        New-Item -ItemType Directory -Path $remoteCredDir -Force | Out-Null
    }
    # Copy same credentials (same domain user for target servers)
    Copy-Item -Path $credFile -Destination $remoteCredFile -Force
    Write-Host "  OK: credentials.txt" -ForegroundColor Green
} catch {
    Write-Host "  FAIL: credentials.txt - $($_.Exception.Message)" -ForegroundColor Red
    $errors++
}

# ===== DEPLOY JUMP SERVER'S SERVER LIST =====
Write-Host "Deploying server list for jump server..." -ForegroundColor Gray

$remoteServerFile = Join-Path $remotePath "config\servers.txt"
if (Test-Path $jumpServersFile) {
    try {
        Copy-Item -Path $jumpServersFile -Destination $remoteServerFile -Force
        Write-Host "  OK: servers.txt (from jumpserver-servers.txt)" -ForegroundColor Green
    } catch {
        Write-Host "  FAIL: servers.txt - $($_.Exception.Message)" -ForegroundColor Red
        $errors++
    }
} else {
    Write-Host "  SKIP: config/jumpserver-servers.txt not found" -ForegroundColor Yellow
    Write-Host "  You'll need to edit config\servers.txt on the jump server manually." -ForegroundColor Yellow
}

# ===== CREATE EMPTY DIRS =====
foreach ($dir in @("logs", "rdp_sessions")) {
    $remoteDir = Join-Path $remotePath $dir
    if (-not (Test-Path $remoteDir)) {
        try {
            New-Item -ItemType Directory -Path $remoteDir -Force | Out-Null
        } catch {}
    }
}

# ===== CLEANUP NET USE =====
& net use "\\$jumpServer\C$" /delete 2>&1 | Out-Null

# ===== REMOTE LAUNCH =====
Write-Host ""
Write-Host "Launching RDP Grid on jump server..." -ForegroundColor Cyan

$remoteLaunchScript = "C:\RDP_Launcher\scripts\rdp-grid.ps1"

# Try Invoke-Command (WinRM / PSRemoting)
$launched = $false
try {
    $secPass = ConvertTo-SecureString $password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($username, $secPass)

    Invoke-Command -ComputerName $jumpServer -Credential $cred -ScriptBlock {
        Start-Process "powershell.exe" -ArgumentList @(
            "-ExecutionPolicy", "Bypass",
            "-File", "C:\RDP_Launcher\scripts\rdp-grid.ps1"
        ) -WindowStyle Normal
    } -ErrorAction Stop

    $launched = $true
    Write-Host "  Launched via PSRemoting (Invoke-Command)" -ForegroundColor Green
} catch {
    Write-Host "  PSRemoting failed: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  Trying PsExec..." -ForegroundColor Gray
}

# Fallback: PsExec (if installed)
if (-not $launched) {
    $psexec = Get-Command "psexec" -ErrorAction SilentlyContinue
    if ($null -eq $psexec) {
        $psexec = Get-Command "psexec64" -ErrorAction SilentlyContinue
    }
    if ($null -ne $psexec) {
        try {
            & $psexec.Source "\\$jumpServer" -u $username -p $password -d -i `
                powershell.exe -ExecutionPolicy Bypass -File "C:\RDP_Launcher\scripts\rdp-grid.ps1"
            $launched = $true
            Write-Host "  Launched via PsExec" -ForegroundColor Green
        } catch {
            Write-Host "  PsExec failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# Fallback: schtasks (create a one-time scheduled task, interactive)
if (-not $launched) {
    Write-Host "  Trying schtasks..." -ForegroundColor Gray
    try {
        $taskName = "RDP_Launcher_Grid"
        # Delete old task if exists
        & schtasks /Delete /S $jumpServer /U $username /P $password /TN $taskName /F 2>&1 | Out-Null
        # Create task that runs interactively in the user's session
        & schtasks /Create /S $jumpServer /U $username /P $password `
            /TN $taskName `
            /TR "powershell.exe -ExecutionPolicy Bypass -WindowStyle Normal -File C:\RDP_Launcher\scripts\rdp-grid.ps1" `
            /SC ONCE /ST 00:00 /F /IT 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            & schtasks /Run /S $jumpServer /U $username /P $password /TN $taskName 2>&1 | Out-Null
            $launched = $true
            Write-Host "  Launched via schtasks (interactive)" -ForegroundColor Green
        } else {
            Write-Host "  schtasks create failed" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  schtasks failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if (-not $launched) {
    Write-Host ""
    Write-Host "  Could not auto-launch remotely." -ForegroundColor Yellow
    Write-Host "  Manual steps on the jump server:" -ForegroundColor White
    Write-Host "    1. Open C:\RDP_Launcher" -ForegroundColor White
    Write-Host "    2. Double-click launch-grid.bat" -ForegroundColor White
}

# ===== SUMMARY =====
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if ($errors -eq 0 -and $launched) {
    Write-Host "  Deployed and launched!" -ForegroundColor Green
    Write-Host "  Grid sessions starting on $jumpServer" -ForegroundColor White
} elseif ($errors -eq 0) {
    Write-Host "  Deployed successfully!" -ForegroundColor Green
    Write-Host "  Auto-launch failed - run manually on jump server" -ForegroundColor Yellow
} else {
    Write-Host "  Deployed with $errors error(s)" -ForegroundColor Yellow
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "Press Enter to close"
