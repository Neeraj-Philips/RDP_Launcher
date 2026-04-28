# ============================================
# RDP Launcher - GUI Dashboard (Auto-Login)
# ============================================
# Reads servers from servers.txt
# Reads credentials from credentials.txt
# Uses .rdp files for username + SendKeys for password
# Usage: powershell -ExecutionPolicy Bypass -File .\rdp-gui.ps1
# ============================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptDir = $PSScriptRoot
$serverFile = Join-Path $scriptDir "servers.txt"
$credFile   = Join-Path $scriptDir "credentials.txt"
$rdpFolder  = Join-Path $scriptDir "rdp_sessions"
$delaySeconds = 3

if (-not (Test-Path $rdpFolder)) { New-Item -ItemType Directory -Path $rdpFolder | Out-Null }

# ===== LOAD SERVERS =====
function Get-Servers {
    if (-not (Test-Path $serverFile)) { return @() }
    return Get-Content $serverFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" -and $_ -notmatch "^\s*#" }
}

# ===== LOAD CREDENTIALS =====
function Get-RdpCredentials {
    $creds = @{ Username = ""; Password = "" }
    if (-not (Test-Path $credFile)) { return $creds }
    Get-Content $credFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -match "^Username\s*=\s*(.+)$") { $creds.Username = $Matches[1].Trim() }
        if ($line -match "^Password\s*=\s*(.+)$") { $creds.Password = $Matches[1].Trim() }
    }
    return $creds
}

# ===== GENERATE .RDP FILE (username only) =====
function New-RdpFile {
    param([string]$Server, [string]$Username)
    $safeName = $Server -replace '[^a-zA-Z0-9\.\-]', '_'
    $rdpPath = Join-Path $rdpFolder "$safeName.rdp"
    $rdpContent = @"
full address:s:${Server}
username:s:${Username}
enablecredsspsupport:i:1
authentication level:i:2
prompt for credentials on client:i:0
use multimon:i:1
"@
    Set-Content -Path $rdpPath -Value $rdpContent -Encoding ASCII
    return $rdpPath
}

# ===== ESCAPE SPECIAL CHARS FOR SENDKEYS =====
function Get-SendKeysEscaped {
    param([string]$Text)
    # SendKeys treats these as special: + ^ % ~ { } [ ] ( ) !
    $escaped = $Text
    $escaped = $escaped.Replace('{', '{{}')
    $escaped = $escaped.Replace('}', '{}}')
    $escaped = $escaped.Replace('+', '{+}')
    $escaped = $escaped.Replace('^', '{^}')
    $escaped = $escaped.Replace('%', '{%}')
    $escaped = $escaped.Replace('~', '{~}')
    $escaped = $escaped.Replace('!', '{!}')
    $escaped = $escaped.Replace('(', '{(}')
    $escaped = $escaped.Replace(')', '{)}')
    $escaped = $escaped.Replace('[', '{[}')
    $escaped = $escaped.Replace(']', '{]}')
    return $escaped
}

# ===== LAUNCH ONE SERVER WITH AUTO-TYPE =====
function Launch-SingleRdp {
    param([string]$Server, [string]$Username, [string]$Password)

    $rdpPath = New-RdpFile -Server $Server -Username $Username
    Start-Process "mstsc.exe" -ArgumentList "`"$rdpPath`""

    $wshell = New-Object -ComObject WScript.Shell

    # Wait for the trust/certificate warning dialog
    Start-Sleep -Milliseconds 2500

    # Activate the RDP warning window and click Connect
    $wshell.AppActivate("Remote Desktop Connection") | Out-Null
    Start-Sleep -Milliseconds 300
    $wshell.SendKeys("{ENTER}")

    # Wait for the credential/password prompt
    Start-Sleep -Milliseconds 3000

    # Activate the Windows Security credential window
    $activated = $wshell.AppActivate("Windows Security")
    if (-not $activated) {
        # Try alternate title
        $wshell.AppActivate("Remote Desktop Connection") | Out-Null
    }
    Start-Sleep -Milliseconds 300

    # Clear the username field completely, type correct username
    $wshell.SendKeys("^a")
    Start-Sleep -Milliseconds 100
    $wshell.SendKeys($Username)
    Start-Sleep -Milliseconds 200

    # Tab to password field
    $wshell.SendKeys("{TAB}")
    Start-Sleep -Milliseconds 200

    # Type the password and press Enter
    $escapedPass = Get-SendKeysEscaped -Text $Password
    $wshell.SendKeys($escapedPass)
    Start-Sleep -Milliseconds 300
    $wshell.SendKeys("{ENTER}")
}

# ===== FORM SETUP =====
$form = New-Object System.Windows.Forms.Form
$form.Text = "RDP Launcher"
$form.Size = New-Object System.Drawing.Size(450, 470)
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

# ===== CREDENTIAL STATUS =====
$creds = Get-RdpCredentials
$credHasValues = ($creds.Username -ne "" -and $creds.Username -ne "DOMAIN\your.username")
$credLabel = New-Object System.Windows.Forms.Label
$credLabel.Size = New-Object System.Drawing.Size(390, 20)
$credLabel.Location = New-Object System.Drawing.Point(20, 45)
if ($credHasValues) {
    $credLabel.Text = "User: $($creds.Username)"
    $credLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 150, 80)
} else {
    $credLabel.Text = "No credentials set - edit credentials.txt"
    $credLabel.ForeColor = [System.Drawing.Color]::Red
}
$form.Controls.Add($credLabel)

# ===== SERVER LIST =====
$listLabel = New-Object System.Windows.Forms.Label
$listLabel.Text = "Servers (from servers.txt):"
$listLabel.Size = New-Object System.Drawing.Size(400, 20)
$listLabel.Location = New-Object System.Drawing.Point(20, 72)
$form.Controls.Add($listLabel)

$listBox = New-Object System.Windows.Forms.ListBox
$listBox.Size = New-Object System.Drawing.Size(390, 150)
$listBox.Location = New-Object System.Drawing.Point(20, 95)
$listBox.SelectionMode = "None"
$form.Controls.Add($listBox)

$servers = Get-Servers
foreach ($s in $servers) { [void]$listBox.Items.Add($s) }

# ===== STATUS LABEL =====
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Size = New-Object System.Drawing.Size(390, 25)
$statusLabel.Location = New-Object System.Drawing.Point(20, 400)
$statusLabel.ForeColor = [System.Drawing.Color]::Green
$statusLabel.Text = "$($servers.Count) server(s) loaded"
$form.Controls.Add($statusLabel)

# ===== LAUNCH ALL BUTTON =====
$launchBtn = New-Object System.Windows.Forms.Button
$launchBtn.Text = "Launch All (Auto-Login)"
$launchBtn.Size = New-Object System.Drawing.Size(390, 45)
$launchBtn.Location = New-Object System.Drawing.Point(20, 255)
$launchBtn.FlatStyle = "Flat"
$launchBtn.BackColor = [System.Drawing.Color]::FromArgb(0, 150, 80)
$launchBtn.ForeColor = [System.Drawing.Color]::White
$launchBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$launchBtn.Cursor = [System.Windows.Forms.Cursors]::Hand

$launchBtn.Add_Click({
    $srvList = Get-Servers
    if ($srvList.Count -eq 0) {
        $statusLabel.Text = "No servers to launch!"
        $statusLabel.ForeColor = [System.Drawing.Color]::Red
        return
    }
    $c = Get-RdpCredentials
    $ok = ($c.Username -ne "" -and $c.Password -ne "" -and $c.Username -ne "DOMAIN\your.username" -and $c.Password -ne "YourPasswordHere")
    if (-not $ok) {
        $statusLabel.Text = "No credentials set - edit credentials.txt first!"
        $statusLabel.ForeColor = [System.Drawing.Color]::Red
        return
    }

    # Minimize the launcher so it doesn't steal focus from RDP
    $form.WindowState = "Minimized"
    Start-Sleep -Milliseconds 500

    foreach ($srv in $srvList) {
        $statusLabel.Text = "Connecting to $srv..."
        Launch-SingleRdp -Server $srv -Username $c.Username -Password $c.Password
        Start-Sleep -Seconds $delaySeconds
    }

    $form.WindowState = "Normal"
    $statusLabel.Text = "Done - $($srvList.Count) session(s) launched."
    $statusLabel.ForeColor = [System.Drawing.Color]::Green
})

$form.Controls.Add($launchBtn)

# ===== EDIT SERVERS BUTTON =====
$editServersBtn = New-Object System.Windows.Forms.Button
$editServersBtn.Text = "Edit servers.txt"
$editServersBtn.Size = New-Object System.Drawing.Size(185, 40)
$editServersBtn.Location = New-Object System.Drawing.Point(20, 310)
$editServersBtn.FlatStyle = "Flat"
$editServersBtn.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$editServersBtn.ForeColor = [System.Drawing.Color]::White
$editServersBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$editServersBtn.Add_Click({ Start-Process "notepad.exe" -ArgumentList $serverFile })
$form.Controls.Add($editServersBtn)

# ===== EDIT CREDENTIALS BUTTON =====
$editCredsBtn = New-Object System.Windows.Forms.Button
$editCredsBtn.Text = "Edit credentials.txt"
$editCredsBtn.Size = New-Object System.Drawing.Size(185, 40)
$editCredsBtn.Location = New-Object System.Drawing.Point(225, 310)
$editCredsBtn.FlatStyle = "Flat"
$editCredsBtn.BackColor = [System.Drawing.Color]::FromArgb(200, 120, 0)
$editCredsBtn.ForeColor = [System.Drawing.Color]::White
$editCredsBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$editCredsBtn.Add_Click({ Start-Process "notepad.exe" -ArgumentList $credFile })
$form.Controls.Add($editCredsBtn)

# ===== REFRESH BUTTON =====
$refreshBtn = New-Object System.Windows.Forms.Button
$refreshBtn.Text = "Refresh"
$refreshBtn.Size = New-Object System.Drawing.Size(390, 35)
$refreshBtn.Location = New-Object System.Drawing.Point(20, 360)
$refreshBtn.FlatStyle = "Flat"
$refreshBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$refreshBtn.Add_Click({
    $listBox.Items.Clear()
    $refreshed = Get-Servers
    foreach ($s in $refreshed) { [void]$listBox.Items.Add($s) }
    $c = Get-RdpCredentials
    $hasC = ($c.Username -ne "" -and $c.Username -ne "DOMAIN\your.username")
    if ($hasC) {
        $credLabel.Text = "User: $($c.Username)"
        $credLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 150, 80)
    } else {
        $credLabel.Text = "No credentials set - edit credentials.txt"
        $credLabel.ForeColor = [System.Drawing.Color]::Red
    }
    $statusLabel.Text = "$($refreshed.Count) server(s) loaded"
    $statusLabel.ForeColor = [System.Drawing.Color]::Green
})
$form.Controls.Add($refreshBtn)

# ===== SHOW FORM =====
$form.TopMost = $true
$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
