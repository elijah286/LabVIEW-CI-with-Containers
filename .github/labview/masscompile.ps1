<#
.SYNOPSIS
    Runs LabVIEW Mass Compile on the workspace, then generates an HTML report.

.PARAMETER WorkspaceRoot
    Absolute path inside the container to the project root.
    Default: C:\workspace (GitHub Actions volume mount point)

.PARAMETER ReportDir
    Directory to write masscompile.log and index.html into.

.PARAMETER LabVIEWPath
    Path to LabVIEW.exe inside the container.
#>
param(
    [string]$WorkspaceRoot = 'C:\workspace',
    [string]$ReportDir     = 'C:\report',
    [string]$LabVIEWPath   = 'C:\Program Files\National Instruments\LabVIEW 2024\LabVIEW.exe'
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
$CliExe  = Resolve-LabVIEWCLI $LabVIEWPath
$LogFile = Join-Path $ReportDir 'masscompile.log'
$HtmlOut = Join-Path $ReportDir 'index.html'

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

Write-Host "=== Mass Compile ==="
Write-Host "  Workspace : $WorkspaceRoot"
Write-Host "  LabVIEW   : $LabVIEWPath"
Write-Host "  CLI       : $CliExe"
Write-Host ""

$Start = Get-Date

# Run MassCompile and tee output to log.
# NOTE: -Headless is REQUIRED for LabVIEW 2026+ inside Windows containers, otherwise
# LabVIEWCLI cannot establish a VI Server connection (error -350000).
# LabVIEWCLI prints its operation output to stderr; relax ErrorActionPreference so
# that merging it with 2>&1 does not raise a terminating NativeCommandError. We
# judge success by the real $LASTEXITCODE instead.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $CliExe `
    -LogToConsole       TRUE `
    -OperationName      MassCompile `
    -DirectoryToCompile $WorkspaceRoot `
    -LabVIEWPath        $LabVIEWPath `
    -Headless `
    2>&1 | Tee-Object -FilePath $LogFile

$ExitCode = $LASTEXITCODE
$Duration = [math]::Round(((Get-Date) - $Start).TotalSeconds, 1)

# Keep going even if report parsing hits an unexpected condition — we always want
# to emit an index.html so the dashboard never links to a 404.
$ErrorActionPreference = 'Continue'

# ── Compute per-VI compile success ───────────────────────────────────────────
# LabVIEW Mass Compile processes every VI individually: VIs that do not depend on
# libraries missing from the CI image (NI-DAQmx / OpenG / G-Image / G-Audio) still
# compile cleanly, while only the ones that do are flagged "### Bad VI/subVI ...
# Path=...". So instead of a binary pass/fail, report the percentage of project VIs
# that compiled.
#   Denominator: every .vi under the workspace except the CI tooling in .github.
#   Failures:    unique project VI paths flagged bad in the log. The log is UTF-16
#                and LabVIEW hard-wraps long lines, so a captured Path may contain
#                embedded newlines — strip them before de-duping.
$LogText = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($LogText)) { $LogText = '(no output captured)' }

$AllVIs = @(Get-ChildItem -LiteralPath $WorkspaceRoot -Recurse -File -Filter '*.vi' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '(?i)\\\.github\\' })
$TotalVIs = $AllVIs.Count

$wsPrefix = ($WorkspaceRoot.TrimEnd('\') + '\').ToLowerInvariant()
$BadSet = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($m in [regex]::Matches($LogText, 'Path="([^"]+)"')) {
    $p = ($m.Groups[1].Value -replace '[\r\n]', '').ToLowerInvariant()
    if ($p.EndsWith('.vi') -and $p.StartsWith($wsPrefix) -and ($p -notmatch '\\\.github\\')) {
        [void]$BadSet.Add($p)
    }
}
$BadVIs  = $BadSet.Count
$OkVIs   = [math]::Max(0, $TotalVIs - $BadVIs)
$Percent = if ($TotalVIs -gt 0) { [int][math]::Round($OkVIs / $TotalVIs * 100) } else { 0 }

# Classify the run. LabVIEW Mass Compile returns exit code 3 when it finished but
# flagged some bad VIs (the ones depending on libraries absent from the CI image) —
# that is a PARTIAL compile, not a failure. Any OTHER non-zero code (or zero project
# VIs discovered) means LabVIEW could not complete the compile at all: a true, red
# failure. A clean exit with nothing bad is a full pass.
$RealError = ($ExitCode -ne 0 -and $ExitCode -ne 3)
if ($RealError -or $TotalVIs -le 0) {
    $StatusWord = 'failed'
} elseif ($ExitCode -eq 0 -and $BadVIs -eq 0) {
    $StatusWord = 'passed'
} elseif ($OkVIs -le 0) {
    $StatusWord = 'failed'
} else {
    $StatusWord = 'partial'
}
# A true failure means nothing reliably compiled — zero the figures so the summary
# and badge read 0% (red), not an inflated count from a run that never completed.
if ($StatusWord -eq 'failed') { $OkVIs = 0; $Percent = 0 }
$StatusLabel = if ($StatusWord -eq 'failed') { 'compile failed' } else { "$Percent% compiled" }
# Yellow for a partial (some VIs failed); red reserved for a true failure; green at 100%.
$StatusColor = if ($StatusWord -eq 'passed') { '#2ea043' } elseif ($StatusWord -eq 'failed') { '#da3633' } else { '#bb8009' }

Write-Host ""
Write-Host "=== Result: $StatusLabel ($OkVIs/$TotalVIs project VIs, $BadVIs bad; exit=$ExitCode duration=${Duration}s) ==="

# Machine-readable summary: the dashboard's Mass Compile column reads this to show
# the percentage badge, and the workflow reads it for the commit-status description.
$Summary = [ordered]@{
    total    = $TotalVIs
    ok       = $OkVIs
    bad      = $BadVIs
    percent  = $Percent
    status   = $StatusWord
    exit     = $ExitCode
    duration = $Duration
}
[System.IO.File]::WriteAllText((Join-Path $ReportDir 'summary.json'), ($Summary | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))

# ── Generate HTML report ─────────────────────────────────────────────────────
function Encode-Html([string]$s) {
    $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
}

if ([string]::IsNullOrEmpty($LogText)) {
  $LogText = '(no output captured)'
}
$LogHtml  = Encode-Html $LogText
$ReportTs = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')

$Html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Mass Compile — LabVIEW-CI-with-Containers</title>
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
    <h1>Mass Compile — LabVIEW-CI-with-Containers</h1>
    <span class="badge">$StatusLabel</span>
    <div class="meta">
      <span>Date: $ReportTs</span>
      <span>Duration: ${Duration}s</span>
      <span>Project VIs: $TotalVIs</span>
      <span>Compiled OK: $OkVIs</span>
      <span>Bad: $BadVIs</span>
    </div>
  </div>
  <pre>$LogHtml</pre>
</body>
</html>
"@

[System.IO.File]::WriteAllText($HtmlOut, $Html, [System.Text.UTF8Encoding]::new($false))
Write-Host "HTML report -> $HtmlOut"

# Partial/passed are a successful CI outcome (the report shows the %); only a true
# failure fails the job and turns the commit status red.
if ($StatusWord -eq 'failed') { exit 1 } else { exit 0 }
