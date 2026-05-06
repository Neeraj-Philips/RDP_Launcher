# ============================================
# RDP Grid Launcher (Fixed Grid Mode)
# ============================================
# Launches RDP sessions one-by-one
# Assigns each server to a fixed grid slot
# Restores + positions window immediately
# Then performs login automation
#
# IMPORTANT:
# - NO fullscreen
# - NO post-launch tiling
# - NO bulk window movement
# ============================================

#Requires -Version 5.1

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

# ===== WIN32 WINDOW API =====
try {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public class WinAPI {

    [DllImport("user32.dll")]
    public static extern bool MoveWindow(
        IntPtr hWnd,
        int X,
        int Y,
        int nWidth,
        int nHeight,
        bool bRepaint
    );

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(
        IntPtr hWnd,
        int nCmdShow
    );

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(
        IntPtr hWnd
    );

    public const int SW_RESTORE = 9;
}
"@
} catch {}

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
        }
        else {
            Write-Log -Message "UI Automation load failed: $($_.Exception.Message)" -LogFile $logFile -Level "WARN"
        }
    }
}

# ===== LOAD CREDENTIALS =====
$creds = Get-ConfiguredCredentials

$username = $creds.Username
$password = $creds.Password

if (-not $username) {

    Write-Log -Message "ERROR: No username configured in config/user.txt" -LogFile $logFile -Level "ERROR"

    exit 1
}

# ===== GRID POSITIONS =====
# Adjust for your monitor setup

function Get-GridPositions {

    return @(

        # Monitor 1
        @{ X = 0;    Y = 0;    W = 950; H = 500 }
        @{ X = 950;  Y = 0;    W = 950; H = 500 }

        @{ X = 0;    Y = 500;  W = 950; H = 500 }
        @{ X = 950;  Y = 500;  W = 950; H = 500 }

        @{ X = 0;    Y = 1000; W = 950; H = 500 }

        # Monitor 2
        @{ X = 1920; Y = 0;    W = 950; H = 500 }
        @{ X = 2870; Y = 0;    W = 950; H = 500 }

        @{ X = 1920; Y = 500;  W = 950; H = 500 }
        @{ X = 2870; Y = 500;  W = 950; H = 500 }

        @{ X = 1920; Y = 1000; W = 950; H = 500 }
    )
}

# ===== MOVE WINDOW =====
function Move-RdpWindow {

    param(
        $Process,
        $Position
    )

    try {

        $success = $false

        for ($i = 0; $i -lt 10; $i++) {

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

                [WinAPI]::SetForegroundWindow($hwnd) | Out-Null

                $success = $true

                break
            }
        }

        return $success
    }
    catch {
        return $false
    }
}

# ===== AUTO LOGIN =====
function Invoke-AutoLogin {

    param(
        [int]$ProcessId,
        [string]$Server,
        [string]$Username,
        [string]$Password
    )

    if (-not $uiAutomationLoaded -or -not $Password) {
        return
    }

    # Security warning
    $securityTitles = @(
        "security",
        "certificate",
        "trust",
        "warning",
        "unknown publisher",
        "Remote Desktop Connection"
    )

    $secWin = [RdpUIAutomation]::WaitForWindowTitleByPid(
        $ProcessId,
        $securityTitles,
        10000
    )

    if ($null -ne $secWin) {

        $clicked = [RdpUIAutomation]::ClickButton($secWin, "Yes")

        if (-not $clicked) {
            $clicked = [RdpUIAutomation]::ClickButton($secWin, "Connect")
        }

        if (-not $clicked) {
            [RdpUIAutomation]::ClickFirstActionButton($secWin) | Out-Null
        }

        Write-Log -Message "  Security warning dismissed" -LogFile $logFile

        Start-Sleep -Milliseconds 1500
    }

    # Wait for session
    Start-Sleep -Seconds 3

    $sessionTitles = @($Server, "Remote Desktop")

    $sessionWin = [RdpUIAutomation]::WaitForWindowTitleByPid(
        $ProcessId,
        $sessionTitles,
        10000
    )

    if ($null -ne $sessionWin) {

        Write-Log -Message "  Session connected" -LogFile $logFile

        Start-Sleep -Seconds 2

        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue

        if ($null -ne $proc) {

            $proc.Refresh()

            $hwnd = $proc.MainWindowHandle

            if ($hwnd -ne [IntPtr]::Zero) {

                [WinAPI]::SetForegroundWindow($hwnd) | Out-Null

                Start-Sleep -Milliseconds 800

                [System.Windows.Forms.SendKeys]::SendWait("{TAB}")

                Start-Sleep -Milliseconds 300

                [System.Windows.Forms.SendKeys]::SendWait($Password)

                Start-Sleep -Milliseconds 300

                [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")

                Write-Log -Message "  Credentials typed" -LogFile $logFile
            }
        }
    }
    else {

        # NLA prompt
        $credWin = [RdpUIAutomation]::WaitForWindowWithEditsByPid(
            $ProcessId,
            5000
        )

        if ($null -ne $credWin) {

            Write-Log -Message "  NLA credential prompt detected" -LogFile $logFile

            [RdpUIAutomation]::FillCredentials(
                $credWin,
                $Username,
                $Password
            ) | Out-Null

            Start-Sleep -Milliseconds 500

            $clicked = [RdpUIAutomation]::ClickButton($credWin, "OK")

            if (-not $clicked) {
                [RdpUIAutomation]::ClickFirstActionButton($credWin) | Out-Null
            }

            Write-Log -Message "  Credentials submitted" -LogFile $logFile
        }
    }
}

# ===== MAIN =====
try {

    Write-Log -Message "==========================================" -LogFile $logFile
    Write-Log -Message "RDP Grid Launcher (Fixed Grid Mode)" -LogFile $logFile
    Write-Log -Message "Username: $username" -LogFile $logFile

    # Load servers
    [array]$servers = Get-ValidatedServers -Path $serverFile -LogFile $logFile

    if ($servers.Count -eq 0) {

        Write-Log -Message "ERROR: No valid servers configured" -LogFile $logFile -Level "ERROR"

        exit 1
    }

    Write-Log -Message "Servers: $($servers.Count)" -LogFile $logFile

    # Get positions
    $positions = Get-GridPositions

    # Cleanup old RDP files
    Get-ChildItem $rdpFolder -Filter "*.rdp" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $launched = 0
    $failed   = 0

    # Launch sequentially
    for ($i = 0; $i -lt $servers.Count; $i++) {

        $server = $servers[$i]

        if ($i -ge $positions.Count) {

            Write-Log -Message "No grid slot for $server" -LogFile $logFile -Level "WARN"

            break
        }

        $pos = $positions[$i]

        Write-Log -Message "--- $server ---" -LogFile $logFile

        try {

            # Store credential
            $cmdkeyList = & cmdkey /list 2>&1 | Out-String

            if ($cmdkeyList -notmatch [regex]::Escape("TERMSRV/$server")) {

                if ($password) {

                    & cmdkey `
                        /generic:TERMSRV/$server `
                        /user:$username `
                        /pass:$password | Out-Null

                    Write-Log -Message "  Credential stored" -LogFile $logFile
                }
            }

            # Generate RDP file (WINDOWED)
            $safe = $server -replace '[^a-zA-Z0-9\.\-]', '_'

            $rdpPath = Join-Path $rdpFolder "$safe.rdp"

@"
full address:s:$server
username:s:$username
prompt for credentials:i:0
authentication level:i:2
enablecredsspsupport:i:1
screen mode id:i:1
desktopwidth:i:1280
desktopheight:i:800
smart sizing:i:1
"@ | Set-Content -Path $rdpPath -Encoding ASCII

            Write-Log -Message "  Launching mstsc..." -LogFile $logFile

            # Launch
            $proc = Start-Process `
                "mstsc.exe" `
                -ArgumentList "`"$rdpPath`"" `
                -PassThru

            if ($null -eq $proc) {

                throw "Failed to start mstsc"
            }

            Write-Log -Message "  PID: $($proc.Id)" -LogFile $logFile

            # Wait before moving
            Start-Sleep -Seconds 3

            # Restore + move immediately
            $moved = Move-RdpWindow `
                -Process $proc `
                -Position $pos

            if ($moved) {

                Write-Log -Message "  Positioned in grid slot $($i + 1)" -LogFile $logFile
            }
            else {

                Write-Log -Message "  Could not position window" -LogFile $logFile -Level "WARN"
            }

            # Login automation
            Invoke-AutoLogin `
                -ProcessId $proc.Id `
                -Server $server `
                -Username $username `
                -Password $password

            $launched++

        }
        catch {

            Write-Log -Message "  FAILED: $($_.Exception.Message)" -LogFile $logFile -Level "ERROR"

            $failed++
        }

        # Wait before next server
        Start-Sleep -Seconds 5
    }

    Write-Log -Message "==========================================" -LogFile $logFile
    Write-Log -Message "Complete: $launched launched, $failed failed" -LogFile $logFile
    Write-Log -Message "==========================================" -LogFile $logFile
}
catch {

    Write-Log -Message "FATAL: $($_.Exception.Message)" -LogFile $logFile -Level "FATAL"

    exit 1
}