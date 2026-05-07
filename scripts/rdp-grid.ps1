# ============================================
# RDP Grid Launcher (STABLE TEST VERSION)
# ============================================

#Requires -Version 5.1

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ===== LOAD CONFIG =====
$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir "lib\Config.ps1")

$projectRoot = Split-Path $scriptDir -Parent
$configDir   = Join-Path $projectRoot "config"
$serverFile  = Join-Path $configDir  "servers.txt"
$rdpFolder   = Join-Path $projectRoot "rdp_sessions"
$logDir      = Join-Path $projectRoot "logs"
$logFile     = Join-Path $logDir     "rdp-grid.log"

Initialize-Directories

# ===== WIN32 =====
try {
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class WinAPI {
    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

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
function Get-GridPositions {
    # Display1: 1920x1080 at X=0 (Primary, right screen)
    # Display2: 1920x1080 at X=-1920 (left screen)
    # 3 windows per monitor, each 960x540

    return @(
        # Left monitor (Display2: starts at X=-1920)
        @{ X = -1920; Y = 0;   W = 960; H = 540 }
        @{ X = -960;  Y = 0;   W = 960; H = 540 }
        @{ X = -1920; Y = 540; W = 960; H = 540 }

        # Right monitor (Display1: starts at X=0)
        @{ X = 0;    Y = 0;   W = 960; H = 540 }
        @{ X = 960;  Y = 0;   W = 960; H = 540 }
        @{ X = 0;    Y = 540; W = 960; H = 540 }
    )
}

# ===== FOCUS WINDOW =====
function Focus-Window {
    param([System.Diagnostics.Process]$Process)

    $Process.Refresh()
    $hwnd = $Process.MainWindowHandle

    if ($hwnd -ne [IntPtr]::Zero) {
        [WinAPI]::ShowWindow($hwnd, [WinAPI]::SW_RESTORE) | Out-Null
        Start-Sleep -Milliseconds 200
        [WinAPI]::SetForegroundWindow($hwnd) | Out-Null
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
                [WinAPI]::ShowWindow($hwnd, [WinAPI]::SW_RESTORE) | Out-Null
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

$positions = Get-GridPositions

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

@"
full address:s:$server
username:s:$username
prompt for credentials:i:0
authentication level:i:0
enablecredsspsupport:i:1
screen mode id:i:1
desktopwidth:i:$($pos.W)
desktopheight:i:$($pos.H)
smart sizing:i:1
redirectclipboard:i:1
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

# ===== FINAL REPOSITION (fix minimized windows) =====
Write-Log -Message "Final reposition pass..." -LogFile $logFile
Start-Sleep -Seconds 3

foreach ($entry in $launchedProcs) {
    try {
        $p = $entry.Proc
        $pos = $positions[$entry.Index]
        $p.Refresh()
        $hwnd = $p.MainWindowHandle
        if ($hwnd -ne [IntPtr]::Zero) {
            [WinAPI]::ShowWindow($hwnd, [WinAPI]::SW_RESTORE) | Out-Null
            Start-Sleep -Milliseconds 200
            [WinAPI]::MoveWindow($hwnd, $pos.X, $pos.Y, $pos.W, $pos.H, $true) | Out-Null
        }
    } catch {}
}

Write-Log -Message "==========================================" -LogFile $logFile
Write-Log -Message "Done." -LogFile $logFile
Write-Log -Message "==========================================" -LogFile $logFile
