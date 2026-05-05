# ============================================
# RDP Launcher - Headless Auto-Run
# ============================================
# Headless RDP launcher for Task Scheduler.
# Reads credentials from config/user.txt.
# Auto-login via cmdkey + UI Automation.
# ============================================

#Requires -Version 5.1

$ErrorActionPreference = "Stop"

# ===== LOAD SHARED CONFIG =====
$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir "lib\Config.ps1")

$projectRoot = Split-Path $scriptDir -Parent
$configDir   = Join-Path $projectRoot "config"
$serverFile  = Join-Path $configDir  "servers.txt"
$rdpFolder   = Join-Path $projectRoot "rdp_sessions"
$logDir      = Join-Path $projectRoot "logs"
$logFile     = Join-Path $logDir     "rdp-auto.log"

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
    Write-Log -Message "ERROR: No username configured in config/user.txt" -LogFile $logFile -Level "ERROR"
    exit 1
}

# ===== MAIN =====
try {
    Write-Log -Message "==========================================" -LogFile $logFile
    Write-Log -Message "RDP Auto Launcher" -LogFile $logFile
    Write-Log -Message "  Username: $username" -LogFile $logFile

    # Load and validate servers
    $servers = Get-ValidatedServers -Path $serverFile -LogFile $logFile

    if ($servers.Count -eq 0) {
        Write-Log -Message "ERROR: No valid servers in $serverFile" -LogFile $logFile -Level "ERROR"
        exit 1
    }

    Write-Log -Message "  Servers: $($servers.Count)" -LogFile $logFile

    # Track results
    $launched = 0
    $failed   = 0

    # Launch each server
    foreach ($server in $servers) {
        Write-Log -Message "--- $server ---" -LogFile $logFile

        try {
            # Store credential via cmdkey if not already present
            $cmdkeyList = & cmdkey /list 2>&1 | Out-String
            if ($cmdkeyList -notmatch [regex]::Escape("TERMSRV/$server")) {
                if ($password) {
                    & cmdkey /generic:TERMSRV/$server /user:$username /pass:$password | Out-Null
                    Write-Log -Message "  Credential stored for $server" -LogFile $logFile
                } else {
                    Write-Log -Message "  No password in config - will prompt on connect" -LogFile $logFile -Level "WARN"
                }
            }

            # Generate RDP file (no prompt - we handle auth via cmdkey + UI Automation)
            $rdpPath = New-RdpFile -Server $server -Username $username -Width 1280 -Height 800
            Write-Log -Message "  RDP file: $rdpPath" -LogFile $logFile

            # Launch with retry
            $proc = Start-RdpProcess -RdpFilePath $rdpPath -MaxRetries 3 -LogFile $logFile

            if ($null -ne $proc) {
                Write-Log -Message "  PID: $($proc.Id)" -LogFile $logFile

                # Auto-login via UI Automation
                if ($uiAutomationLoaded -and $password) {
                    # Dismiss security warning
                    $securityTitles = @("security", "certificate", "trust", "warning")
                    $secWin = [RdpUIAutomation]::WaitForWindowTitleByPid($proc.Id, $securityTitles, 8000)
                    if ($null -ne $secWin) {
                        Write-Log -Message "  Security warning detected" -LogFile $logFile
                        $clicked = [RdpUIAutomation]::ClickButton($secWin, "Yes")
                        if (-not $clicked) { [RdpUIAutomation]::ClickFirstActionButton($secWin) | Out-Null }
                        Write-Log -Message "  Security warning dismissed" -LogFile $logFile
                        Start-Sleep -Milliseconds 1500
                    }

                    # Fill credentials if prompted
                    $credWin = [RdpUIAutomation]::WaitForWindowWithEditsByPid($proc.Id, 8000)
                    if ($null -ne $credWin) {
                        [RdpUIAutomation]::FillCredentials($credWin, $username, $password) | Out-Null
                        Start-Sleep -Milliseconds 500
                        $clicked = [RdpUIAutomation]::ClickButton($credWin, "OK")
                        if (-not $clicked) { [RdpUIAutomation]::ClickFirstActionButton($credWin) | Out-Null }
                        Write-Log -Message "  Credentials submitted" -LogFile $logFile
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

        # Stagger launches to avoid resource contention
        Start-Sleep -Seconds 2
    }

    # Summary
    Write-Log -Message "==========================================" -LogFile $logFile
    Write-Log -Message "Complete: $launched launched, $failed failed" -LogFile $logFile
    Write-Log -Message "==========================================" -LogFile $logFile

    if ($failed -gt 0) {
        exit 1
    }
}
catch {
    Write-Log -Message "FATAL: $($_.Exception.Message)" -LogFile $logFile -Level "FATAL"
    Write-Log -Message "  Stack: $($_.ScriptStackTrace)" -LogFile $logFile -Level "FATAL"
    exit 1
}
