# ============================================
# RDP Launcher - GUI Dashboard
# ============================================
# Reads server list from servers.txt (same folder)
# Usage: powershell -ExecutionPolicy Bypass -File .\rdp-gui.ps1
# ============================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptDir = $PSScriptRoot
$serverFile = Join-Path $scriptDir "servers.txt"
$delaySeconds = 2

# ===== LOAD SERVERS FROM FILE =====
function Get-Servers {
    if (-not (Test-Path $serverFile)) {
        return @()
    }
    return Get-Content $serverFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" -and $_ -notmatch "^\s*#" }
}

# ===== FORM SETUP =====
$form = New-Object System.Windows.Forms.Form
$form.Text = "RDP Launcher"
$form.Size = New-Object System.Drawing.Size(450, 420)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

# ===== TITLE =====
$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "RDP Launcher"
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$titleLabel.Size = New-Object System.Drawing.Size(300, 30)
$titleLabel.Location = New-Object System.Drawing.Point(20, 10)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$form.Controls.Add($titleLabel)

# ===== SERVER LIST DISPLAY =====
$listLabel = New-Object System.Windows.Forms.Label
$listLabel.Text = "Servers (from servers.txt):"
$listLabel.Size = New-Object System.Drawing.Size(400, 20)
$listLabel.Location = New-Object System.Drawing.Point(20, 50)
$form.Controls.Add($listLabel)

$listBox = New-Object System.Windows.Forms.ListBox
$listBox.Size = New-Object System.Drawing.Size(390, 180)
$listBox.Location = New-Object System.Drawing.Point(20, 75)
$listBox.SelectionMode = "None"
$form.Controls.Add($listBox)

# Populate list
$servers = Get-Servers
foreach ($s in $servers) { [void]$listBox.Items.Add($s) }

# ===== STATUS LABEL =====
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Size = New-Object System.Drawing.Size(390, 25)
$statusLabel.Location = New-Object System.Drawing.Point(20, 350)
$statusLabel.ForeColor = [System.Drawing.Color]::Green
$statusLabel.Text = "$($servers.Count) server(s) loaded"
$form.Controls.Add($statusLabel)

# ===== LAUNCH ALL BUTTON =====
$launchBtn = New-Object System.Windows.Forms.Button
$launchBtn.Text = "Launch All"
$launchBtn.Size = New-Object System.Drawing.Size(185, 45)
$launchBtn.Location = New-Object System.Drawing.Point(20, 270)
$launchBtn.FlatStyle = "Flat"
$launchBtn.BackColor = [System.Drawing.Color]::FromArgb(0, 150, 80)
$launchBtn.ForeColor = [System.Drawing.Color]::White
$launchBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$launchBtn.Cursor = [System.Windows.Forms.Cursors]::Hand

$launchBtn.Add_Click({
    $currentServers = Get-Servers
    if ($currentServers.Count -eq 0) {
        $statusLabel.Text = "No servers in servers.txt!"
        $statusLabel.ForeColor = [System.Drawing.Color]::Red
        return
    }
    $statusLabel.Text = "Launching $($currentServers.Count) session(s)..."
    $statusLabel.ForeColor = [System.Drawing.Color]::Orange
    $form.Refresh()
    foreach ($server in $currentServers) {
        Start-Process "mstsc.exe" -ArgumentList "/v:$server /multimon"
        Start-Sleep -Seconds $delaySeconds
    }
    $statusLabel.Text = "Done - $($currentServers.Count) session(s) launched."
    $statusLabel.ForeColor = [System.Drawing.Color]::Green
}.GetNewClosure())

$form.Controls.Add($launchBtn)

# ===== EDIT FILE BUTTON =====
$editBtn = New-Object System.Windows.Forms.Button
$editBtn.Text = "Edit servers.txt"
$editBtn.Size = New-Object System.Drawing.Size(185, 45)
$editBtn.Location = New-Object System.Drawing.Point(225, 270)
$editBtn.FlatStyle = "Flat"
$editBtn.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$editBtn.ForeColor = [System.Drawing.Color]::White
$editBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$editBtn.Cursor = [System.Windows.Forms.Cursors]::Hand

$editBtn.Add_Click({
    Start-Process "notepad.exe" -ArgumentList $serverFile
}.GetNewClosure())

$form.Controls.Add($editBtn)

# ===== REFRESH BUTTON =====
$refreshBtn = New-Object System.Windows.Forms.Button
$refreshBtn.Text = "Refresh List"
$refreshBtn.Size = New-Object System.Drawing.Size(185, 35)
$refreshBtn.Location = New-Object System.Drawing.Point(20, 325)
$refreshBtn.FlatStyle = "Flat"
$refreshBtn.Cursor = [System.Windows.Forms.Cursors]::Hand

$refreshBtn.Add_Click({
    $listBox.Items.Clear()
    $refreshed = Get-Servers
    foreach ($s in $refreshed) { [void]$listBox.Items.Add($s) }
    $statusLabel.Text = "$($refreshed.Count) server(s) loaded"
    $statusLabel.ForeColor = [System.Drawing.Color]::Green
}.GetNewClosure())

$form.Controls.Add($refreshBtn)

# ===== SHOW FORM =====
$form.TopMost = $true
$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
