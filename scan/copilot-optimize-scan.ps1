# ============================================
# Security Scan Script (PS 4.0+ Compatible)
# Works on Windows Server 2012 and newer
# ============================================

# Log all output to file
$logFile = "$env:USERPROFILE\Downloads\scan-results.txt"
Start-Transcript -Path $logFile -Force

Write-Output "Starting security scan..."
Write-Output "Machine: $env:COMPUTERNAME"
Write-Output "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

function Find-FilesByName {
    param(
        [string[]]$Roots,
        [string[]]$Patterns
    )

    $results = @()

    foreach ($root in $Roots) {
        if (-not (Test-Path $root)) { continue }
        Write-Output "Scanning root: $root"

        foreach ($pattern in $Patterns) {
            try {
                $found = @(Get-ChildItem -Path $root -Filter $pattern -Recurse -File -ErrorAction SilentlyContinue)
                if ($found.Count -gt 0) {
                    $results += $found
                }
            }
            catch {}
        }
    }

    return $results
}

# Get all fixed local drives
$scanRoots = @([System.IO.DriveInfo]::GetDrives() |
    Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady } |
    ForEach-Object { $_.RootDirectory.FullName })

if (-not $scanRoots -or $scanRoots.Count -eq 0) {
    Write-Output "ERROR: No ready fixed local drives found."
    exit 1
}

Write-Output "Fixed local drives selected for scan: $($scanRoots -join ', ')"

## [1/3] Scan for compromised JavaScript packages

Write-Output ""
Write-Output "[1/3] Scanning JavaScript package files..."

$jsFiles = @(Find-FilesByName -Roots $scanRoots -Patterns @(
    'package.json',
    'package-lock.json',
    'pnpm-lock.yaml',
    'yarn.lock'
))

Write-Output "Found $($jsFiles.Count) JavaScript package files to scan"

$jsMatches = @()
if ($jsFiles.Count -gt 0) {
    $jsMatches = @($jsFiles | Select-String -Pattern '@(tanstack|opensearch-project|squawk|tallyui|uipath|mistralai)/(mistralai|guardrails-ai)' -ErrorAction SilentlyContinue)
}

if ($jsMatches.Count -gt 0) {
    Write-Output "WARNING: Found $($jsMatches.Count) potential matches in JavaScript packages!"
    foreach ($m in $jsMatches) {
        Write-Output "  $($m.Path):$($m.LineNumber): $($m.Line.Trim())"
    }
}
else {
    Write-Output "No compromised JavaScript packages found"
}

## [2/3] Scan for compromised Python packages

Write-Output ""
Write-Output "[2/3] Scanning Python package files..."

$pyFiles = @(Find-FilesByName -Roots $scanRoots -Patterns @(
    'requirements*.txt',
    'pyproject.toml',
    'poetry.lock',
    'Pipfile*',
    'uv.lock'
))

Write-Output "Found $($pyFiles.Count) Python package files to scan"

$pyMatches = @()
if ($pyFiles.Count -gt 0) {
    $pyMatches = @($pyFiles | Select-String -Pattern '(^|\s)(mistralai|guardrails-ai)[=<>!~]' -ErrorAction SilentlyContinue)
}

if ($pyMatches.Count -gt 0) {
    Write-Output "WARNING: Found $($pyMatches.Count) potential matches in Python packages!"
    foreach ($m in $pyMatches) {
        Write-Output "  $($m.Path):$($m.LineNumber): $($m.Line.Trim())"
    }
}
else {
    Write-Output "No compromised Python packages found"
}

## [3/3] Search for suspicious artifacts

Write-Output ""
Write-Output "[3/3] Searching for suspicious artifacts in $env:USERPROFILE..."

$suspiciousNames = @('gh-token-monitor.*','pgmonitor.py','transformers.pyz','router_init.js','setup.mjs')
$artifacts = @()

try {
    $allFiles = @(Get-ChildItem -Path $env:USERPROFILE -Recurse -File -ErrorAction SilentlyContinue)
    foreach ($f in $allFiles) {
        # Limit to ~4 levels deep
        $relPath = $f.FullName.Substring($env:USERPROFILE.Length)
        $depth = @($relPath.Split('\') | Where-Object { $_ }).Count - 1
        if ($depth -gt 4) { continue }

        foreach ($pattern in $suspiciousNames) {
            if ($f.Name -like $pattern) {
                $artifacts += $f
                break
            }
        }
    }
} catch {}

if ($artifacts.Count -gt 0) {
    Write-Output "WARNING: Found $($artifacts.Count) suspicious artifacts!"
    foreach ($a in $artifacts) {
        Write-Output "  $($a.FullName) (Size: $($a.Length) bytes, Modified: $($a.LastWriteTime))"
    }
}
else {
    Write-Output "No suspicious artifacts found"
}

Write-Output ""
Write-Output "Scan complete!"

Stop-Transcript

Write-Output ""
Write-Output "Results saved to: $logFile"
