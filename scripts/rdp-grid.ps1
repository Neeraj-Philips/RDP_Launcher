# ============================================
# RDP Grid Launcher (STABLE TEST VERSION)
# ============================================

#Requires -Version 5.1

param(
    [string]$ServerListFile = ""
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ===== LOAD CONFIG =====
$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir "lib\Config.ps1")

$projectRoot = Split-Path $scriptDir -Parent
$configDir   = Join-Path $projectRoot "config"
$serverFile  = if ($ServerListFile -and (Test-Path $ServerListFile)) { $ServerListFile } else { Join-Path $configDir "servers.txt" }
$rdpFolder   = Join-Path $projectRoot "rdp_sessions"
$logDir      = Join-Path $projectRoot "logs"
$logFile     = Join-Path $logDir     "rdp-grid.log"

Initialize-Directories

# ===== WIN32 =====
try {
Add-Type @"
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
}

public class WinAPI {
    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    public const int SW_RESTORE = 9;
}
"@
} catch {}

# ===== UI AUTOMATION =====
$uiAutomationPath = Join-Path $scriptDir "lib\RdpUIAutomation.cs"
$uiAutomationLoaded = $false

if (Test-Path $uiAutomationPath) {
    try {
        $csCode = Get-Content $uiAutomationPath -Raw
        Add-Type -TypeDefinition $csCode -ReferencedAssemblies @(
            "UIAutomationClient",
            "UIAutomationTypes"
        ) -ErrorAction Stop
        $uiAutomationLoaded = $true
    }
    catch {
        if ($_.Exception.Message -match "already exists") {
            $uiAutomationLoaded = $true
        }
    }
}

# ===== CREDENTIALS =====
$creds = Get-ConfiguredCredentials
$username = $creds.Username
$password = $creds.Password

if (-not $username) {
    Write-Host "No username configured"
    exit 1
}

# ===== GRID =====
function Get-MonitorLayout {
    <#
    .SYNOPSIS
    Detects all monitors and returns their bounds sorted left-to-right.
    #>
    $screens = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }

    $monitors = @()
    foreach ($scr in $screens) {
        $monitors += @{
            X      = $scr.Bounds.X
            Y      = $scr.Bounds.Y
            Width  = $scr.Bounds.Width
            Height = $scr.Bounds.Height
            Name   = $scr.DeviceName
        }
    }

    return $monitors
}

function Get-GridPositions {
    param([int]$ServerCount)

    <#
    .SYNOPSIS
    Dynamically calculates grid positions based on actual monitor layout
    and the number of servers to launch.

    Strategy:
    - Detect all monitors (sorted left to right)
    - Distribute servers evenly across monitors
    - For each monitor, calculate a grid (cols x rows) to fit its share
    - Return positions as array: [0,0], [0,1], [1,0], [1,1], etc.
    #>

    $monitors = Get-MonitorLayout
    $monitorCount = $monitors.Count

    Write-Log -Message "Detected $monitorCount monitor(s):" -LogFile $logFile
    foreach ($mon in $monitors) {
        Write-Log -Message "  $($mon.Name): $($mon.Width)x$($mon.Height) at ($($mon.X),$($mon.Y))" -LogFile $logFile
    }

    if ($ServerCount -eq 0) { return @() }

    # Distribute servers across monitors as evenly as possible
    $serversPerMonitor = @()
    $baseCount = [Math]::Floor($ServerCount / $monitorCount)
    $remainder = $ServerCount % $monitorCount

    for ($m = 0; $m -lt $monitorCount; $m++) {
        $count = $baseCount
        if ($m -lt $remainder) { $count++ }
        $serversPerMonitor += $count
    }

    Write-Log -Message "Distribution: $($serversPerMonitor -join ', ') servers per monitor" -LogFile $logFile

    # Calculate grid positions for each monitor
    $positions = @()

    for ($m = 0; $m -lt $monitorCount; $m++) {
        $mon = $monitors[$m]
        $count = $serversPerMonitor[$m]

        if ($count -eq 0) { continue }

        # Calculate optimal grid dimensions (cols x rows) for this monitor's share
        # Prefer wider cells (more cols) since RDP windows are landscape
        $cols = [Math]::Ceiling([Math]::Sqrt($count))
        $rows = [Math]::Ceiling($count / $cols)

        $cellW = [Math]::Floor($mon.Width / $cols)
        $cellH = [Math]::Floor($mon.Height / $rows)

        Write-Log -Message "  Monitor $m grid: ${cols}x${rows} cells (${cellW}x${cellH} each) for $count server(s)" -LogFile $logFile

        # Fill grid row by row: [0,0], [0,1], [1,0], [1,1], ...
        $placed = 0
        for ($row = 0; $row -lt $rows -and $placed -lt $count; $row++) {
            for ($col = 0; $col -lt $cols -and $placed -lt $count; $col++) {
                $positions += @{
                    X = $mon.X + ($col * $cellW)
                    Y = $mon.Y + ($row * $cellH)
                    W = $cellW
                    H = $cellH
                }
                $placed++
            }
        }
    }

    return $positions
}

# ===== VERIFY & FIX POSITIONS =====
function Verify-WindowPositions {
    <#
    .SYNOPSIS
    After all windows are launched, verify each one is at its expected position.
    If a window is misplaced, reposition it. Retries up to 3 times.
    #>
    param(
        [array]$LaunchedProcs,
        [array]$Positions
    )

    Write-Log -Message "--- Verifying window positions ---" -LogFile $logFile

    $misplaced = 0
    $fixed = 0
    $tolerance = 20  # pixels tolerance for position check

    foreach ($entry in $LaunchedProcs) {
        $proc = $entry.Proc
        $idx = $entry.Index
        $pos = $Positions[$idx]

        try {
            $proc.Refresh()
            $hwnd = $proc.MainWindowHandle

            if ($hwnd -eq [IntPtr]::Zero) {
                Write-Log -Message "  Slot $($idx+1): No window handle - skipping" -LogFile $logFile -Level "WARN"
                continue
            }

            # Get actual window position
            $rect = New-Object RECT
            $gotRect = [WinAPI]::GetWindowRect($hwnd, [ref]$rect)

            if (-not $gotRect) {
                Write-Log -Message "  Slot $($idx+1): GetWindowRect failed" -LogFile $logFile -Level "WARN"
                continue
            }

            $actualX = $rect.Left
            $actualY = $rect.Top
            $actualW = $rect.Right - $rect.Left
            $actualH = $rect.Bottom - $rect.Top

            $expectedX = $pos.X
            $expectedY = $pos.Y
            $expectedW = $pos.W
            $expectedH = $pos.H

            # Check if position matches within tolerance
            $xOk = [Math]::Abs($actualX - $expectedX) -le $tolerance
            $yOk = [Math]::Abs($actualY - $expectedY) -le $tolerance
            $wOk = [Math]::Abs($actualW - $expectedW) -le $tolerance
            $hOk = [Math]::Abs($actualH - $expectedH) -le $tolerance

            if ($xOk -and $yOk -and $wOk -and $hOk) {
                Write-Log -Message "  Slot $($idx+1): OK at ($actualX,$actualY ${actualW}x${actualH})" -LogFile $logFile
            } else {
                $misplaced++
                Write-Log -Message "  Slot $($idx+1): MISPLACED at ($actualX,$actualY ${actualW}x${actualH}) expected ($expectedX,$expectedY ${expectedW}x${expectedH})" -LogFile $logFile -Level "WARN"

                # Retry repositioning up to 3 times
                $repositioned = $false
                for ($retry = 1; $retry -le 3; $retry++) {
                    [WinAPI]::ShowWindow($hwnd, [WinAPI]::SW_RESTORE) | Out-Null
                    Start-Sleep -Milliseconds 300
                    [WinAPI]::MoveWindow($hwnd, $expectedX, $expectedY, $expectedW, $expectedH, $true) | Out-Null
                    Start-Sleep -Milliseconds 500

                    # Verify again
                    $rect2 = New-Object RECT
                    [WinAPI]::GetWindowRect($hwnd, [ref]$rect2) | Out-Null
                    $newX = $rect2.Left
                    $newY = $rect2.Top

                    if ([Math]::Abs($newX - $expectedX) -le $tolerance -and [Math]::Abs($newY - $expectedY) -le $tolerance) {
                        $repositioned = $true
                        $fixed++
                        Write-Log -Message "  Slot $($idx+1): FIXED on retry $retry -> ($newX,$newY)" -LogFile $logFile
                        break
                    }
                }

                if (-not $repositioned) {
                    Write-Log -Message "  Slot $($idx+1): Could not fix after 3 retries" -LogFile $logFile -Level "ERROR"
                }
            }
        }
        catch {
            Write-Log -Message "  Slot $($idx+1): Verify error: $($_.Exception.Message)" -LogFile $logFile -Level "WARN"
        }
    }

    Write-Log -Message "--- Verification complete: $misplaced misplaced, $fixed fixed ---" -LogFile $logFile
}

# ===== FOCUS WINDOW =====
function Focus-Window {
    param([System.Diagnostics.Process]$Process)

    $Process.Refresh()
    $hwnd = $Process.MainWindowHandle

    if ($hwnd -ne [IntPtr]::Zero) {
        [WinAPI]::ShowWindow($hwnd, [WinAPI]::SW_RESTORE) | Out-Null
        Start-Sleep -Milliseconds 200
        #[WinAPI]::SetForegroundWindow($hwnd) | Out-Null
        Start-Sleep -Milliseconds 500
        return $true
    }

    # Fallback: AppActivate
    try {
        $wshell = New-Object -ComObject WScript.Shell
        $wshell.AppActivate($Process.Id) | Out-Null
        Start-Sleep -Milliseconds 500
        return $true
    } catch {}

    return $false
}

# ===== MOVE WINDOW =====
function Move-RdpWindow {
    param($Process, $Position)

    try {
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            $Process.Refresh()
            $hwnd = $Process.MainWindowHandle

            if ($hwnd -ne 0) {
                #[WinAPI]::ShowWindow($hwnd, [WinAPI]::SW_RESTORE) | Out-Null
                Start-Sleep -Milliseconds 300
                [WinAPI]::MoveWindow(
                    $hwnd,
                    $Position.X,
                    $Position.Y,
                    $Position.W,
                    $Position.H,
                    $true
                ) | Out-Null
                return $true
            }
        }
        return $false
    }
    catch { return $false }
}

# ===== AUTO LOGIN =====
function Invoke-AutoLogin {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Server,
        [string]$Username,
        [string]$Password
    )

    if (-not $uiAutomationLoaded -or -not $Password) { return }

    $securityTitles = @(
        "security", "certificate", "trust",
        "warning", "Remote Desktop Connection"
    )

    # Phase 1: Dismiss security warning(s)
    for ($w = 0; $w -lt 3; $w++) {
        $timeout = if ($w -eq 0) { 10000 } else { 3000 }
        $secWin = [RdpUIAutomation]::WaitForWindowTitleByPid(
            $Process.Id, $securityTitles, $timeout
        )

        if ($null -ne $secWin) {
            Write-Log -Message "  Warning dialog #$($w+1): '$($secWin.Current.Name)'" -LogFile $logFile
            $clicked = [RdpUIAutomation]::ClickButton($secWin, "Yes")
            if (-not $clicked) { $clicked = [RdpUIAutomation]::ClickButton($secWin, "Connect") }
            if (-not $clicked) { [RdpUIAutomation]::ClickFirstActionButton($secWin) | Out-Null }
            Write-Log -Message "  Warning dismissed" -LogFile $logFile
            Start-Sleep -Seconds 2
        } else {
            break
        }
    }

    # Phase 2: Wait for session window
    Start-Sleep -Seconds 3

    $sessionTitles = @($Server, "Remote Desktop")
    $sessionWin = [RdpUIAutomation]::WaitForWindowTitleByPid(
        $Process.Id, $sessionTitles, 10000
    )

    if ($null -ne $sessionWin) {
        Write-Log -Message "  Session connected: '$($sessionWin.Current.Name)'" -LogFile $logFile
        Start-Sleep -Seconds 2

        # FOCUS the RDP window before sending keys
        $focused = Focus-Window -Process $Process
        Write-Log -Message "  Window focused: $focused" -LogFile $logFile

        if ($focused) {
            Start-Sleep -Milliseconds 500
            [System.Windows.Forms.SendKeys]::SendWait("{TAB}")
            Start-Sleep -Milliseconds 300
            [System.Windows.Forms.SendKeys]::SendWait($Password)
            Start-Sleep -Milliseconds 300
            [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
            Write-Log -Message "  Credentials typed" -LogFile $logFile
        } else {
            Write-Log -Message "  Could not focus window - credentials not sent" -LogFile $logFile -Level "WARN"
        }
    } else {
        # NLA prompt fallback
        $credWin = [RdpUIAutomation]::WaitForWindowWithEditsByPid($Process.Id, 5000)
        if ($null -ne $credWin) {
            Write-Log -Message "  NLA prompt detected" -LogFile $logFile
            [RdpUIAutomation]::FillCredentials($credWin, $Username, $Password) | Out-Null
            Start-Sleep -Milliseconds 500
            $clicked = [RdpUIAutomation]::ClickButton($credWin, "OK")
            if (-not $clicked) { [RdpUIAutomation]::ClickFirstActionButton($credWin) | Out-Null }
            Write-Log -Message "  Credentials submitted" -LogFile $logFile
        } else {
            Write-Log -Message "  No session or prompt found" -LogFile $logFile -Level "WARN"
        }
    }

    # Phase 3: Post-login warning
    Start-Sleep -Seconds 2
    $secWin3 = [RdpUIAutomation]::WaitForWindowTitleByPid($Process.Id, $securityTitles, 3000)
    if ($null -ne $secWin3) {
        [RdpUIAutomation]::ClickButton($secWin3, "Yes") | Out-Null
        Write-Log -Message "  Post-login warning dismissed" -LogFile $logFile
    }
}

# ===== MAIN =====
Write-Log -Message "==========================================" -LogFile $logFile
Write-Log -Message "RDP Grid Launcher" -LogFile $logFile
Write-Log -Message "Username: $username" -LogFile $logFile

[array]$servers = Get-ValidatedServers -Path $serverFile -LogFile $logFile

if ($servers.Count -eq 0) {
    Write-Log -Message "No servers configured" -LogFile $logFile -Level "ERROR"
    exit 1
}

Write-Log -Message "Servers: $($servers.Count)" -LogFile $logFile

# Check for saved layout file (captured from Dashboard)
$layoutFile = Join-Path $configDir "layout.txt"
$savedLayout = @{}
if (Test-Path $layoutFile) {
    Get-Content $layoutFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#")) {
            $parts = $line -split '\|'
            if ($parts.Count -eq 5) {
                $savedLayout[$parts[0]] = @{
                    X = [int]$parts[1]
                    Y = [int]$parts[2]
                    W = [int]$parts[3]
                    H = [int]$parts[4]
                }
            }
        }
    }
    Write-Log -Message "Saved layout loaded: $($savedLayout.Count) entries" -LogFile $logFile
}

# Use saved layout positions if available, otherwise calculate dynamic grid
$useSavedLayout = ($savedLayout.Count -gt 0)
$positions = @()

if ($useSavedLayout) {
    # Build positions array from saved layout (in server order)
    foreach ($srv in $servers) {
        if ($savedLayout.ContainsKey($srv)) {
            $positions += $savedLayout[$srv]
        } else {
            # No saved position for this server - will use dynamic fallback
            $positions += $null
        }
    }
    Write-Log -Message "Using saved layout" -LogFile $logFile
} else {
    $positions = Get-GridPositions -ServerCount $servers.Count
    Write-Log -Message "Using dynamic grid layout" -LogFile $logFile
}

# Cleanup old RDP files
Get-ChildItem $rdpFolder -Filter "*.rdp" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

# Check already connected
$alreadyConnected = @()
$existingMstsc = Get-Process -Name "mstsc" -ErrorAction SilentlyContinue
if ($existingMstsc) {
    foreach ($p in $existingMstsc) {
        try {
            $title = $p.MainWindowTitle
            foreach ($s in $servers) {
                if ($title -match [regex]::Escape($s)) {
                    $alreadyConnected += $s
                    Write-Log -Message "  Already connected: $s" -LogFile $logFile
                }
            }
        } catch {}
    }
}

# Track launched processes for final reposition
$launchedProcs = @()

# Launch sequentially
for ($i = 0; $i -lt $servers.Count; $i++) {

    $server = $servers[$i]

    if ($alreadyConnected -contains $server) {
        Write-Log -Message "--- $server --- SKIPPED (already connected)" -LogFile $logFile
        continue
    }

    if ($i -ge $positions.Count) {
        Write-Log -Message "No grid slot for $server" -LogFile $logFile -Level "WARN"
        break
    }

    $pos = $positions[$i]

    # If no saved position for this server, calculate a fallback
    if ($null -eq $pos) {
        $fallback = Get-GridPositions -ServerCount $servers.Count
        if ($i -lt $fallback.Count) {
            $pos = $fallback[$i]
        } else {
            Write-Log -Message "No position available for $server" -LogFile $logFile -Level "WARN"
            continue
        }
    }

    Write-Log -Message "--- $server ---" -LogFile $logFile

    try {
        # Store creds
        $cmdkeyList = & cmdkey /list 2>&1 | Out-String
        if ($cmdkeyList -notmatch [regex]::Escape("TERMSRV/$server")) {
            if ($password) {
                & cmdkey /generic:TERMSRV/$server /user:$username /pass:$password | Out-Null
            }
        }

        # RDP FILE
        $safe = $server -replace '[^a-zA-Z0-9\.\-]', '_'
        $rdpPath = Join-Path $rdpFolder "$safe.rdp"

        # Use full monitor resolution for desktop size so maximize works properly
        # smart sizing scales it down in the grid cell
        $monitors = Get-MonitorLayout
        $currentMon = $monitors[0]  # default to first monitor
        foreach ($mon in $monitors) {
            if ($pos.X -ge $mon.X -and $pos.X -lt ($mon.X + $mon.Width)) {
                $currentMon = $mon
                break
            }
        }

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
desktopwidth:i:$($currentMon.Width)
desktopheight:i:$($currentMon.Height)
smart sizing:i:1
redirectclipboard:i:1
winposstr:s:0,1,$winLeft,$winTop,$winRight,$winBottom
"@ | Set-Content -Path $rdpPath -Encoding ASCII

        Write-Log -Message "  Launching mstsc..." -LogFile $logFile

        # LAUNCH
        $proc = Start-Process "mstsc.exe" -ArgumentList "`"$rdpPath`"" -PassThru

        if ($null -eq $proc) { throw "Failed to start mstsc" }

        Write-Log -Message "  PID: $($proc.Id)" -LogFile $logFile

        # Wait for window
        Start-Sleep -Seconds 3

        # Position
        $moved = Move-RdpWindow -Process $proc -Position $pos
        if ($moved) {
            Write-Log -Message "  Positioned at slot $($i+1)" -LogFile $logFile
        }

        # Login
        Invoke-AutoLogin -Process $proc -Server $server -Username $username -Password $password

        $launchedProcs += @{ Proc = $proc; Index = $i }

    }
    catch {
        Write-Log -Message "  FAILED: $($_.Exception.Message)" -LogFile $logFile -Level "ERROR"
    }

    Start-Sleep -Seconds 5
}

# ===== POST-LAUNCH COMPLETE =====
Write-Log -Message "" -LogFile $logFile
Write-Log -Message "All launches complete." -LogFile $logFile

Write-Log -Message "==========================================" -LogFile $logFile
Write-Log -Message "RDP Grid Launcher finished" -LogFile $logFile
Write-Log -Message "==========================================" -LogFile $logFile

