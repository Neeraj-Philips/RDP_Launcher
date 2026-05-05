# ============================================
# RDP Launcher - Headless Auto-Run
# ============================================
# For Task Scheduler. Same logic as GUI version.
#
# Task Scheduler:
#   Program:   powershell.exe
#   Arguments: -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\path\to\scripts\rdp-auto.ps1"
#   Trigger:   At log on
# ============================================

#Requires -Version 5.1

$ErrorActionPreference = "Continue"

$scriptDir   = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent
$configDir   = Join-Path $projectRoot "config"
$serverFile  = Join-Path $configDir  "servers.txt"
$credFile    = Join-Path $configDir  "credentials.txt"
$rdpFolder   = Join-Path $projectRoot "rdp_sessions"
$logDir      = Join-Path $projectRoot "logs"
$logFile     = Join-Path $logDir     "rdp-auto.log"
$uiaCsFile   = Join-Path $scriptDir  "lib\RdpUIAutomation.cs"

foreach ($d in @($rdpFolder, $logDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Write-Log {
    param([string]$msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] $msg"
    Add-Content -Path $logFile -Value $entry -ErrorAction SilentlyContinue
    Write-Host $entry
}

# Load UI Automation
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

function ConvertTo-SendKeysEscaped {
    param([string]$Text)
    $e = $Text
    $e = $e.Replace('{','{{}').Replace('}','{}}')
    foreach ($c in @('+','^','%','~','!','(',')','[',']')) { $e = $e.Replace($c,"{$c}") }
    return $e
}

# ===== MAIN =====
try {

# Load servers
if (-not (Test-Path $serverFile)) { Write-Log "ERROR: $serverFile not found"; exit 1 }
$servers = @(Get-Content (Join-Path $projectRoot "config\servers.txt") |
    Where-Object { $_ -and $_ -notmatch "^\s*#" } |
    ForEach-Object { $_.Trim() })
if ($servers.Count -eq 0) { Write-Log "ERROR: No servers"; exit 1 }

# Load credentials
$username = ""; $password = ""
if (Test-Path $credFile) {
    Get-Content $credFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -match "^Username\s*=\s*(.+)$") { $username = $Matches[1].Trim() }
        if ($line -match "^Password\s*=\s*(.+)$") { $password = $Matches[1].Trim() }
    }
}
if (-not $username -or -not $password) {
    Write-Log "ERROR: No credentials in $credFile"; exit 1
}

# Registry trust
try {
    $reg = "HKCU:\Software\Microsoft\Terminal Server Client"
    if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
    Set-ItemProperty -Path $reg -Name "AuthenticationLevelOverride" -Value 0 -Type DWord -Force
} catch {}

Write-Log "=========================================="
Write-Log "Auto-launch: $($servers.Count) server(s) as $username"

foreach ($server in $servers) {
    Write-Log "--- $server ---"
    try {
        # Store credential
        & cmdkey /delete:TERMSRV/$server 2>$null | Out-Null
        & cmdkey /generic:TERMSRV/$server /user:$username /pass:$password | Out-Null

        # Generate .rdp
        $safe = $server -replace '[^a-zA-Z0-9\.\-]', '_'
        $rdpPath = Join-Path $rdpFolder "$safe.rdp"
        @"
full address:s:$server
username:s:$username
prompt for credentials:i:1
authentication level:i:2
enablecredsspsupport:i:1
use multimon:i:0
screen mode id:i:1
desktopwidth:i:1280
desktopheight:i:800
"@ | Set-Content -Path $rdpPath -Encoding ASCII

        # Launch
        $proc = Start-Process "mstsc.exe" -ArgumentList "`"$rdpPath`"" -PassThru
        Write-Log "  PID: $($proc.Id)"
        Start-Sleep -Seconds 2

        if ($uiaLoaded) {
            # Phase 1: Security warning
            $win = [RdpUIAutomation]::FindWindowByPid($proc.Id, 20000)
            if ($null -ne $win) {
                $clicked = [RdpUIAutomation]::ClickButton($win, "Connect")
                if (-not $clicked) { $clicked = [RdpUIAutomation]::ClickButton($win, "Yes") }
                if (-not $clicked) { [RdpUIAutomation]::ClickFirstActionButton($win) | Out-Null }
                Write-Log "  Security warning dismissed"
            }

            # Phase 2: Session or credential prompt
            $credWin = $null; $connected = $false
            $deadline = (Get-Date).AddSeconds(45)
            while ((Get-Date) -lt $deadline) {
                $sessWin = [RdpUIAutomation]::WaitForWindowTitleByPid($proc.Id, @($server), 1000)
                if ($null -ne $sessWin) {
                    $t = $sessWin.Current.Name
                    if ($t -notmatch "security warning|Connecting to|Configuring|Securing") {
                        $btns = [RdpUIAutomation]::GetButtonNames($sessWin)
                        if ($btns -contains "Minimize" -or $btns -contains "Restore") {
                            $connected = $true; break
                        }
                    }
                }
                $credWin = [RdpUIAutomation]::WaitForWindowWithEditsByPid($proc.Id, 1000)
                if ($null -ne $credWin) { break }
                Start-Sleep -Milliseconds 500
            }

            if ($connected) {
                Write-Log "  Session connected - typing credentials"
                Start-Sleep -Seconds 3
                $wsh = New-Object -ComObject WScript.Shell
                $wsh.AppActivate($proc.Id) | Out-Null
                Start-Sleep -Milliseconds 800
                $wsh.SendKeys("^a"); Start-Sleep -Milliseconds 100
                $wsh.SendKeys($username); Start-Sleep -Milliseconds 300
                $wsh.SendKeys("{TAB}"); Start-Sleep -Milliseconds 300
                $wsh.SendKeys((ConvertTo-SendKeysEscaped $password))
                Start-Sleep -Milliseconds 300
                $wsh.SendKeys("{ENTER}")
                Write-Log "  Credentials typed"
            } elseif ($null -ne $credWin) {
                [RdpUIAutomation]::FillCredentials($credWin, $username, $password) | Out-Null
                Start-Sleep -Milliseconds 800
                $ok = [RdpUIAutomation]::ClickButton($credWin, "OK")
                if (-not $ok) { [RdpUIAutomation]::ClickButton($credWin, "Submit") | Out-Null }
                Write-Log "  Credentials submitted via UIA"
            } else {
                Write-Log "  No prompt detected"
            }
        } else {
            # SendKeys fallback
            $wsh = New-Object -ComObject WScript.Shell
            Start-Sleep -Seconds 5
            $wsh.AppActivate("Remote Desktop Connection") | Out-Null
            Start-Sleep -Milliseconds 500
            $wsh.SendKeys("{ENTER}")
            Start-Sleep -Seconds 8
            $wsh.AppActivate($proc.Id) | Out-Null
            Start-Sleep -Milliseconds 500
            $wsh.SendKeys("^a"); Start-Sleep -Milliseconds 100
            $wsh.SendKeys($username); Start-Sleep -Milliseconds 200
            $wsh.SendKeys("{TAB}"); Start-Sleep -Milliseconds 200
            $wsh.SendKeys((ConvertTo-SendKeysEscaped $password))
            Start-Sleep -Milliseconds 300
            $wsh.SendKeys("{ENTER}")
            Write-Log "  Credentials typed via SendKeys"
        }

        Write-Log "  Done: $server"
    } catch {
        Write-Log "  FAILED: $server - $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 2
}

Write-Log "Auto-launch complete."
Write-Log "=========================================="

} catch {
    Write-Log "FATAL: $($_.Exception.Message)"
}
