# ============================================
# Shared Configuration Module
# ============================================
# Centralizes config loading, validation, and
# logging for all RDP Launcher scripts.
# ============================================

#Requires -Version 5.1

# ===== PATH SETUP =====
$script:ProjectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if ($PSScriptRoot -match 'scripts$') {
    $script:ProjectRoot = Split-Path $PSScriptRoot -Parent
}
# Normalize: if called from scripts/lib, go up two levels
if ($PSScriptRoot -match 'lib$') {
    $script:ProjectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}

$script:ConfigDir  = Join-Path $script:ProjectRoot "config"
$script:RdpFolder  = Join-Path $script:ProjectRoot "rdp_sessions"
$script:LogDir     = Join-Path $script:ProjectRoot "logs"

# ===== DIRECTORY INIT =====
function Initialize-Directories {
    foreach ($d in @($script:RdpFolder, $script:LogDir)) {
        if (-not (Test-Path $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
}

# ===== LOGGING =====
function Write-Log {
    param(
        [string]$Message,
        [string]$LogFile,
        [ValidateSet("INFO", "WARN", "ERROR", "FATAL")]
        [string]$Level = "INFO",
        [switch]$NoConsole
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] [$Level] $Message"
    if ($LogFile) {
        Add-Content -Path $LogFile -Value $entry -ErrorAction SilentlyContinue
    }
    if (-not $NoConsole) {
        switch ($Level) {
            "ERROR" { Write-Host $entry -ForegroundColor Red }
            "WARN"  { Write-Host $entry -ForegroundColor Yellow }
            "FATAL" { Write-Host $entry -ForegroundColor Magenta }
            default { Write-Host $entry }
        }
    }
}

# ===== SERVER LOADING =====
function Get-ServerList {
    param([string]$Path)

    if (-not $Path) {
        $Path = Join-Path $script:ConfigDir "servers.txt"
    }

    if (-not (Test-Path $Path)) {
        return @()
    }

    $servers = @(Get-Content $Path |
        Where-Object { $_ -and $_ -notmatch "^\s*#" } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" })

    return $servers
}

# ===== SERVER VALIDATION =====
function Test-ServerEntry {
    <#
    .SYNOPSIS
    Validates a server entry (IP address or hostname).
    Returns $true if valid, $false otherwise.
    #>
    param([string]$Server)

    if ([string]::IsNullOrWhiteSpace($Server)) { return $false }

    # Block dangerous characters (path traversal, command injection)
    if ($Server -match '[;|&`$<>{}()\[\]\\/"''%]') { return $false }

    # Allow IP:Port format
    $parts = $Server -split ':'
    $host_ = $parts[0]
    if ($parts.Count -gt 1) {
        $port = $parts[1]
        if ($port -notmatch '^\d+$' -or [int]$port -lt 1 -or [int]$port -gt 65535) {
            return $false
        }
    }

    # Validate as IP address
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($host_, [ref]$ip)) {
        return $true
    }

    # Validate as hostname (RFC 1123)
    if ($host_ -match '^[a-zA-Z0-9]([a-zA-Z0-9\-\.]{0,253}[a-zA-Z0-9])?$') {
        return $true
    }

    return $false
}

function Get-ValidatedServers {
    <#
    .SYNOPSIS
    Loads and validates server list. Returns only valid entries.
    Logs warnings for invalid entries.
    #>
    param(
        [string]$Path,
        [string]$LogFile
    )

    $servers = Get-ServerList -Path $Path
    $valid = @()

    foreach ($s in $servers) {
        if (Test-ServerEntry -Server $s) {
            $valid += $s
        } else {
            Write-Log -Message "Invalid server entry skipped: '$s'" -LogFile $LogFile -Level "WARN"
        }
    }

    return ,$valid
}

# ===== CREDENTIAL LOADING =====
function Get-ConfiguredUsername {
    <#
    .SYNOPSIS
    Loads username from config/user.txt.
    Returns empty string if not configured.
    #>
    $creds = Get-ConfiguredCredentials
    return $creds.Username
}

function Get-ConfiguredPassword {
    <#
    .SYNOPSIS
    Loads password from config/user.txt.
    Returns empty string if not configured.
    #>
    $creds = Get-ConfiguredCredentials
    return $creds.Password
}

function Get-ConfiguredCredentials {
    <#
    .SYNOPSIS
    Loads username and password from config/user.txt.
    Returns hashtable with Username and Password keys.
    #>
    $userFile = Join-Path $script:ConfigDir "user.txt"
    $result = @{ Username = ""; Password = "" }

    if (-not (Test-Path $userFile)) {
        return $result
    }

    Get-Content $userFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -match "^Username\s*=\s*(.+)$") { $result.Username = $Matches[1].Trim() }
        if ($line -match "^Password\s*=\s*(.+)$") { $result.Password = $Matches[1].Trim() }
    }

    return $result
}

# ===== RDP FILE GENERATION =====
function New-RdpFile {
    <#
    .SYNOPSIS
    Generates a secure RDP file for a server connection.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Server,

        [Parameter(Mandatory)]
        [string]$Username,

        [string]$OutputPath,

        [int]$Width = 1280,
        [int]$Height = 800,

        [switch]$PromptForCredentials,

        [switch]$FullScreen,

        [switch]$MultiMonitor
    )

    if (-not $OutputPath) {
        $safe = $Server -replace '[^a-zA-Z0-9\.\-]', '_'
        $OutputPath = Join-Path $script:RdpFolder "$safe.rdp"
    }

    $promptVal = if ($PromptForCredentials) { 1 } else { 0 }
    $screenMode = if ($FullScreen -or $MultiMonitor) { 2 } else { 1 }
    $multimonVal = if ($MultiMonitor) { 1 } else { 0 }
    $spanVal = if ($Width -gt 1920 -and -not $MultiMonitor) { 1 } else { 0 }

    $content = @"
full address:s:$Server
username:s:$Username
prompt for credentials:i:$promptVal
authentication level:i:0
enablecredsspsupport:i:1
use multimon:i:$multimonVal
span monitors:i:$spanVal
screen mode id:i:$screenMode
desktopwidth:i:$Width
desktopheight:i:$Height
smart sizing:i:1
redirectclipboard:i:1
disable wallpaper:i:1
allow font smoothing:i:1
"@

    # If multi-monitor, use all available monitors (no selectedmonitors restriction)
    # This lets the RDP session span across all monitors connected to the machine.

    Set-Content -Path $OutputPath -Value $content -Encoding ASCII
    return $OutputPath
}

# ===== PROCESS LAUNCH WITH RETRY =====
function Start-RdpProcess {
    <#
    .SYNOPSIS
    Launches mstsc.exe with retry logic.
    Returns the process object or $null on failure.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$RdpFilePath,

        [int]$MaxRetries = 2,
        [int]$RetryDelayMs = 1000,
        [string]$LogFile
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $proc = Start-Process "mstsc.exe" -ArgumentList "`"$RdpFilePath`"" -PassThru -ErrorAction Stop

            if ($null -ne $proc -and -not $proc.HasExited) {
                if ($attempt -gt 1) {
                    Write-Log -Message "  Launched on attempt $attempt" -LogFile $LogFile -Level "INFO"
                }
                return $proc
            }
        }
        catch {
            Write-Log -Message "  Launch attempt $attempt failed: $($_.Exception.Message)" -LogFile $LogFile -Level "WARN"
        }

        if ($attempt -lt $MaxRetries) {
            Start-Sleep -Milliseconds $RetryDelayMs
        }
    }

    return $null
}
