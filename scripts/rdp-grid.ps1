# ============================================
# RDP Grid Launcher (with Auto-Login)
# ============================================
# Launches RDP sessions in a tiled grid.
# Uses mstsc /w /h for sizing.
# After all sessions connect, tiles them using
# Windows' built-in cascade/tile functionality.
# ============================================

#Requires -Version 5.1

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms

# Win32 API
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinAPI {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    // Tile windows via shell
    [DllImport("user32.dll")]
    public static extern void TileWindows(IntPtr hwndParent, uint wHow, IntPtr lpRect, uint cKids, IntPtr[] lpKids);

    public const int SW_SHOWNORMAL = 1;
    public const int SW_RESTORE = 9;
    public const int SW_SHOWNOACTIVATE = 4;
    public const uint SWP_SHOWWINDOW = 0x0040;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint MDITILE_VERTICAL = 0x0000;
    public const uint MDITILE_HORIZONTAL = 0x0001;

    public static void TileTheseWindows(IntPtr[] handles) {
        TileWindows(IntPtr.Zero, MDITILE_VERTICAL, IntPtr.Zero, (uint)handles.Length, handles);
    }
}
"@

# ===== LOAD SHARED CONFIG =====
$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir "lib\Config.ps1")

$projectRoot = Split-Path $scriptDir -Parent
$configDir   = Join-Path $projectRoot "config"
$serverFile  = Join-Path $configDir  "servers.txt"
$rdpFolder   = Join-Path $projectRoot "rdp_sessions"
$logDir      = Join-Path $projectRoot "logs"
$logFile     = Join-Path $logDir     "rdp-grid.log"

Initialize-Directories

# ===== LOAD UI AUTOMATION =====
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
        Write-Log -Message "UI Automation loaded" -LogFile $logFile
    }
    catch {
        if ($_.Exception.Message -match "already exists") {
            $uiAutomationLoaded = $true
        } else {
            Write-Log -Message "UI Automation load failed: $($_.Exception.Message)" -LogFile $logFile -Level "WARN"
        }
    }
}

# ===== LOAD CREDENTIALS =====
$creds = Get-ConfiguredCredentials
$username = $creds.Username
$password = $creds.Password

if (-not $username) {
    Write-Log -Message "ERROR: No username in config/user.txt" -LogFile $logFile -Level "ERROR"
    exit 1
}

# ===== KILL EXISTING MSTSC SESSIONS =====
function Stop-ExistingSessions {
    $existing = Get-Process -Name "mstsc" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log -Message "Killing $($existing.Count) existing mstsc process(es)..." -LogFile $logFile
        $existing | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
}

# ===== AUTO-LOGIN VIA UI AUTOMATION =====
function Invoke-AutoLogin {
    param(
        [int]$ProcessId,
        [string]$Server,
        [string]$Username,
        [string]$Password
    )

    if (-not $uiAutomationLoaded -or -not $Password) { return }

    # Phase 1: Dismiss security/certificate warning
    $securityTitles = @("security", "certificate", "trust", "warning", "unknown publisher")
    $secWin = [RdpUIAutomation]::WaitForWindowTitleByPid($ProcessId, $securityTitles, 8000)

    if ($null -ne $secWin) {
        $clicked = [RdpUIAutomation]::ClickButton($secWin, "Yes")
        if (-not $clicked) { $clicked = [RdpUIAutomation]::ClickButton($secWin, "Connect") }
        if (-not $clicked) { [RdpUIAutomation]::ClickFirstActionButton($secWin) | Out-Null }
        Write-Log -Message "  $Server - Security warning dismissed" -LogFile $logFile
        Start-Sleep -Milliseconds 1500
    }

    # Phase 2: Credential prompt or SendKeys
    $credWin = [RdpUIAutomation]::WaitForWindowWithEditsByPid($ProcessId, 10000)

    if ($null -ne $credWin) {
        [RdpUIAutomation]::FillCredentials($credWin, $Username, $Password) | Out-Null
        Start-Sleep -Milliseconds 500
        $clicked = [RdpUIAutomation]::ClickButton($credWin, "OK")
        if (-not $clicked) { [RdpUIAutomation]::ClickFirstActionButton($credWin) | Out-Null }
        Write-Log -Message "  $Server - Credentials filled (NLA)" -LogFile $logFile
    } else {
        $sessionTitles = @($Server, "Remote Desktop")
        $sessionWin = [RdpUIAutomation]::WaitForWindowTitleByPid($ProcessId, $sessionTitles, 5000)
        if ($null -ne $sessionWin) {
            Start-Sleep -Seconds 3

            $mstscProc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
            if ($null -ne $mstscProc) {
                $mstscProc.Refresh()
                $hwnd = $mstscProc.MainWindowHandle
                if ($hwnd -ne [IntPtr]::Zero) {
                    [WinAPI]::ShowWindow($hwnd, [WinAPI]::SW_SHOWNORMAL) | Out-Null
                    [WinAPI]::SetForegroundWindow($hwnd) | Out-Null
                } else {
                    try {
                        $wshell = New-Object -ComObject WScript.Shell
                        $wshell.AppActivate($ProcessId) | Out-Null
                    } catch {}
                }
            }

            Start-Sleep -Milliseconds 800
            [System.Windows.Forms.SendKeys]::SendWait("{TAB}")
            Start-Sleep -Milliseconds 300
            [System.Windows.Forms.SendKeys]::SendWait($Password)
            Start-Sleep -Milliseconds 300
            [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
            Write-Log -Message "  $Server - Credentials typed (SendKeys)" -LogFile $logFile
        }
    }

    # Phase 3: Second security warning
    Start-Sleep -Milliseconds 1000
    $secWin2 = [RdpUIAutomation]::WaitForWindowTitleByPid($ProcessId, $securityTitles, 3000)
    if ($null -ne $secWin2) {
        [RdpUIAutomation]::ClickButton($secWin2, "Yes") | Out-Null
        Write-Log -Message "  $Server - Second warning dismissed" -LogFile $logFile
    }
}

# ===== TILE WINDOWS =====
function Invoke-TileWindows {
    param([array]$Processes)

    Write-Log -Message "Tiling $($Processes.Count) windows..." -LogFile $logFile

    # Collect valid window handles
    $handles = @()
    foreach ($proc in $Processes) {
        if ($null -eq $proc -or $proc.HasExited) { continue }
        $proc.Refresh()
        $hwnd = $proc.MainWindowHandle
        if ($hwnd -ne [IntPtr]::Zero) {
            # Make sure window is in normal state (not minimized/maximized)
            [WinAPI]::ShowWindow($hwnd, [WinAPI]::SW_RESTORE) | Out-Null
            $handles += $hwnd
        }
    }

    if ($handles.Count -eq 0) {
        Write-Log -Message "  No window handles found to tile" -LogFile $logFile -Level "WARN"
        return
    }

    Write-Log -Message "  Found $($handles.Count) window handles" -LogFile $logFile

    # Use Windows TileWindows API to tile them
    [WinAPI]::TileTheseWindows($handles)

    Write-Log -Message "  Windows tiled" -LogFile $logFile
}

# ===== MAIN =====
try {
    Write-Log -Message "==========================================" -LogFile $logFile
    Write-Log -Message "RDP Grid Launcher" -LogFile $logFile
    Write-Log -Message "  Username: $username" -LogFile $logFile

    # Kill any existing RDP sessions first
    Stop-ExistingSessions

    # Load and validate servers
    $servers = Get-ValidatedServers -Path $serverFile -LogFile $logFile

    if ($servers.Count -eq 0) {
        Write-Log -Message "ERROR: No valid servers configured" -LogFile $logFile -Level "ERROR"
        exit 1
    }

    Write-Log -Message "  Servers: $($servers.Count)" -LogFile $logFile

    # Launch all sessions
    $processes = @()
    $launched = 0
    $failed   = 0

    for ($i = 0; $i -lt $servers.Count; $i++) {
        $server = $servers[$i]
        Write-Log -Message "--- $server ---" -LogFile $logFile

        try {
            # Store credential via cmdkey
            $cmdkeyList = & cmdkey /list 2>&1 | Out-String
            if ($cmdkeyList -notmatch [regex]::Escape("TERMSRV/$server")) {
                if ($password) {
                    & cmdkey /generic:TERMSRV/$server /user:$username /pass:$password | Out-Null
                }
            }

            # Generate simple RDP file (no position - we tile after)
            $safe = $server -replace '[^a-zA-Z0-9\.\-]', '_'
            $rdpPath = Join-Path $rdpFolder "$safe.rdp"

            $rdpContent = @"
full address:s:$server
username:s:$username
prompt for credentials:i:0
authentication level:i:2
enablecredsspsupport:i:1
use multimon:i:0
screen mode id:i:1
desktopwidth:i:1280
desktopheight:i:800
smart sizing:i:1
redirectclipboard:i:1
disable wallpaper:i:1
allow font smoothing:i:1
"@
            Set-Content -Path $rdpPath -Value $rdpContent -Encoding ASCII

            # Launch mstsc
            $proc = Start-Process "mstsc.exe" -ArgumentList "`"$rdpPath`"" -PassThru

            if ($null -ne $proc) {
                Write-Log -Message "  PID: $($proc.Id)" -LogFile $logFile

                # Auto-login
                Invoke-AutoLogin -ProcessId $proc.Id -Server $server -Username $username -Password $password

                $processes += $proc
                $launched++
            } else {
                Write-Log -Message "  FAILED: Could not start mstsc" -LogFile $logFile -Level "ERROR"
                $failed++
            }
        }
        catch {
            Write-Log -Message "  FAILED: $($_.Exception.Message)" -LogFile $logFile -Level "ERROR"
            $failed++
        }

        Start-Sleep -Seconds 2
    }

    # Wait for all sessions to fully connect
    Write-Log -Message "Waiting 15s for sessions to stabilize..." -LogFile $logFile
    Start-Sleep -Seconds 15

    # Tile all mstsc windows using Windows API
    Invoke-TileWindows -Processes $processes

    # Summary
    Write-Log -Message "==========================================" -LogFile $logFile
    Write-Log -Message "Complete: $launched launched, $failed failed" -LogFile $logFile
    Write-Log -Message "==========================================" -LogFile $logFile
}
catch {
    Write-Log -Message "FATAL: $($_.Exception.Message)" -LogFile $logFile -Level "FATAL"
    Write-Log -Message "  Stack: $($_.ScriptStackTrace)" -LogFile $logFile -Level "FATAL"
    exit 1
}
