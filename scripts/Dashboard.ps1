# ============================================
# RDP Session Dashboard
# ============================================
# Features:
# - Launch All / Launch Selected
# - Stop All / Live Status
# - Add / Remove server IPs
# - Capture Layout: manually arrange windows,
#   then capture positions for next launch
# - Log Viewer
# ============================================

#Requires -Version 5.1

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ===== WIN32 API =====
try {
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class DashWinAPI {
    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    public const int SW_RESTORE = 9;
}

[StructLayout(LayoutKind.Sequential)]
public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
}
"@
} catch {}

# ===== PATHS =====
$scriptDir   = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent
$configDir   = Join-Path $projectRoot "config"
$serverFile  = Join-Path $configDir "servers.txt"
$layoutFile  = Join-Path $configDir "layout.txt"
$logDir      = Join-Path $projectRoot "logs"
$logFile     = Join-Path $logDir "rdp-grid.log"
$dashLogFile = Join-Path $logDir "dashboard.log"
$gridScript  = Join-Path $scriptDir "rdp-grid.ps1"

# Load shared config for Write-Log
. (Join-Path $scriptDir "lib\Config.ps1")

# Ensure dirs exist
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

# ===== FORM =====
$form = New-Object System.Windows.Forms.Form
$form.Text = "RDP Session Dashboard"
$form.Size = New-Object System.Drawing.Size(920, 700)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# ===== TITLE =====
$title = New-Object System.Windows.Forms.Label
$title.Text = "RDP SESSION DASHBOARD"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::FromArgb(0, 180, 255)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(20, 15)
$form.Controls.Add($title)

# ===== SERVER LIST =====
$serverLabel = New-Object System.Windows.Forms.Label
$serverLabel.Text = "Servers"
$serverLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$serverLabel.Location = New-Object System.Drawing.Point(20, 55)
$serverLabel.AutoSize = $true
$form.Controls.Add($serverLabel)

$serverList = New-Object System.Windows.Forms.CheckedListBox
$serverList.Location = New-Object System.Drawing.Point(20, 80)
$serverList.Size = New-Object System.Drawing.Size(250, 280)
$serverList.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$serverList.ForeColor = [System.Drawing.Color]::White
$serverList.BorderStyle = "FixedSingle"
$serverList.CheckOnClick = $true
$form.Controls.Add($serverList)

# --- Add/Remove IP controls ---
$ipBox = New-Object System.Windows.Forms.TextBox
$ipBox.Location = New-Object System.Drawing.Point(20, 368)
$ipBox.Size = New-Object System.Drawing.Size(145, 25)
$ipBox.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
$ipBox.ForeColor = [System.Drawing.Color]::White
$ipBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$ipBox.Text = ""
$form.Controls.Add($ipBox)

$addBtn = New-Object System.Windows.Forms.Button
$addBtn.Text = "Add"
$addBtn.Location = New-Object System.Drawing.Point(170, 367)
$addBtn.Size = New-Object System.Drawing.Size(48, 26)
$addBtn.BackColor = [System.Drawing.Color]::FromArgb(0, 100, 60)
$addBtn.ForeColor = [System.Drawing.Color]::White
$addBtn.FlatStyle = "Flat"
$form.Controls.Add($addBtn)

$removeBtn = New-Object System.Windows.Forms.Button
$removeBtn.Text = "Del"
$removeBtn.Location = New-Object System.Drawing.Point(222, 367)
$removeBtn.Size = New-Object System.Drawing.Size(48, 26)
$removeBtn.BackColor = [System.Drawing.Color]::FromArgb(140, 30, 30)
$removeBtn.ForeColor = [System.Drawing.Color]::White
$removeBtn.FlatStyle = "Flat"
$form.Controls.Add($removeBtn)

# Hint: checked = enabled for launch
$hintLbl = New-Object System.Windows.Forms.Label
$hintLbl.Text = "Checked = enabled for launch"
$hintLbl.Location = New-Object System.Drawing.Point(20, 395)
$hintLbl.Size = New-Object System.Drawing.Size(250, 15)
$hintLbl.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
$hintLbl.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
$form.Controls.Add($hintLbl)

# ===== STATUS GRID =====
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Session Status"
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$statusLabel.Location = New-Object System.Drawing.Point(300, 55)
$statusLabel.AutoSize = $true
$form.Controls.Add($statusLabel)

$statusGrid = New-Object System.Windows.Forms.ListView
$statusGrid.Location = New-Object System.Drawing.Point(300, 80)
$statusGrid.Size = New-Object System.Drawing.Size(580, 200)
$statusGrid.View = "Details"
$statusGrid.FullRowSelect = $true
$statusGrid.GridLines = $true
$statusGrid.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$statusGrid.ForeColor = [System.Drawing.Color]::White
$statusGrid.BorderStyle = "FixedSingle"
[void]$statusGrid.Columns.Add("Server", 200)
[void]$statusGrid.Columns.Add("Status", 120)
$form.Controls.Add($statusGrid)

# ===== LOG VIEWER =====
$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = "Live Logs"
$logLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$logLabel.Location = New-Object System.Drawing.Point(300, 295)
$logLabel.AutoSize = $true
$form.Controls.Add($logLabel)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(300, 320)
$logBox.Size = New-Object System.Drawing.Size(580, 200)
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::Black
$logBox.ForeColor = [System.Drawing.Color]::LightGreen
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$logBox.BorderStyle = "FixedSingle"
$form.Controls.Add($logBox)

# ===== ACTION BUTTONS =====
$launchBtn = New-Object System.Windows.Forms.Button
$launchBtn.Text = "Launch Selected"
$launchBtn.Location = New-Object System.Drawing.Point(20, 405)
$launchBtn.Size = New-Object System.Drawing.Size(120, 35)
$launchBtn.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 80)
$launchBtn.ForeColor = [System.Drawing.Color]::White
$launchBtn.FlatStyle = "Flat"
$form.Controls.Add($launchBtn)

$launchAllBtn = New-Object System.Windows.Forms.Button
$launchAllBtn.Text = "Launch All"
$launchAllBtn.Location = New-Object System.Drawing.Point(150, 405)
$launchAllBtn.Size = New-Object System.Drawing.Size(120, 35)
$launchAllBtn.BackColor = [System.Drawing.Color]::FromArgb(0, 100, 200)
$launchAllBtn.ForeColor = [System.Drawing.Color]::White
$launchAllBtn.FlatStyle = "Flat"
$form.Controls.Add($launchAllBtn)

$stopBtn = New-Object System.Windows.Forms.Button
$stopBtn.Text = "Stop All"
$stopBtn.Location = New-Object System.Drawing.Point(20, 450)
$stopBtn.Size = New-Object System.Drawing.Size(80, 35)
$stopBtn.BackColor = [System.Drawing.Color]::FromArgb(180, 40, 40)
$stopBtn.ForeColor = [System.Drawing.Color]::White
$stopBtn.FlatStyle = "Flat"
$form.Controls.Add($stopBtn)

$stopSelBtn = New-Object System.Windows.Forms.Button
$stopSelBtn.Text = "Stop Selected"
$stopSelBtn.Location = New-Object System.Drawing.Point(105, 450)
$stopSelBtn.Size = New-Object System.Drawing.Size(165, 35)
$stopSelBtn.BackColor = [System.Drawing.Color]::FromArgb(150, 50, 20)
$stopSelBtn.ForeColor = [System.Drawing.Color]::White
$stopSelBtn.FlatStyle = "Flat"
$form.Controls.Add($stopSelBtn)

# --- Capture & Apply Layout ---
$captureBtn = New-Object System.Windows.Forms.Button
$captureBtn.Text = "Capture Layout"
$captureBtn.Location = New-Object System.Drawing.Point(20, 500)
$captureBtn.Size = New-Object System.Drawing.Size(120, 40)
$captureBtn.BackColor = [System.Drawing.Color]::FromArgb(120, 80, 0)
$captureBtn.ForeColor = [System.Drawing.Color]::White
$captureBtn.FlatStyle = "Flat"
$captureBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($captureBtn)

$applyLayoutBtn = New-Object System.Windows.Forms.Button
$applyLayoutBtn.Text = "Apply Layout"
$applyLayoutBtn.Location = New-Object System.Drawing.Point(150, 500)
$applyLayoutBtn.Size = New-Object System.Drawing.Size(120, 40)
$applyLayoutBtn.BackColor = [System.Drawing.Color]::FromArgb(80, 60, 120)
$applyLayoutBtn.ForeColor = [System.Drawing.Color]::White
$applyLayoutBtn.FlatStyle = "Flat"
$applyLayoutBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($applyLayoutBtn)

# --- Layout status ---
$layoutStatus = New-Object System.Windows.Forms.Label
$layoutStatus.Location = New-Object System.Drawing.Point(20, 548)
$layoutStatus.Size = New-Object System.Drawing.Size(250, 20)
$layoutStatus.ForeColor = [System.Drawing.Color]::Gray
$layoutStatus.Text = ""
$form.Controls.Add($layoutStatus)

# ===== STATUS BAR =====
$statusBar = New-Object System.Windows.Forms.Label
$statusBar.Location = New-Object System.Drawing.Point(20, 630)
$statusBar.Size = New-Object System.Drawing.Size(860, 25)
$statusBar.Text = "Ready"
$statusBar.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($statusBar)

# ===== HELPER FUNCTIONS =====

function Write-DashLog {
    param([string]$Message, [string]$Level = "INFO")
    Write-Log -Message $Message -LogFile $dashLogFile -Level $Level
}

function Load-Servers {
    $script:skipSaveOnCheck = $true
    $serverList.Items.Clear()
    if (Test-Path $serverFile) {
        Get-Content $serverFile | ForEach-Object {
            $line = $_.Trim()
            if (-not $line -or $line -match "^#\s*(#|RDP|This|Add)") {
                # Skip empty lines and header comments
                return
            }
            if ($line.StartsWith("#")) {
                # Commented server - show unchecked
                $server = $line.TrimStart("#").Trim()
                if ($server) {
                    [void]$serverList.Items.Add($server, $false)
                }
            } else {
                # Active server - show checked
                [void]$serverList.Items.Add($line, $true)
            }
        }
    }
    $script:skipSaveOnCheck = $false
    $statusBar.Text = "$($serverList.Items.Count) server(s) loaded"
    Write-DashLog "Loaded $($serverList.Items.Count) server(s) from config"

    # Show saved layout status
    if (Test-Path $layoutFile) {
        $layoutStatus.Text = "Saved layout found"
        $layoutStatus.ForeColor = [System.Drawing.Color]::FromArgb(100, 180, 100)
    } else {
        $layoutStatus.Text = "No saved layout"
        $layoutStatus.ForeColor = [System.Drawing.Color]::Gray
    }
}

function Save-ServerList {
    # Write server list back to file
    # Checked = active, Unchecked = commented out
    $header = "# RDP Server List"
    $lines = @($header)
    for ($i = 0; $i -lt $serverList.Items.Count; $i++) {
        $server = $serverList.Items[$i].ToString()
        $isChecked = $serverList.GetItemChecked($i)
        if ($isChecked) {
            $lines += $server
        } else {
            $lines += "# $server"
        }
    }
    Set-Content -Path $serverFile -Value ($lines -join "`n") -Encoding ASCII
    Write-DashLog "Server list saved: $($serverList.Items.Count) entries"
}

function Get-ConnectedSessions {
    $sessions = @()
    $mstscProcs = Get-Process -Name "mstsc" -ErrorAction SilentlyContinue

    $configuredServers = @()
    if (Test-Path $serverFile) {
        $configuredServers = @(Get-Content $serverFile |
            Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith("#") } |
            ForEach-Object { $_.Trim() })
    }

    if ($mstscProcs) {
        foreach ($proc in $mstscProcs) {
            try {
                $proc.Refresh()
                $titleText = $proc.MainWindowTitle
                $hwnd = $proc.MainWindowHandle

                foreach ($server in $configuredServers) {
                    if ($titleText -match [regex]::Escape($server)) {
                        $sessions += @{
                            Server = $server
                            PID    = $proc.Id
                            Handle = $hwnd
                            Title  = $titleText
                        }
                        break
                    }
                }
            } catch {}
        }
    }

    return $sessions
}

function Refresh-Status {
    $statusGrid.Items.Clear()

    $configuredServers = @()
    if (Test-Path $serverFile) {
        $configuredServers = @(Get-Content $serverFile |
            Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith("#") } |
            ForEach-Object { $_.Trim() })
    }

    $mstscProcs = Get-Process -Name "mstsc" -ErrorAction SilentlyContinue

    foreach ($server in $configuredServers) {
        $item = New-Object System.Windows.Forms.ListViewItem($server)

        $found = $false
        if ($mstscProcs) {
            foreach ($proc in $mstscProcs) {
                try {
                    if ($proc.MainWindowTitle -match [regex]::Escape($server)) {
                        [void]$item.SubItems.Add("Connected")
                        $item.ForeColor = [System.Drawing.Color]::LightGreen
                        $found = $true
                        break
                    }
                } catch {}
            }
        }

        if (-not $found) {
            [void]$item.SubItems.Add("Disconnected")
            $item.ForeColor = [System.Drawing.Color]::Gray
        }

        [void]$statusGrid.Items.Add($item)
    }

    if (Test-Path $logFile) {
        try {
            $content = Get-Content $logFile -Tail 30 -ErrorAction Stop
            $logBox.Text = ($content -join "`r`n")
            $logBox.SelectionStart = $logBox.Text.Length
            $logBox.ScrollToCaret()
        } catch {}
    }

    $connected = ($statusGrid.Items | Where-Object { $_.SubItems[1].Text -eq "Connected" }).Count
    $total = $statusGrid.Items.Count
    $statusBar.Text = "Sessions: $connected / $total connected | Last refresh: $(Get-Date -Format 'HH:mm:ss')"
}

function Launch-GridScript {
    param([string[]]$Servers)

    if ($Servers.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "No servers selected.", "RDP Dashboard",
            "OK", "Warning"
        )
        return
    }

    $statusBar.Text = "Launching $($Servers.Count) session(s)..."
    $statusBar.ForeColor = [System.Drawing.Color]::Yellow
    $form.Refresh()
    Write-DashLog "Launching $($Servers.Count) session(s): $($Servers -join ', ')"

    # Write selected servers to a temp file and pass it to the grid script
    $tempServerFile = Join-Path $logDir "launch-servers.txt"
    $Servers | Set-Content -Path $tempServerFile -Encoding ASCII

    Start-Process "powershell.exe" -ArgumentList @(
        "-ExecutionPolicy", "Bypass",
        "-NoProfile",
        "-File", "`"$gridScript`"",
        "-ServerListFile", "`"$tempServerFile`""
    ) -WindowStyle Hidden

    Start-Sleep -Seconds 3
    $statusBar.Text = "Launch initiated for $($Servers.Count) server(s)"
    $statusBar.ForeColor = [System.Drawing.Color]::LightGreen
    Write-DashLog "Launch initiated for $($Servers.Count) server(s)"

    Refresh-Status
}

# ===== CAPTURE & APPLY LAYOUT =====

function Capture-CurrentLayout {
    <#
    .SYNOPSIS
    Reads the current position and size of each connected RDP window
    and saves it to config/layout.txt. Next time you launch, the grid
    script can use these saved positions.

    Format: server|X|Y|Width|Height (one per line)
    #>
    $sessions = Get-ConnectedSessions
    if ($sessions.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "No connected RDP sessions to capture.`nLaunch sessions first, arrange them manually, then capture.",
            "Capture Layout", "OK", "Information"
        )
        return
    }

    $lines = @("# Saved window layout - captured $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines += "# Format: server|X|Y|Width|Height"
    $captured = 0

    foreach ($sess in $sessions) {
        $hwnd = $sess.Handle
        if ($hwnd -ne [IntPtr]::Zero) {
            $rect = New-Object RECT
            $ok = [DashWinAPI]::GetWindowRect($hwnd, [ref]$rect)
            if ($ok) {
                $x = $rect.Left
                $y = $rect.Top
                $w = $rect.Right - $rect.Left
                $h = $rect.Bottom - $rect.Top
                $lines += "$($sess.Server)|$x|$y|$w|$h"
                $captured++
                Write-DashLog "  Captured $($sess.Server): ($x,$y) ${w}x${h}"
            }
        }
    }

    if ($captured -gt 0) {
        Set-Content -Path $layoutFile -Value ($lines -join "`n") -Encoding ASCII
        $layoutStatus.Text = "Layout saved ($captured windows)"
        $layoutStatus.ForeColor = [System.Drawing.Color]::LightGreen
        Write-DashLog "Layout captured: $captured windows saved to $layoutFile"
        [System.Windows.Forms.MessageBox]::Show(
            "Captured $captured window position(s).`nThis layout will be used on next Apply Layout.",
            "Layout Saved", "OK", "Information"
        )
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not read any window positions.`nMake sure RDP windows are visible.",
            "Capture Failed", "OK", "Warning"
        )
    }
}

function Apply-SavedLayout {
    <#
    .SYNOPSIS
    Reads saved positions from config/layout.txt and moves each
    connected RDP window to its saved position.
    #>
    if (-not (Test-Path $layoutFile)) {
        [System.Windows.Forms.MessageBox]::Show(
            "No saved layout found.`n`nHow to use:`n1. Launch your RDP sessions`n2. Manually drag/resize each window where you want it`n3. Click 'Capture Layout' to save positions`n4. Next time, click 'Apply Layout' to restore",
            "No Layout", "OK", "Information"
        )
        return
    }

    # Parse layout file
    $layoutEntries = @{}
    Get-Content $layoutFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#")) {
            $parts = $line -split '\|'
            if ($parts.Count -eq 5) {
                $layoutEntries[$parts[0]] = @{
                    X = [int]$parts[1]
                    Y = [int]$parts[2]
                    W = [int]$parts[3]
                    H = [int]$parts[4]
                }
            }
        }
    }

    if ($layoutEntries.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Layout file is empty or invalid.",
            "Apply Layout", "OK", "Warning"
        )
        return
    }

    Write-DashLog "Applying saved layout ($($layoutEntries.Count) entries)"

    $sessions = Get-ConnectedSessions
    $moved = 0
    $notFound = 0

    foreach ($sess in $sessions) {
        if ($layoutEntries.ContainsKey($sess.Server)) {
            $pos = $layoutEntries[$sess.Server]
            $hwnd = $sess.Handle

            if ($hwnd -ne [IntPtr]::Zero) {
                [DashWinAPI]::ShowWindow($hwnd, [DashWinAPI]::SW_RESTORE) | Out-Null
                Start-Sleep -Milliseconds 100
                $ok = [DashWinAPI]::MoveWindow($hwnd, $pos.X, $pos.Y, $pos.W, $pos.H, $true)
                if ($ok) {
                    $moved++
                    Write-DashLog "  Applied $($sess.Server) -> ($($pos.X),$($pos.Y)) $($pos.W)x$($pos.H)"
                }
            }
        } else {
            $notFound++
            Write-DashLog "  No saved position for $($sess.Server)" -Level "WARN"
        }
    }

    $statusBar.Text = "Layout applied: $moved moved"
    $statusBar.ForeColor = [System.Drawing.Color]::LightGreen
    Write-DashLog "Layout applied: $moved moved, $notFound not in layout"

    if ($notFound -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Moved $moved window(s).`n$notFound window(s) had no saved position (new servers?).`nCapture again to include them.",
            "Layout Applied", "OK", "Information"
        )
    }

    Refresh-Status
}

# ===== BUTTON EVENTS =====

# Auto-save when check state changes (checked = enabled, unchecked = commented)
$script:skipSaveOnCheck = $false
$serverList.Add_ItemCheck({
    if (-not $script:skipSaveOnCheck) {
        # Delay save slightly so the new check state is applied
        $form.BeginInvoke([Action]{
            Save-ServerList
        })
    }
})

# Add IP
$addBtn.Add_Click({
    $ip = $ipBox.Text.Trim()
    if (-not $ip) {
        $statusBar.Text = "Enter an IP address or hostname to add"
        $statusBar.ForeColor = [System.Drawing.Color]::Orange
        return
    }

    # Check if already exists
    $exists = $false
    for ($i = 0; $i -lt $serverList.Items.Count; $i++) {
        if ($serverList.Items[$i].ToString() -eq $ip) {
            $exists = $true
            break
        }
    }

    if ($exists) {
        $statusBar.Text = "$ip already in list"
        $statusBar.ForeColor = [System.Drawing.Color]::Orange
        return
    }

    [void]$serverList.Items.Add($ip, $true)
    Save-ServerList
    $ipBox.Text = ""
    $statusBar.Text = "Added: $ip"
    $statusBar.ForeColor = [System.Drawing.Color]::LightGreen
    Write-DashLog "Added server: $ip"
})

# Remove selected IP
$removeBtn.Add_Click({
    $selectedIdx = $serverList.SelectedIndex
    if ($selectedIdx -lt 0) {
        $statusBar.Text = "Select a server from the list to remove"
        $statusBar.ForeColor = [System.Drawing.Color]::Orange
        return
    }

    $server = $serverList.Items[$selectedIdx].ToString()
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Remove '$server' from the server list?",
        "Confirm Remove", "YesNo", "Question"
    )

    if ($result -eq "Yes") {
        $serverList.Items.RemoveAt($selectedIdx)
        Save-ServerList
        $statusBar.Text = "Removed: $server"
        $statusBar.ForeColor = [System.Drawing.Color]::LightGreen
        Write-DashLog "Removed server: $server"
    }
})

# Launch Selected
$launchBtn.Add_Click({
    $selected = @()
    foreach ($item in $serverList.CheckedItems) {
        $selected += $item.ToString()
    }
    Launch-GridScript -Servers $selected
})

# Launch All
$launchAllBtn.Add_Click({
    $all = @()
    for ($i = 0; $i -lt $serverList.Items.Count; $i++) {
        $all += $serverList.Items[$i].ToString()
    }
    Launch-GridScript -Servers $all
})

# Stop All
$stopBtn.Add_Click({
    $mstsc = Get-Process -Name "mstsc" -ErrorAction SilentlyContinue
    if ($mstsc) {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "Close all $($mstsc.Count) RDP session(s)?",
            "Confirm Stop", "YesNo", "Question"
        )
        if ($result -eq "Yes") {
            $mstsc | Stop-Process -Force -ErrorAction SilentlyContinue
            $statusBar.Text = "All sessions stopped"
            $statusBar.ForeColor = [System.Drawing.Color]::OrangeRed
            Write-DashLog "All sessions stopped by user"
            Start-Sleep -Seconds 1
            Refresh-Status
        }
    } else {
        $statusBar.Text = "No active sessions to stop"
    }
})

# Stop Selected
$stopSelBtn.Add_Click({
    # Get checked servers from the server list
    $selected = @()
    foreach ($item in $serverList.CheckedItems) {
        $selected += $item.ToString()
    }

    if ($selected.Count -eq 0) {
        $statusBar.Text = "Check the servers you want to stop"
        $statusBar.ForeColor = [System.Drawing.Color]::Orange
        return
    }

    $result = [System.Windows.Forms.MessageBox]::Show(
        "Stop $($selected.Count) selected session(s)?`n$($selected -join ', ')",
        "Confirm Stop Selected", "YesNo", "Question"
    )

    if ($result -eq "Yes") {
        $stopped = 0
        $mstscProcs = Get-Process -Name "mstsc" -ErrorAction SilentlyContinue
        if ($mstscProcs) {
            foreach ($proc in $mstscProcs) {
                try {
                    $procTitle = $proc.MainWindowTitle
                    foreach ($srv in $selected) {
                        if ($procTitle -match [regex]::Escape($srv)) {
                            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                            $stopped++
                            Write-DashLog "Stopped session: $srv (PID $($proc.Id))"
                            break
                        }
                    }
                } catch {}
            }
        }
        $statusBar.Text = "Stopped $stopped session(s)"
        $statusBar.ForeColor = [System.Drawing.Color]::OrangeRed
        Start-Sleep -Seconds 1
        Refresh-Status
    }
})

# Capture Layout
$captureBtn.Add_Click({
    Capture-CurrentLayout
})

# Apply Layout
$applyLayoutBtn.Add_Click({
    Apply-SavedLayout
})

# ===== AUTO-REFRESH TIMER =====
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Refresh-Status })
$timer.Start()

# ===== INITIAL LOAD =====
Write-DashLog "=========================================="
Write-DashLog "Dashboard started"
Load-Servers
Refresh-Status

# ===== SHOW =====
$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()

# Cleanup
$timer.Stop()
$timer.Dispose()
Write-DashLog "Dashboard closed"
