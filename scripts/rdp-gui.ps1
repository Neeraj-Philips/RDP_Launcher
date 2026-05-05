# ============================================
# RDP Launcher - Production Version
# ============================================
# UI Automation dismisses security warnings.
# SendKeys types credentials into remote login screen.
# cmdkey stores credentials for NLA passthrough.
# ============================================

#Requires -Version 5.1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptDir   = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent
$configDir   = Join-Path $projectRoot "config"
$serverFile  = Join-Path $configDir  "servers.txt"
$rdpFolder   = Join-Path $projectRoot "rdp_sessions"
$logDir      = Join-Path $projectRoot "logs"
$logFile     = Join-Path $logDir     "rdp-gui.log"
$uiaCsFile   = Join-Path $scriptDir  "lib\RdpUIAutomation.cs"

foreach ($d in @($rdpFolder, $logDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ===== LOGGING =====
function Write-Log {
    param([string]$msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$ts] $msg" -ErrorAction SilentlyContinue
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

# ===== HELPERS =====

function Get-Servers {
    $path = Join-Path $projectRoot "config\servers.txt"
    if (-not (Test-Path $path)) { return @() }
    return @(Get-Content $path |
        Where-Object { $_ -and $_ -notmatch "^\s*#" } |
        ForEach-Object { $_.Trim() })
}

function Store-Credential {
    param([string]$Server, [string]$User, [string]$Pass)
    & cmdkey /delete:TERMSRV/$Server 2>$null | Out-Null
    & cmdkey /generic:TERMSRV/$Server /user:$User /pass:$Pass | Out-Null
}

function New-RdpFile {
    param([string]$Server, [string]$Username)
    $safe = $Server -replace '[^a-zA-Z0-9\.\-]', '_'
    $path = Join-Path $rdpFolder "$safe.rdp"
    @"
full address:s:$Server
username:s:$Username
prompt for credentials:i:1
authentication level:i:2
enablecredsspsupport:i:1
use multimon:i:0
screen mode id:i:1
desktopwidth:i:1280
desktopheight:i:800
"@ | Set-Content -Path $path -Encoding ASCII
    return $path
}

function ConvertTo-SendKeysEscaped {
    param([string]$Text)
    $e = $Text
    $e = $e.Replace('{','{{}').Replace('}','{}}')
    foreach ($c in @('+','^','%','~','!','(',')','[',']')) { $e = $e.Replace($c,"{$c}") }
    return $e
}

# ===== DISMISS SECURITY WARNING (UI Automation) =====
function Dismiss-SecurityWarning {
    param([int]$ProcessId)
    if (-not $uiaLoaded) { return $false }
    $win = [RdpUIAutomation]::FindWindowByPid($ProcessId, 20000)
    if ($null -eq $win) { return $false }
    $title = $win.Current.Name
    Write-Log "  Window: '$title'"
    $clicked = [RdpUIAutomation]::ClickButton($win, "Connect")
    if (-not $clicked) { $clicked = [RdpUIAutomation]::ClickButton($win, "Yes") }
    if (-not $clicked) { $null = [RdpUIAutomation]::ClickFirstActionButton($win); $clicked = $true }
    if ($clicked) { Write-Log "  Security warning dismissed" }
    return $clicked
}

# ===== WAIT FOR SESSION OR CREDENTIAL PROMPT =====
function Wait-ForSessionOrCredentials {
    param([int]$ProcessId, [string]$Server)
    $credWin = $null
    $connected = $false
    $deadline = (Get-Date).AddSeconds(45)

    while ((Get-Date) -lt $deadline) {
        if ($uiaLoaded) {
            # Check for connected RDP session
            $sessWin = [RdpUIAutomation]::WaitForWindowTitleByPid($ProcessId, @($Server), 1000)
            if ($null -ne $sessWin) {
                $t = $sessWin.Current.Name
                if ($t -notmatch "security warning|Connecting to|Configuring|Securing") {
                    $btns = [RdpUIAutomation]::GetButtonNames($sessWin)
                    if ($btns -contains "Minimize" -or $btns -contains "Restore") {
                        $connected = $true; break
                    }
                }
            }
            # Check for credential prompt (window with edit boxes)
            $credWin = [RdpUIAutomation]::WaitForWindowWithEditsByPid($ProcessId, 1000)
            if ($null -ne $credWin) { break }
        }
        Start-Sleep -Milliseconds 500
    }
    return @{ Connected = $connected; CredentialWindow = $credWin }
}

# ===== TYPE CREDENTIALS INTO REMOTE LOGIN SCREEN =====
function Send-RemoteCredentials {
    param([int]$ProcessId, [string]$Username, [string]$Password)
    Start-Sleep -Seconds 3
    $wsh = New-Object -ComObject WScript.Shell
    $wsh.AppActivate($ProcessId) | Out-Null
    Start-Sleep -Milliseconds 800
    $wsh.SendKeys("^a");            Start-Sleep -Milliseconds 100
    $wsh.SendKeys($Username);       Start-Sleep -Milliseconds 300
    $wsh.SendKeys("{TAB}");         Start-Sleep -Milliseconds 300
    $wsh.SendKeys((ConvertTo-SendKeysEscaped $Password))
    Start-Sleep -Milliseconds 300
    $wsh.SendKeys("{ENTER}")
    Write-Log "  Credentials typed into remote login"
}

# ===== FILL LOCAL CREDENTIAL PROMPT (UI Automation) =====
function Submit-LocalCredentials {
    param($Window, [string]$Username, [string]$Password)
    $count = [RdpUIAutomation]::FillCredentials($Window, $Username, $Password)
    Write-Log "  Filled $count edit box(es)"
    Start-Sleep -Milliseconds 800
    $ok = [RdpUIAutomation]::ClickButton($Window, "OK")
    if (-not $ok) { $ok = [RdpUIAutomation]::ClickButton($Window, "Submit") }
    if (-not $ok) { $ok = [RdpUIAutomation]::ClickButton($Window, "Sign in") }
    if (-not $ok) { [RdpUIAutomation]::ClickFirstActionButton($Window) | Out-Null }
    Write-Log "  Credentials submitted"
}

# ===== LAUNCH ONE SERVER =====
function Invoke-RdpConnection {
    param([string]$Server, [string]$Username, [string]$Password)

    Write-Log "--- $Server ---"
    Store-Credential -Server $Server -User $Username -Pass $Password
    $rdp = New-RdpFile -Server $Server -Username $Username

    $proc = Start-Process "mstsc.exe" -ArgumentList "`"$rdp`"" -PassThru
    Write-Log "  PID: $($proc.Id)"
    Start-Sleep -Seconds 2

    # Phase 1: Security warning
    Dismiss-SecurityWarning -ProcessId $proc.Id

    # Phase 2: Session or credential prompt
    $result = Wait-ForSessionOrCredentials -ProcessId $proc.Id -Server $Server

    if ($result.Connected) {
        Write-Log "  Session connected"
        Send-RemoteCredentials -ProcessId $proc.Id -Username $Username -Password $Password
    } elseif ($null -ne $result.CredentialWindow) {
        Write-Log "  Local credential prompt found"
        Submit-LocalCredentials -Window $result.CredentialWindow -Username $Username -Password $Password
    } else {
        Write-Log "  No prompt detected (may have auto-connected)"
    }

    Write-Log "  Done: $Server"
}

# ===== GUI =====

$form = New-Object Windows.Forms.Form
$form.Text = "RDP Launcher"
$form.Size = New-Object Drawing.Size(420, 460)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = New-Object Drawing.Font("Segoe UI", 10)

# Title
$title = New-Object Windows.Forms.Label
$title.Text = "RDP Launcher"
$title.Font = New-Object Drawing.Font("Segoe UI", 14, [Drawing.FontStyle]::Bold)
$title.ForeColor = [Drawing.Color]::FromArgb(0, 120, 215)
$title.Location = "20,10"
$title.Size = "300,30"
$form.Controls.Add($title)

# UIA status
$uiaLabel = New-Object Windows.Forms.Label
$uiaLabel.Font = New-Object Drawing.Font("Segoe UI", 8)
$uiaLabel.Location = "20,42"
$uiaLabel.Size = "360,16"
if ($uiaLoaded) {
    $uiaLabel.Text = "UI Automation: Active"
    $uiaLabel.ForeColor = [Drawing.Color]::FromArgb(0, 150, 80)
} else {
    $uiaLabel.Text = "UI Automation: Unavailable"
    $uiaLabel.ForeColor = [Drawing.Color]::FromArgb(200, 120, 0)
}
$form.Controls.Add($uiaLabel)

# Server list
$listLabel = New-Object Windows.Forms.Label
$listLabel.Text = "Servers (config/servers.txt):"
$listLabel.Location = "20,62"
$listLabel.Size = "360,20"
$form.Controls.Add($listLabel)

$list = New-Object Windows.Forms.ListBox
$list.Location = "20,84"
$list.Size = "360,130"
$list.SelectionMode = "None"
$form.Controls.Add($list)

$servers = Get-Servers
foreach ($s in $servers) { $list.Items.Add($s) }

# Credentials
$userBox = New-Object Windows.Forms.TextBox
$userBox.Location = "20,224"
$userBox.Size = "360,28"
$form.Controls.Add($userBox)

$passBox = New-Object Windows.Forms.TextBox
$passBox.UseSystemPasswordChar = $true
$passBox.Location = "20,258"
$passBox.Size = "360,28"
$form.Controls.Add($passBox)

# Pre-fill from config
$credFile = Join-Path $configDir "credentials.txt"
if (Test-Path $credFile) {
    Get-Content $credFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -match "^Username\s*=\s*(.+)$") { $userBox.Text = $Matches[1].Trim() }
        if ($line -match "^Password\s*=\s*(.+)$") { $passBox.Text = $Matches[1].Trim() }
    }
}

# Launch button
$launchBtn = New-Object Windows.Forms.Button
$launchBtn.Text = "Launch All (Auto-Login)"
$launchBtn.Location = "20,296"
$launchBtn.Size = "360,42"
$launchBtn.FlatStyle = "Flat"
$launchBtn.BackColor = [Drawing.Color]::FromArgb(0, 150, 80)
$launchBtn.ForeColor = [Drawing.Color]::White
$launchBtn.Font = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)
$launchBtn.Cursor = [Windows.Forms.Cursors]::Hand
$form.Controls.Add($launchBtn)

# Edit / Refresh buttons
$editBtn = New-Object Windows.Forms.Button
$editBtn.Text = "Edit servers.txt"
$editBtn.Location = "20,346"
$editBtn.Size = "175,34"
$editBtn.FlatStyle = "Flat"
$editBtn.BackColor = [Drawing.Color]::FromArgb(0, 120, 215)
$editBtn.ForeColor = [Drawing.Color]::White
$editBtn.Cursor = [Windows.Forms.Cursors]::Hand
$editBtn.Add_Click({ Start-Process "notepad.exe" -ArgumentList $serverFile })
$form.Controls.Add($editBtn)

$refreshBtn = New-Object Windows.Forms.Button
$refreshBtn.Text = "Refresh"
$refreshBtn.Location = "205,346"
$refreshBtn.Size = "175,34"
$refreshBtn.FlatStyle = "Flat"
$refreshBtn.Cursor = [Windows.Forms.Cursors]::Hand
$refreshBtn.Add_Click({
    $list.Items.Clear()
    foreach ($s in (Get-Servers)) { $list.Items.Add($s) }
    $status.Text = "$($list.Items.Count) server(s) loaded"
    $status.ForeColor = [Drawing.Color]::Green
})
$form.Controls.Add($refreshBtn)

# Status
$status = New-Object Windows.Forms.Label
$status.Location = "20,390"
$status.Size = "360,30"
$status.ForeColor = [Drawing.Color]::Green
$status.Text = "$($servers.Count) server(s) loaded"
$form.Controls.Add($status)

# ===== LAUNCH ACTION =====
$launchBtn.Add_Click({
    $username = $userBox.Text.Trim()
    $password = $passBox.Text
    $srvList  = Get-Servers

    if (-not $username -or -not $password) {
        $status.Text = "Enter username and password"
        $status.ForeColor = [Drawing.Color]::Red
        return
    }
    if ($srvList.Count -eq 0) {
        $status.Text = "No servers in servers.txt"
        $status.ForeColor = [Drawing.Color]::Red
        return
    }

    $launchBtn.Enabled = $false
    $status.Text = "Launching..."
    $status.ForeColor = [Drawing.Color]::FromArgb(0, 120, 215)
    $form.Refresh()

    Write-Log "=========================================="
    Write-Log "Launch: $($srvList.Count) server(s) as $username"

    $form.WindowState = "Minimized"
    Start-Sleep -Milliseconds 500

    foreach ($srv in $srvList) {
        $status.Text = "Connecting to $srv..."
        $form.Refresh()
        try {
            Invoke-RdpConnection -Server $srv -Username $username -Password $password
        } catch {
            Write-Log "  FAILED: $srv - $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 2
    }

    Write-Log "Launch complete."
    Write-Log "=========================================="

    $form.WindowState = "Minimized"
    $launchBtn.Enabled = $true
    $status.Text = "Done - $($srvList.Count) session(s) launched."
    $status.ForeColor = [Drawing.Color]::Green
})

$form.TopMost = $true
$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
