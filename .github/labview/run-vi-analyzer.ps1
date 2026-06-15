<#
.SYNOPSIS
    Runs LabVIEW VI Analyzer (Windows container) and generates an HTML report.

.PARAMETER WorkspaceRoot
    Absolute path to the project inside the container. Default: C:\workspace

.PARAMETER ReportDir
    Output directory for the XML results and HTML report.

.PARAMETER ConfigTemplate
    Path to the .viancfg template file (uses __WORKSPACE_PATH__ placeholder).

.PARAMETER LabVIEWPath
    Path to LabVIEW.exe inside the container.
#>
param(
    [string]$WorkspaceRoot   = 'C:\workspace',
    [string]$ReportDir       = 'C:\report',
    [string]$ConfigTemplate  = 'C:\workspace\.github\labview\via-configs\via-config-default.viancfg',
    [string]$LabVIEWPath     = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Resolve-LabVIEWPath([string]$PreferredPath) {
    if ($PreferredPath -and (Test-Path $PreferredPath)) {
        return $PreferredPath
    }

    $candidates = @(Get-ChildItem 'C:\Program Files\National Instruments' -Directory -Filter 'LabVIEW *' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'LabVIEW.exe' } |
        Where-Object { Test-Path $_ })

    if ($candidates.Count -gt 0) {
        return $candidates[0]
    }

    throw "LabVIEW.exe not found. Checked preferred path '$PreferredPath' and C:\Program Files\National Instruments\LabVIEW *"
}

function Resolve-LabVIEWCLI([string]$LabVIEWExePath) {
    $cliCmd = Get-Command LabVIEWCLI.exe -ErrorAction SilentlyContinue
    if ($null -eq $cliCmd) {
        $cliCmd = Get-Command LabVIEWCLI -ErrorAction SilentlyContinue
    }
    if ($null -ne $cliCmd -and $cliCmd.Source) {
        return $cliCmd.Source
    }

    $candidate = Join-Path (Split-Path $LabVIEWExePath) 'LabVIEWCLI.exe'
    if (Test-Path $candidate) {
        return $candidate
    }

    throw "LabVIEWCLI not found on PATH and not found beside LabVIEW.exe ('$candidate')."
}

$LabVIEWPath = Resolve-LabVIEWPath $LabVIEWPath
$CliExe     = Resolve-LabVIEWCLI $LabVIEWPath
$ConfigFile = Join-Path $ReportDir 'via-config.viancfg'
$ResultsXml = Join-Path $ReportDir 'via-results.xml'
$HtmlOut    = Join-Path $ReportDir 'index.html'

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

Write-Host "=== VI Analyzer (Windows) ==="
Write-Host "  Workspace  : $WorkspaceRoot"
Write-Host "  LabVIEW    : $LabVIEWPath"
Write-Host "  Config src : $ConfigTemplate"

# ── Patch config: replace __WORKSPACE_PATH__ with the actual container path ──
$ConfigXml = Get-Content $ConfigTemplate -Raw
$ConfigXml = $ConfigXml -replace '__WORKSPACE_PATH__', $WorkspaceRoot
[System.IO.File]::WriteAllText($ConfigFile, $ConfigXml, [System.Text.UTF8Encoding]::new($false))
Write-Host "  Config out : $ConfigFile"
Write-Host ""

$Start = Get-Date

# NOTE: -Headless is REQUIRED for LabVIEW 2026+ inside Windows containers, otherwise
# LabVIEWCLI cannot establish a VI Server connection (error -350000).
& $CliExe `
    -LogToConsole  TRUE `
    -OperationName RunVIAnalyzer `
    -ConfigPath    $ConfigFile `
    -ReportPath    $ResultsXml `
    -LabVIEWPath   $LabVIEWPath `
    -Headless

$ExitCode = $LASTEXITCODE
$Duration = [math]::Round(((Get-Date) - $Start).TotalSeconds, 1)

Write-Host ""
Write-Host "=== VI Analyzer finished (exit=$ExitCode duration=${Duration}s) ==="

# ── Parse XML results ────────────────────────────────────────────────────────
$Passed = 0; $Failed = 0; $TotalVIs = 0
if (Test-Path $ResultsXml) {
    try {
        [xml]$Xml = Get-Content $ResultsXml -Raw
        $TestResults = $Xml.SelectNodes("//TestResult")
        foreach ($r in $TestResults) {
            if ($r.Result -eq 'Pass') { $Passed++ } else { $Failed++ }
        }
        $TotalVIs = ($Xml.SelectNodes("//VI") | Measure-Object).Count
    } catch {
        Write-Warning "Could not parse results XML: $_"
    }
}

$StatusLabel = if ($ExitCode -eq 0 -and $Failed -eq 0) { 'PASSED' } else { 'FAILED' }
$StatusColor = if ($StatusLabel -eq 'PASSED') { '#2ea043' } else { '#da3633' }

# ── Embed results XML as escaped HTML ────────────────────────────────────────
function Encode-Html([string]$s) {
    $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
}
$XmlContent = if (Test-Path $ResultsXml) { Get-Content $ResultsXml -Raw } else { '(no results file)' }
$XmlHtml    = Encode-Html $XmlContent
$ReportTs   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')

$Html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>VI Analyzer — LabVIEW-CI-with-Containers</title>
  <style>
    *{box-sizing:border-box}
    body{margin:0;padding:20px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0d1117;color:#e6edf3}
    .card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:20px;margin-bottom:16px}
    h1{margin:0 0 12px;font-size:1.3em}
    .badge{display:inline-block;padding:3px 10px;border-radius:4px;font-weight:700;font-size:.85em;color:#fff;background:$StatusColor}
    .meta{margin-top:10px;font-size:.82em;color:#8b949e;display:flex;flex-wrap:wrap;gap:16px}
    pre{background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:14px;font-size:.75em;white-space:pre-wrap;word-break:break-all;overflow-y:auto;max-height:65vh;margin:0}
  </style>
</head>
<body>
  <div class="card">
    <h1>VI Analyzer — LabVIEW-CI-with-Containers</h1>
    <span class="badge">$StatusLabel</span>
    <div class="meta">
      <span>Date: $ReportTs</span>
      <span>Duration: ${Duration}s</span>
      <span>VIs analyzed: $TotalVIs</span>
      <span>Tests passed: $Passed</span>
      <span>Tests failed: $Failed</span>
    </div>
  </div>
  <pre>$XmlHtml</pre>
</body>
</html>
"@

[System.IO.File]::WriteAllText($HtmlOut, $Html, [System.Text.UTF8Encoding]::new($false))
Write-Host "HTML report -> $HtmlOut"

exit $ExitCode
