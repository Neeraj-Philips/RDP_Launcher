# ============================================
# RDP Launcher - Secure GUI Version
# ============================================
# - Uses Windows Credential Manager (cmdkey)
# - No plaintext credential files
# - Reads default username from config/user.txt
# - Input validation on all server entries
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
$logFile     = Join-Path $logDir     "rdp-gui.log"

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
} catch {
    # Type may already be loaded
}

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
        Write-Log -Message "UI Automation loaded from $uiAutomationPath" -LogFile $logFile
    }
    catch {
        if ($_.Exception.Message -notmatch "already exists") {
            Write-Log -Message "UI Automation load failed: $($_.Exception.Message)" -LogFile $logFile -Level "WARN"
        } else {
            $uiAutomationLoaded = $true
        }
    }
}

# ===== HELPERS =====

function Get-Servers {
    return Get-ValidatedServers -Path $serverFile -LogFile $logFile
}

function Ensure-Credential {
    param([string]$Server, [string]$Username, [string]$Password)

    $cmdkeyOutput = & cmdkey /list 2>&1 | Out-String
    if ($cmdkeyOutput -notmatch [regex]::Escape("TERMSRV/$Server")) {
        Write-Log -Message "Storing credential for $Server" -LogFile $logFile

        if ($Password) {
            & cmdkey /generic:TERMSRV/$Server /user:$Username /pass:$Password | Out-Null
        } else {
            # No password in config, prompt user
            $cred = Get-Credential -UserName $Username -Message "Enter credentials for $Server"
            if ($null -eq $cred) {
                Write-Log -Message "Credential prompt cancelled for $Server" -LogFile $logFile -Level "WARN"
                return $false
            }
            & cmdkey /generic:TERMSRV/$Server /user:$($cred.UserName) /pass:$($cred.GetNetworkCredential().Password) | Out-Null
        }

        if ($LASTEXITCODE -ne 0) {
            Write-Log -Message "cmdkey failed for $Server (exit code: $LASTEXITCODE)" -LogFile $logFile -Level "ERROR"
            return $false
        }
    }
    return $true
}

function Launch-RDP {
    param([string]$Server, [string]$Username, [string]$Password)

    Write-Log -Message "Launching $Server as $Username" -LogFile $logFile

    $credOk = Ensure-Credential -Server $Server -Username $Username -Password $Password
    if (-not $credOk) {
        throw "Credential setup failed for $Server"
    }

    $rdpPath = New-RdpFile -Server $Server -Username $Username -Width 1920 -Height 1080 -MultiMonitor

    $proc = Start-RdpProcess -RdpFilePath $rdpPath -MaxRetries 2 -LogFile $logFile
    if ($null -eq $proc) {
        throw "Failed to launch mstsc for $Server"
    }

    Write-Log -Message "  PID: $($proc.Id)" -LogFile $logFile

    # Auto-dismiss security warning via UI Automation
    if ($uiAutomationLoaded) {
        Write-Log -Message "  Using UI Automation for $Server..." -LogFile $logFile

        # Phase 1: Dismiss security/certificate warning
        $securityTitles = @("security", "certificate", "trust", "warning", "unknown publisher")
        $secWin = [RdpUIAutomation]::WaitForWindowTitleByPid($proc.Id, $securityTitles, 10000)

        if ($null -ne $secWin) {
            $winTitle = $secWin.Current.Name
            Write-Log -Message "  Security dialog: '$winTitle'" -LogFile $logFile

            $clicked = [RdpUIAutomation]::ClickButton($secWin, "Yes")
            if (-not $clicked) { $clicked = [RdpUIAutomation]::ClickButton($secWin, "Connect") }
            if (-not $clicked) { $clicked = [RdpUIAutomation]::ClickFirstActionButton($secWin) }

            if ($clicked) {
                Write-Log -Message "  Security warning dismissed" -LogFile $logFile
            } else {
                Write-Log -Message "  Could not dismiss security warning" -LogFile $logFile -Level "WARN"
            }
            Start-Sleep -Milliseconds 1500
        }

        # Phase 2: Wait for session to connect, then type credentials into remote login screen
        Start-Sleep -Seconds 3
        Write-Log -Message "  Waiting for session window..." -LogFile $logFile

        # Find the connected RDP session window
        $sessionTitles = @($Server, "Remote Desktop")
        $sessionWin = [RdpUIAutomation]::WaitForWindowTitleByPid($proc.Id, $sessionTitles, 10000)

        if ($null -ne $sessionWin) {
            Write-Log -Message "  Session connected: '$($sessionWin.Current.Name)'" -LogFile $logFile

            # The remote desktop shows a Windows login screen
            # We need to type credentials via SendKeys into the active RDP window
            if ($Password) {
                Write-Log -Message "  Typing credentials into remote login screen..." -LogFile $logFile

                Start-Sleep -Seconds 3

                # Activate the RDP window using multiple methods
                $focused = $false

                # Method 1: Use process MainWindowHandle
                $proc.Refresh()
                $hwnd = $proc.MainWindowHandle
                if ($hwnd -ne [IntPtr]::Zero) {
                    [WinAPI]::ShowWindow($hwnd, 9) | Out-Null
                    [WinAPI]::SetForegroundWindow($hwnd) | Out-Null
                    $focused = $true
                    Write-Log -Message "  Window focused via MainWindowHandle" -LogFile $logFile
                }

                # Method 2: Fallback to AppActivate
                if (-not $focused) {
                    try {
                        $wshell = New-Object -ComObject WScript.Shell
                        $wshell.AppActivate($proc.Id) | Out-Null
                        $focused = $true
                        Write-Log -Message "  Window focused via AppActivate" -LogFile $logFile
                    } catch {
                        Write-Log -Message "  AppActivate failed: $($_.Exception.Message)" -LogFile $logFile -Level "WARN"
                    }
                }

                Start-Sleep -Milliseconds 800

                # TAB to password field (username is pre-filled, focus is on username)
                [System.Windows.Forms.SendKeys]::SendWait("{TAB}")
                Start-Sleep -Milliseconds 300

                # Type the password and press Enter
                [System.Windows.Forms.SendKeys]::SendWait($Password)
                Start-Sleep -Milliseconds 300
                [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")

                Write-Log -Message "  Credentials typed" -LogFile $logFile

                # Wait for remote desktop to load, then launch grid script
                Write-Log -Message "  Waiting for remote desktop to load..." -LogFile $logFile
                Start-Sleep -Seconds 10

                # Re-focus the RDP window
                $proc.Refresh()
                $hwnd = $proc.MainWindowHandle
                if ($hwnd -ne [IntPtr]::Zero) {
                    [WinAPI]::SetForegroundWindow($hwnd) | Out-Null
                } else {
                    try {
                        $wshell = New-Object -ComObject WScript.Shell
                        $wshell.AppActivate($proc.Id) | Out-Null
                    } catch {}
                }
                Start-Sleep -Milliseconds 800

                # Open Run dialog with Win+R inside the RDP session
                # Re-focus RDP window
                $proc.Refresh()
                $hwnd = $proc.MainWindowHandle
                if ($hwnd -ne [IntPtr]::Zero) {
                    [WinAPI]::SetForegroundWindow($hwnd) | Out-Null
                }
                Start-Sleep -Milliseconds 500

                # Use keybd_event for Win+R (SendKeys can't send Windows key reliably)
                try {
                    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class KeySender {
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    public const byte VK_LWIN = 0x5B;
    public const byte VK_R = 0x52;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public static void WinR() {
        keybd_event(VK_LWIN, 0, 0, UIntPtr.Zero);
        keybd_event(VK_R, 0, 0, UIntPtr.Zero);
        keybd_event(VK_R, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        keybd_event(VK_LWIN, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
}
"@
                } catch {}

                [KeySender]::WinR()
                Start-Sleep -Seconds 2

                # Type the command to launch grid script (hidden - no PowerShell window)
                $runCmd = "powershell -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File C:\RDP_Launcher\scripts\rdp-grid.ps1"
                [System.Windows.Forms.SendKeys]::SendWait($runCmd)
                Start-Sleep -Milliseconds 500
                [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")

                Write-Log -Message "  Grid script launched on jump server" -LogFile $logFile
            }
        } else {
            # Check if there's a local credential prompt (NLA)
            $credWin = [RdpUIAutomation]::WaitForWindowWithEditsByPid($proc.Id, 5000)
            if ($null -ne $credWin -and $Password) {
                Write-Log -Message "  NLA credential prompt detected, filling..." -LogFile $logFile
                [RdpUIAutomation]::FillCredentials($credWin, $Username, $Password) | Out-Null
                Start-Sleep -Milliseconds 500
                $clicked = [RdpUIAutomation]::ClickButton($credWin, "OK")
                if (-not $clicked) { [RdpUIAutomation]::ClickFirstActionButton($credWin) | Out-Null }
                Write-Log -Message "  Credentials submitted" -LogFile $logFile
            } else {
                Write-Log -Message "  No session or credential prompt found" -LogFile $logFile -Level "WARN"
            }
        }

        # Phase 3: Second security warning (some servers show one after auth)
        Start-Sleep -Milliseconds 1000
        $secWin2 = [RdpUIAutomation]::WaitForWindowTitleByPid($proc.Id, $securityTitles, 3000)
        if ($null -ne $secWin2) {
            [RdpUIAutomation]::ClickButton($secWin2, "Yes") | Out-Null
            Write-Log -Message "  Second security warning dismissed" -LogFile $logFile
        }
    }

    return $proc
}

# ===== GUI =====

$form = New-Object Windows.Forms.Form
$form.Text = "RDP Launcher"
$form.Size = New-Object Drawing.Size(440, 460)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = New-Object Drawing.Font("Segoe UI", 10)

# Title
$title = New-Object Windows.Forms.Label
$title.Text = "RDP Launcher"
$title.Font = New-Object Drawing.Font("Segoe UI", 14, [Drawing.FontStyle]::Bold)
$title.Location = "20,10"
$title.Size = "300,30"
$form.Controls.Add($title)

# Server list
$listLabel = New-Object Windows.Forms.Label
$listLabel.Text = "Servers (from config/servers.txt):"
$listLabel.Location = "20,50"
$listLabel.Size = "380,20"
$form.Controls.Add($listLabel)

$list = New-Object Windows.Forms.ListBox
$list.Location = "20,72"
$list.Size = "380,140"
$form.Controls.Add($list)

function Refresh-List {
    $list.Items.Clear()
    $servers = Get-Servers
    foreach ($s in $servers) { $list.Items.Add($s) }
    $listLabel.Text = "Servers ($($servers.Count) from config/servers.txt):"
}

Refresh-List

# Username input
$userLabel = New-Object Windows.Forms.Label
$userLabel.Text = "Username (domain\user):"
$userLabel.Location = "20,220"
$userLabel.Size = "380,20"
$form.Controls.Add($userLabel)

$userBox = New-Object Windows.Forms.TextBox
$userBox.Location = "20,242"
$userBox.Size = "380,28"
$form.Controls.Add($userBox)

# Pre-fill username from config
$creds = Get-ConfiguredCredentials
if ($creds.Username) {
    $userBox.Text = $creds.Username
}

# Launch button
$launchBtn = New-Object Windows.Forms.Button
$launchBtn.Text = "Launch All (Credential Manager)"
$launchBtn.Location = "20,282"
$launchBtn.Size = "380,42"
$launchBtn.BackColor = [Drawing.Color]::FromArgb(0, 120, 212)
$launchBtn.ForeColor = [Drawing.Color]::White
$launchBtn.FlatStyle = "Flat"
$form.Controls.Add($launchBtn)

# Utility buttons
$editBtn = New-Object Windows.Forms.Button
$editBtn.Text = "Edit servers.txt"
$editBtn.Location = "20,334"
$editBtn.Size = "185,30"
$editBtn.Add_Click({ Start-Process "notepad.exe" $serverFile })
$form.Controls.Add($editBtn)

$refreshBtn = New-Object Windows.Forms.Button
$refreshBtn.Text = "Refresh"
$refreshBtn.Location = "215,334"
$refreshBtn.Size = "185,30"
$refreshBtn.Add_Click({ Refresh-List })
$form.Controls.Add($refreshBtn)

# Status
$status = New-Object Windows.Forms.Label
$status.Location = "20,374"
$status.Size = "380,40"
$status.Text = "Ready"
$form.Controls.Add($status)

# Launch logic
$launchBtn.Add_Click({
    $username = $userBox.Text.Trim()
    $servers = Get-Servers
    $password = (Get-ConfiguredCredentials).Password

    if (-not $username) {
        $status.Text = "Enter username (e.g. domain\user)"
        $status.ForeColor = [Drawing.Color]::Red
        return
    }

    if ($servers.Count -eq 0) {
        $status.Text = "No valid servers configured"
        $status.ForeColor = [Drawing.Color]::Red
        return
    }

    $launchBtn.Enabled = $false
    $status.Text = "Launching $($servers.Count) session(s)..."
    $status.ForeColor = [Drawing.Color]::Black
    $form.Refresh()

    Write-Log -Message "==========================================" -LogFile $logFile
    Write-Log -Message "GUI launch: $($servers.Count) server(s) as $username" -LogFile $logFile

    $success = 0
    $fail = 0

    foreach ($srv in $servers) {
        try {
            $status.Text = "Connecting to $srv..."
            $form.Refresh()

            Launch-RDP -Server $srv -Username $username -Password $password
            $success++
            Start-Sleep -Seconds 2
        }
        catch {
            Write-Log -Message "FAILED: $srv - $($_.Exception.Message)" -LogFile $logFile -Level "ERROR"
            $fail++
        }
    }

    $launchBtn.Enabled = $true

    if ($fail -eq 0) {
        $status.Text = "$success session(s) launched - closing..."
        $status.ForeColor = [Drawing.Color]::FromArgb(0, 120, 0)
        $form.Refresh()
        Start-Sleep -Seconds 1
        $form.Close()
    } else {
        $status.Text = "$success launched, $fail failed. Check logs."
        $status.ForeColor = [Drawing.Color]::OrangeRed
    }

    Write-Log -Message "GUI launch complete: $success ok, $fail failed" -LogFile $logFile
    Write-Log -Message "==========================================" -LogFile $logFile
})

$form.TopMost = $true
$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
