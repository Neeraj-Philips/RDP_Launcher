# ============================================
# RDP Grid Launcher
# ============================================
# Launches RDP sessions in fullscreen with
# auto-login via cmdkey + UI Automation + SendKeys.
# Same login approach as rdp-gui.ps1.
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

# Win32 API for window activation
try {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinAPI {
    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int W, int H, bool repaint);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    public const int SW_RESTORE = 9;
}
"@
} catch {}

# Load UI Automation helper
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
    Write-Log -Message "ERROR: No username configured in config/user.txt" -LogFile $logFile -Level "ERROR"
    exit 1
}

# ===== MAIN =====
try {
    Write-Log -Message "==========================================" -LogFile $logFile
    Write-Log -Message "RDP Grid Launcher" -LogFile $logFile
    Write-Log -Message "  Username: $username" -LogFile $logFile

    # Load and validate servers
    [array]$servers = Get-ValidatedServers -Path $serverFile -LogFile $logFile

    if ($servers.Count -eq 0) {
        Write-Log -Message "ERROR: No valid servers in $serverFile" -LogFile $logFile -Level "ERROR"
        exit 1
    }

    Write-Log -Message "  Servers: $($servers.Count)" -LogFile $logFile

    $launched = 0
    $failed   = 0

    foreach ($server in $servers) {
        Write-Log -Message "--- $server ---" -LogFile $logFile

        try {
            # Store credential via cmdkey
            $cmdkeyList = & cmdkey /list 2>&1 | Out-String
            if ($cmdkeyList -notmatch [regex]::Escape("TERMSRV/$server")) {
                if ($password) {
                    & cmdkey /generic:TERMSRV/$server /user:$username /pass:$password | Out-Null
                    Write-Log -Message "  Credential stored for $server" -LogFile $logFile
                }
            }

            # Generate RDP file with fullscreen
            $rdpPath = New-RdpFile -Server $server -Username $username -FullScreen
            Write-Log -Message "  RDP file: $rdpPath" -LogFile $logFile

            # Launch with retry
            $proc = Start-RdpProcess -RdpFilePath $rdpPath -MaxRetries 3 -LogFile $logFile

            if ($null -ne $proc) {
                Write-Log -Message "  PID: $($proc.Id)" -LogFile $logFile

                if ($uiAutomationLoaded -and $password) {
                    # Phase 1: Dismiss security/certificate warning
                    $securityTitles = @("security", "certificate", "trust", "warning", "unknown publisher", "Remote Desktop Connection")
                    $secWin = [RdpUIAutomation]::WaitForWindowTitleByPid($proc.Id, $securityTitles, 10000)

                    if ($null -ne $secWin) {
                        Write-Log -Message "  Security dialog: '$($secWin.Current.Name)'" -LogFile $logFile
                        $clicked = [RdpUIAutomation]::ClickButton($secWin, "Yes")
                        if (-not $clicked) { $clicked = [RdpUIAutomation]::ClickButton($secWin, "Connect") }
                        if (-not $clicked) { [RdpUIAutomation]::ClickFirstActionButton($secWin) | Out-Null }
                        Write-Log -Message "  Security warning dismissed" -LogFile $logFile
                        Start-Sleep -Milliseconds 1500
                    }

                    # Phase 2: Wait for session window, then type credentials via SendKeys
                    Start-Sleep -Seconds 3
                    Write-Log -Message "  Waiting for session window..." -LogFile $logFile

                    $sessionTitles = @($server, "Remote Desktop")
                    $sessionWin = [RdpUIAutomation]::WaitForWindowTitleByPid($proc.Id, $sessionTitles, 10000)

                    if ($null -ne $sessionWin) {
                        Write-Log -Message "  Session connected: '$($sessionWin.Current.Name)'" -LogFile $logFile

                        Start-Sleep -Seconds 3

                        # Activate the RDP window
                        $focused = $false
                        $proc.Refresh()
                        $hwnd = $proc.MainWindowHandle
                        if ($hwnd -ne [IntPtr]::Zero) {
                            [WinAPI]::ShowWindow($hwnd, 9) | Out-Null
                            [WinAPI]::SetForegroundWindow($hwnd) | Out-Null
                            $focused = $true
                            Write-Log -Message "  Window focused via MainWindowHandle" -LogFile $logFile
                        }

                        if (-not $focused) {
                            try {
                                $wshell = New-Object -ComObject WScript.Shell
                                $wshell.AppActivate($proc.Id) | Out-Null
                                $focused = $true
                                Write-Log -Message "  Window focused via AppActivate" -LogFile $logFile
                            } catch {}
                        }

                        Start-Sleep -Milliseconds 800

                        # TAB to password field, type password, press Enter
                        [System.Windows.Forms.SendKeys]::SendWait("{TAB}")
                        Start-Sleep -Milliseconds 300
                        [System.Windows.Forms.SendKeys]::SendWait($password)
                        Start-Sleep -Milliseconds 300
                        [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")

                        Write-Log -Message "  Credentials typed" -LogFile $logFile
                    } else {
                        # Check for NLA credential prompt (local dialog)
                        $credWin = [RdpUIAutomation]::WaitForWindowWithEditsByPid($proc.Id, 5000)
                        if ($null -ne $credWin) {
                            Write-Log -Message "  NLA credential prompt detected" -LogFile $logFile
                            [RdpUIAutomation]::FillCredentials($credWin, $username, $password) | Out-Null
                            Start-Sleep -Milliseconds 500
                            $clicked = [RdpUIAutomation]::ClickButton($credWin, "OK")
                            if (-not $clicked) { [RdpUIAutomation]::ClickFirstActionButton($credWin) | Out-Null }
                            Write-Log -Message "  Credentials submitted" -LogFile $logFile
                        } else {
                            Write-Log -Message "  No session or credential prompt found" -LogFile $logFile -Level "WARN"
                        }
                    }

                    # Phase 3: Second security warning after auth
                    Start-Sleep -Milliseconds 1000
                    $secWin2 = [RdpUIAutomation]::WaitForWindowTitleByPid($proc.Id, $securityTitles, 3000)
                    if ($null -ne $secWin2) {
                        [RdpUIAutomation]::ClickButton($secWin2, "Yes") | Out-Null
                        Write-Log -Message "  Second security warning dismissed" -LogFile $logFile
                    }
                }

                $launched++
            } else {
                Write-Log -Message "  FAILED: Could not start mstsc for $server" -LogFile $logFile -Level "ERROR"
                $failed++
            }
        }
        catch {
            Write-Log -Message "  FAILED: $server - $($_.Exception.Message)" -LogFile $logFile -Level "ERROR"
            $failed++
        }

        Start-Sleep -Seconds 5
    }

    Write-Log -Message "==========================================" -LogFile $logFile
    Write-Log -Message "Complete: $launched launched, $failed failed" -LogFile $logFile
    Write-Log -Message "==========================================" -LogFile $logFile

    if ($failed -gt 0) { exit 1 }
}
catch {
    Write-Log -Message "FATAL: $($_.Exception.Message)" -LogFile $logFile -Level "FATAL"
    Write-Log -Message "  Stack: $($_.ScriptStackTrace)" -LogFile $logFile -Level "FATAL"
    exit 1
}
