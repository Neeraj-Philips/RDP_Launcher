# ============================================
# Scan Grid Launcher
# ============================================
# 1. Copies scan script to all machines via C$ share
# 2. Launches RDP to all machines in a grid
# 3. You manually run the scan in each session
# ============================================

#Requires -Version 5.1

$ErrorActionPreference = "Continue"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ===== CONFIG =====
$scriptDir   = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent
$configDir   = Join-Path $projectRoot "config"
$rdpFolder   = Join-Path $projectRoot "rdp_sessions"
$logDir      = Join-Path $projectRoot "logs"
$scanScript  = Join-Path $scriptDir "copilot-optimize-scan.ps1"
$logFile     = Join-Path $logDir "launch-scan-grid.log"

# Ensure folders exist
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
if (-not (Test-Path $rdpFolder)) { New-Item -ItemType Directory -Path $rdpFolder -Force | Out-Null }

# Start transcript
Start-Transcript -Path $logFile -Force

# Load from config files
$serverFile = Join-Path $configDir "scan-servers.txt"
$userFile   = Join-Path $configDir "scan-user.txt"

if (-not (Test-Path $serverFile)) {
    Write-Host "ERROR: config\scan-servers.txt not found!" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $userFile)) {
    Write-Host "ERROR: config\scan-user.txt not found!" -ForegroundColor Red
    exit 1
}

$servers = @(Get-Content $serverFile | Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith("#") } | ForEach-Object { $_.Trim() })

$username = ""
$password = ""
Get-Content $userFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -match "^Username\s*=\s*(.+)$") { $username = $Matches[1].Trim() }
    if ($line -match "^Password\s*=\s*(.+)$") { $password = $Matches[1].Trim() }
}

# ===== UI AUTOMATION (for dismissing warnings) =====
$uiAutomationPath = Join-Path $projectRoot "scripts\lib\RdpUIAutomation.cs"
$uiAutomationLoaded = $false

if (Test-Path $uiAutomationPath) {
    try {
        $csCode = Get-Content $uiAutomationPath -Raw
        Add-Type -TypeDefinition $csCode -ReferencedAssemblies @(
            "UIAutomationClient",
            "UIAutomationTypes"
        ) -ErrorAction Stop
        $uiAutomationLoaded = $true
        Write-Host "  UI Automation loaded (will auto-dismiss warnings)" -ForegroundColor Green
    }
    catch {
        if ($_.Exception.Message -match "already exists") {
            $uiAutomationLoaded = $true
        } else {
            Write-Host "  UI Automation not available - dismiss warnings manually" -ForegroundColor Yellow
        }
    }
}

function Dismiss-RdpWarnings {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Server
    )

    if (-not $uiAutomationLoaded) { return }

    $securityTitles = @("security", "certificate", "trust", "warning", "Remote Desktop Connection")

    for ($w = 0; $w -lt 3; $w++) {
        $timeout = if ($w -eq 0) { 8000 } else { 3000 }
        $secWin = [RdpUIAutomation]::WaitForWindowTitleByPid($Process.Id, $securityTitles, $timeout)

        if ($null -ne $secWin) {
            Write-Host "    Warning dialog: '$($secWin.Current.Name)' - dismissing..." -ForegroundColor Gray
            $clicked = [RdpUIAutomation]::ClickButton($secWin, "Yes")
            if (-not $clicked) { $clicked = [RdpUIAutomation]::ClickButton($secWin, "Connect") }
            if (-not $clicked) { [RdpUIAutomation]::ClickFirstActionButton($secWin) | Out-Null }
            Start-Sleep -Seconds 2
        } else {
            break
        }
    }
}

# ===== STEP 1: Copy scan script to all machines =====
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " STEP 1: Copying scan script to all machines" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $scanScript)) {
    Write-Host "ERROR: copilot-optimize-scan.ps1 not found!" -ForegroundColor Red
    exit 1
}

foreach ($server in $servers) {
    Write-Host "  $server ... " -NoNewline
    try {
        & net use "\\$server\C`$" /delete /y 2>&1 | Out-Null
        $result = & net use "\\$server\C`$" /user:$username $password 2>&1
        if ($LASTEXITCODE -ne 0) { throw "net use failed" }

        $remotePath = "\\$server\C`$\Users\$username\Downloads"
        if (-not (Test-Path $remotePath)) {
            New-Item -ItemType Directory -Path $remotePath -Force | Out-Null
        }

        Copy-Item -Path $scanScript -Destination "$remotePath\copilot-optimize-scan.ps1" -Force
        & net use "\\$server\C`$" /delete /y 2>&1 | Out-Null

        Write-Host "OK" -ForegroundColor Green
    }
    catch {
        Write-Host "FAILED ($($_.Exception.Message))" -ForegroundColor Red
    }
}

# ===== STEP 2: Launch RDP sessions in grid =====
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " STEP 2: Launching RDP sessions" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Store credentials
foreach ($server in $servers) {
    & cmdkey /generic:TERMSRV/$server /user:$username /pass:$password 2>&1 | Out-Null
}

# Get monitor layout
$screens = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }
$monitorCount = $screens.Count

Write-Host "  Monitors detected: $monitorCount" -ForegroundColor Gray

# Calculate grid positions
$serverCount = $servers.Count
$serversPerMonitor = @()
$baseCount = [Math]::Floor($serverCount / $monitorCount)
$remainder = $serverCount % $monitorCount

for ($m = 0; $m -lt $monitorCount; $m++) {
    $count = $baseCount
    if ($m -lt $remainder) { $count++ }
    $serversPerMonitor += $count
}

$positions = @()
$serverIdx = 0

for ($m = 0; $m -lt $monitorCount; $m++) {
    $scr = $screens[$m]
    $count = $serversPerMonitor[$m]
    if ($count -eq 0) { continue }

    $cols = [Math]::Ceiling([Math]::Sqrt($count))
    $rows = [Math]::Ceiling($count / $cols)
    $cellW = [Math]::Floor($scr.Bounds.Width / $cols)
    $cellH = [Math]::Floor($scr.Bounds.Height / $rows)

    for ($row = 0; $row -lt $rows -and $serverIdx -lt ($positions.Count + $count); $row++) {
        for ($col = 0; $col -lt $cols -and $serverIdx -lt $serverCount; $col++) {
            $positions += @{
                X = $scr.Bounds.X + ($col * $cellW)
                Y = $scr.Bounds.Y + ($row * $cellH)
                W = $cellW
                H = $cellH
            }
            $serverIdx++
        }
    }
}

# Clean old RDP files
Get-ChildItem $rdpFolder -Filter "*.rdp" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

# Launch each RDP session
for ($i = 0; $i -lt $servers.Count; $i++) {
    $server = $servers[$i]
    $pos = $positions[$i]

    Write-Host "  Launching $server (slot $($i+1))..." -ForegroundColor Yellow

    $safe = $server -replace '[^a-zA-Z0-9\.\-]', '_'
    $rdpPath = Join-Path $rdpFolder "$safe.rdp"

    $winLeft   = $pos.X
    $winTop    = $pos.Y
    $winRight  = $pos.X + $pos.W
    $winBottom = $pos.Y + $pos.H

    @"
full address:s:$server
username:s:$username
prompt for credentials:i:0
authentication level:i:0
enablecredsspsupport:i:1
screen mode id:i:1
desktopwidth:i:1920
desktopheight:i:1080
smart sizing:i:1
dynamic resolution:i:1
desktop size id:i:0
redirectclipboard:i:1
winposstr:s:0,1,$winLeft,$winTop,$winRight,$winBottom
"@ | Set-Content -Path $rdpPath -Encoding ASCII

    $proc = Start-Process "mstsc.exe" -ArgumentList "`"$rdpPath`"" -PassThru
    Start-Sleep -Seconds 3

    if ($null -ne $proc) {
        Dismiss-RdpWarnings -Process $proc -Server $server
    }

    Start-Sleep -Seconds 2
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " All $($servers.Count) RDP sessions launched!" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Run scan in each machine:" -ForegroundColor White
Write-Host "  powershell -ExecutionPolicy Bypass -File C:\Users\$username\Downloads\copilot-optimize-scan.ps1" -ForegroundColor Yellow
Write-Host ""
Write-Host "  You can resize/expand any window freely." -ForegroundColor Gray
Write-Host ""

Stop-Transcript
