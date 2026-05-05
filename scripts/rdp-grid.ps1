# ============================================
# RDP Grid Launcher - Dual Monitor Layout
# ============================================
# Launches RDP sessions and auto-arranges them
# in a grid across all monitors.
#
# Layout (4 servers, 2 monitors):
#   Monitor 1          Monitor 2
#   +-----------+      +-----------+
#   | Server 1  |      | Server 3  |
#   +-----------+      +-----------+
#   | Server 2  |      | Server 4  |
#   +-----------+      +-----------+
#
# Scales to any number of servers/monitors.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\rdp-grid.ps1
# ============================================

#Requires -Version 5.1

Add-Type -AssemblyName System.Windows.Forms

# Win32 API for window positioning
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinAPI {
    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int W, int H, bool repaint);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    public const int SW_RESTORE = 9;
}
"@

$scriptDir   = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent
$configDir   = Join-Path $projectRoot "config"
$serverFile  = Join-Path $configDir  "servers.txt"
$credFile    = Join-Path $configDir  "credentials.txt"
$rdpFolder   = Join-Path $projectRoot "rdp_sessions"
$logDir      = Join-Path $projectRoot "logs"
$logFile     = Join-Path $logDir     "rdp-grid.log"
$uiaCsFile   = Join-Path $scriptDir  "lib\RdpUIAutomation.cs"

foreach ($d in @($rdpFolder, $logDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Write-Log {
    param([string]$msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] $msg"
    Add-Content -Path $logFile -Value $entry -ErrorAction SilentlyContinue
    Write-Host $entry
}

# ===== LOAD UI AUTOMATION =====
$uiaLoaded = $false
if (Test-Path $uiaCsFile) {
    try {
        Add-Type -TypeDefinition (Get-Content $uiaCsFile -Raw) `
            -ReferencedAssemblies @("UIAutomationClient","UIAutomationTypes") `
            -ErrorAction Stop
        $uiaLoaded = $true
    } catch {
        Write-Log "UIA load failed: $($_.Exception.Message)"
    }
}

function ConvertTo-SendKeysEscaped {
    param([string]$Text)
    $e = $Text
    $e = $e.Replace('{','{{}').Replace('}','{}}')
    foreach ($c in @('+','^','%','~','!','(',')','[',']')) { $e = $e.Replace($c,"{$c}") }
    return $e
}

# ===== CALCULATE GRID POSITIONS =====
function Get-GridPositions {
    param([int]$ServerCount)

    $monitors = @([System.Windows.Forms.Screen]::AllScreens)
    $monCount = $monitors.Count

    Write-Log "Monitors detected: $monCount"
    for ($i = 0; $i -lt $monCount; $i++) {
        $b = $monitors[$i].WorkingArea
        Write-Log "  Monitor $($i+1): $($b.Width)x$($b.Height) at ($($b.X),$($b.Y))"
    }

    # Distribute servers across monitors
    $serversPerMonitor = [Math]::Ceiling($ServerCount / $monCount)

    # Calculate rows/cols per monitor
    $cols = 1
    $rows = $serversPerMonitor
    if ($serversPerMonitor -gt 2) {
        $cols = 2
        $rows = [Math]::Ceiling($serversPerMonitor / $cols)
    }

    $positions = @()
    $serverIndex = 0

    foreach ($mon in $monitors) {
        $area = $mon.WorkingArea
        $cellW = [int]($area.Width / $cols)
        $cellH = [int]($area.Height / $rows)

        for ($r = 0; $r -lt $rows; $r++) {
            for ($c = 0; $c -lt $cols; $c++) {
                if ($serverIndex -ge $ServerCount) { break }
                $positions += @{
                    X = $area.X + ($c * $cellW)
                    Y = $area.Y + ($r * $cellH)
                    W = $cellW
                    H = $cellH
                }
                $serverIndex++
            }
        }
    }

    return $positions
}

# ===== LAUNCH + AUTOMATE + POSITION ONE SERVER =====
function Launch-GridSession {
    param(
        [string]$Server,
        [string]$Username,
        [string]$Password,
        [hashtable]$Position
    )

    Write-Log "--- $Server -> ($($Position.X),$($Position.Y)) $($Position.W)x$($Position.H) ---"

    # Store credential
    & cmdkey /delete:TERMSRV/$Server 2>$null | Out-Null
    & cmdkey /generic:TERMSRV/$Server /user:$Username /pass:$Password | Out-Null

    # Generate .rdp (windowed, sized to grid cell)
    $safe = $Server -replace '[^a-zA-Z0-9\.\-]', '_'
    $rdpPath = Join-Path $rdpFolder "$safe.rdp"
    @"
full address:s:$Server
username:s:$Username
prompt for credentials:i:1
authentication level:i:2
enablecredsspsupport:i:1
use multimon:i:0
screen mode id:i:1
desktopwidth:i:$($Position.W)
desktopheight:i:$($Position.H)
smart sizing:i:1
"@ | Set-Content -Path $rdpPath -Encoding ASCII

    # Launch mstsc
    $proc = Start-Process "mstsc.exe" -ArgumentList "`"$rdpPath`"" -PassThru
    Write-Log "  PID: $($proc.Id)"
    Start-Sleep -Seconds 2

    if (-not $uiaLoaded) {
        Write-Log "  UIA not available - skipping automation"
        return @{ Process = $proc; Server = $Server; Position = $Position }
    }

    # Phase 1: Security warning
    $win = [RdpUIAutomation]::FindWindowByPid($proc.Id, 20000)
    if ($null -ne $win) {
        $title = $win.Current.Name
        Write-Log "  Window: '$title'"
        $clicked = [RdpUIAutomation]::ClickButton($win, "Connect")
        if (-not $clicked) { $clicked = [RdpUIAutomation]::ClickButton($win, "Yes") }
        if (-not $clicked) { [RdpUIAutomation]::ClickFirstActionButton($win) | Out-Null }
        Write-Log "  Security warning dismissed"
    }

    # Phase 2: Wait for session or credential prompt
    $credWin = $null; $connected = $false
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $sessWin = [RdpUIAutomation]::WaitForWindowTitleByPid($proc.Id, @($Server), 1000)
        if ($null -ne $sessWin) {
            $t = $sessWin.Current.Name
            if ($t -notmatch "security warning|Connecting to|Configuring|Securing") {
                $btns = [RdpUIAutomation]::GetButtonNames($sessWin)
                if ($btns -contains "Minimize" -or $btns -contains "Restore") {
                    $connected = $true; break
                }
            }
        }
        $credWin = [RdpUIAutomation]::WaitForWindowWithEditsByPid($proc.Id, 1000)
        if ($null -ne $credWin) { break }
        Start-Sleep -Milliseconds 500
    }

    if ($connected) {
        Write-Log "  Session connected - typing credentials"
        Start-Sleep -Seconds 3
        $wsh = New-Object -ComObject WScript.Shell
        $wsh.AppActivate($proc.Id) | Out-Null
        Start-Sleep -Milliseconds 800
        $wsh.SendKeys("^a"); Start-Sleep -Milliseconds 100
        $wsh.SendKeys($Username); Start-Sleep -Milliseconds 300
        $wsh.SendKeys("{TAB}"); Start-Sleep -Milliseconds 300
        $wsh.SendKeys((ConvertTo-SendKeysEscaped $Password))
        Start-Sleep -Milliseconds 300
        $wsh.SendKeys("{ENTER}")
        Write-Log "  Credentials typed"
    } elseif ($null -ne $credWin) {
        [RdpUIAutomation]::FillCredentials($credWin, $Username, $Password) | Out-Null
        Start-Sleep -Milliseconds 800
        $ok = [RdpUIAutomation]::ClickButton($credWin, "OK")
        if (-not $ok) { [RdpUIAutomation]::ClickButton($credWin, "Submit") | Out-Null }
        Write-Log "  Credentials submitted via UIA"
    } else {
        Write-Log "  No prompt detected"
    }

    return @{ Process = $proc; Server = $Server; Position = $Position }
}

# ===== POSITION WINDOW =====
function Set-WindowPosition {
    param($ProcessInfo)

    $proc = $ProcessInfo.Process
    $pos  = $ProcessInfo.Position
    $srv  = $ProcessInfo.Server

    if ($null -eq $proc -or $proc.HasExited) {
        Write-Log "  $srv - process not running, skip positioning"
        return
    }

    # Get window handle via UI Automation (more reliable than MainWindowHandle)
    $hwnd = [IntPtr]::Zero
    if ($uiaLoaded) {
        $hwnd = [RdpUIAutomation]::GetWindowHandleByPid($proc.Id, 10000)
    }

    # Fallback to Process.MainWindowHandle
    if ($hwnd -eq [IntPtr]::Zero) {
        $proc.Refresh()
        $hwnd = $proc.MainWindowHandle
    }

    if ($hwnd -eq [IntPtr]::Zero) {
        Write-Log "  $srv - no window handle found"
        return
    }

    # Restore window if minimized, then move
    [WinAPI]::ShowWindow($hwnd, [WinAPI]::SW_RESTORE) | Out-Null
    Start-Sleep -Milliseconds 200
    $moved = [WinAPI]::MoveWindow($hwnd, $pos.X, $pos.Y, $pos.W, $pos.H, $true)
    Write-Log "  $srv - positioned at ($($pos.X),$($pos.Y)) $($pos.W)x$($pos.H) [moved=$moved]"
}

# ===== MAIN =====

Write-Log "=========================================="
Write-Log "RDP Grid Launcher"

# Load servers
if (-not (Test-Path $serverFile)) {
    Write-Log "ERROR: $serverFile not found"
    Write-Host "ERROR: config/servers.txt not found" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}
$servers = @(Get-Content (Join-Path $projectRoot "config\servers.txt") |
    Where-Object { $_ -and $_ -notmatch "^\s*#" } |
    ForEach-Object { $_.Trim() })
if ($servers.Count -eq 0) {
    Write-Log "ERROR: No servers"
    Write-Host "ERROR: No servers in config/servers.txt" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Load credentials
$username = ""; $password = ""
if (Test-Path $credFile) {
    Get-Content $credFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -match "^Username\s*=\s*(.+)$") { $username = $Matches[1].Trim() }
        if ($line -match "^Password\s*=\s*(.+)$") { $password = $Matches[1].Trim() }
    }
}
if (-not $username -or -not $password) {
    Write-Log "ERROR: No credentials"
    Write-Host "ERROR: Set credentials in config/credentials.txt" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Registry trust
try {
    $reg = "HKCU:\Software\Microsoft\Terminal Server Client"
    if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
    Set-ItemProperty -Path $reg -Name "AuthenticationLevelOverride" -Value 0 -Type DWord -Force
} catch {}

Write-Log "Servers: $($servers.Count) | User: $username | UIA: $uiaLoaded"

# Calculate grid
$positions = Get-GridPositions -ServerCount $servers.Count
Write-Log "Grid positions calculated: $($positions.Count)"

# Launch all sessions
$sessions = @()
for ($i = 0; $i -lt $servers.Count; $i++) {
    $pos = $positions[$i]
    $result = Launch-GridSession -Server $servers[$i] -Username $username -Password $password -Position $pos
    $sessions += $result
    Start-Sleep -Seconds 2
}

# Wait for all sessions to settle, then position windows
Write-Log "Waiting 5s for sessions to settle..."
Start-Sleep -Seconds 5

Write-Log "Positioning windows..."
foreach ($session in $sessions) {
    try {
        Set-WindowPosition -ProcessInfo $session
    } catch {
        Write-Log "  Position failed: $($session.Server) - $($_.Exception.Message)"
    }
}

Write-Log "All $($servers.Count) session(s) launched and arranged."
Write-Log "=========================================="
Write-Host ""
Write-Host "Done. $($servers.Count) session(s) launched and arranged." -ForegroundColor Green
Write-Host "Press Enter to close..."
Read-Host
