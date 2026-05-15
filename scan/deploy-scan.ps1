# ============================================
# Deploy Scan Script to All Machines
# ============================================
# Copies copilot-optimize-scan.ps1 to Downloads
# on all machines listed in config/scan-servers.txt
# ============================================

$ErrorActionPreference = "Continue"

$scriptDir   = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent
$configDir   = Join-Path $projectRoot "config"
$scanScript  = Join-Path $scriptDir "copilot-optimize-scan.ps1"
$serverFile  = Join-Path $configDir "scan-servers.txt"
$userFile    = Join-Path $configDir "scan-user.txt"

# Load servers from config
if (-not (Test-Path $serverFile)) {
    Write-Host "ERROR: config\scan-servers.txt not found!" -ForegroundColor Red
    exit 1
}
$servers = @(Get-Content $serverFile | Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith("#") } | ForEach-Object { $_.Trim() })

# Load credentials from config
if (-not (Test-Path $userFile)) {
    Write-Host "ERROR: config\scan-user.txt not found!" -ForegroundColor Red
    exit 1
}
$username = ""
$password = ""
Get-Content $userFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -match "^Username\s*=\s*(.+)$") { $username = $Matches[1].Trim() }
    if ($line -match "^Password\s*=\s*(.+)$") { $password = $Matches[1].Trim() }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Deploy Scan Script to All Machines" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Servers: $($servers.Count) (from config\scan-servers.txt)" -ForegroundColor Gray
Write-Host "  User:    $username" -ForegroundColor Gray
Write-Host ""

if (-not (Test-Path $scanScript)) {
    Write-Host "ERROR: copilot-optimize-scan.ps1 not found!" -ForegroundColor Red
    exit 1
}

$success = 0
$failed = 0

foreach ($server in $servers) {
    Write-Host "  $server ... " -NoNewline
    try {
        & net use "\\$server\C`$" /delete /y 2>&1 | Out-Null
        $result = & net use "\\$server\C`$" /user:$username $password 2>&1
        if ($LASTEXITCODE -ne 0) { throw "net use failed: $result" }

        $remotePath = "\\$server\C`$\Users\$username\Downloads"
        if (-not (Test-Path $remotePath)) {
            New-Item -ItemType Directory -Path $remotePath -Force | Out-Null
        }

        Copy-Item -Path $scanScript -Destination "$remotePath\copilot-optimize-scan.ps1" -Force

        & net use "\\$server\C`$" /delete /y 2>&1 | Out-Null

        Write-Host "OK" -ForegroundColor Green
        $success++
    }
    catch {
        Write-Host "FAILED ($($_.Exception.Message))" -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Done: $success copied, $failed failed" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host " Run on each machine:" -ForegroundColor White
Write-Host " powershell -ExecutionPolicy Bypass -File C:\Users\$username\Downloads\copilot-optimize-scan.ps1" -ForegroundColor Yellow
Write-Host ""
