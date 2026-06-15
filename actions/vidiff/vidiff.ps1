<#
.SYNOPSIS
    Generates VIDiff comparison reports for changed VIs (Windows container).

.DESCRIPTION
    For each VI that differs between base and head:
      - Modified  → CreateComparisonReport (side-by-side diff)
      - Added     → PrintToSingleFileHtml of the new VI (no base)
      - Deleted   → PrintToSingleFileHtml of the old VI (no head)

    Magic-byte check (LVIN / LVCC) skips non-LabVIEW files with .vi/.ctl extension.

.PARAMETER BaseDir
    Container path where the base commit checkout is mounted.

.PARAMETER HeadDir
    Container path where the head commit checkout is mounted.

.PARAMETER ChangedFiles
    Newline-separated list of changed files (relative workspace paths).

.PARAMETER ReportDir
    Output directory for HTML diff reports.

.PARAMETER LabVIEWPath
    Path to LabVIEW.exe inside the container.
#>
param(
    [string]$BaseDir      = 'C:\workspace-base',
    [string]$HeadDir      = 'C:\workspace',
    [string]$ChangedFiles = '',   # passed as env or piped
    [string]$ReportDir    = 'C:\report',
    [string]$LabVIEWPath  = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe',
    # Directory containing the PrintToSingleFileHtml operation. Defaults to the head
    # checkout, but the backfill orchestrator passes a stable ops mount because old
    # commits' worktrees predate the CI scripts.
    [string]$OpsDir       = '',
    # Optional file with the newline-separated changed-file list (more robust than a
    # multiline env var across docker exec). Takes precedence over -ChangedFiles/env.
    [string]$ChangedFilesPath = ''
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
    if ($null -eq $cliCmd) { $cliCmd = Get-Command LabVIEWCLI -ErrorAction SilentlyContinue }
    if ($null -ne $cliCmd -and $cliCmd.Source) { return $cliCmd.Source }
    $candidate = Join-Path (Split-Path $LabVIEWExePath) 'LabVIEWCLI.exe'
    if (Test-Path $candidate) { return $candidate }
    throw "LabVIEWCLI not found on PATH and not found beside LabVIEW.exe ('$candidate')."
}

$LabVIEWPath = Resolve-LabVIEWPath $LabVIEWPath
$CliExe      = Resolve-LabVIEWCLI $LabVIEWPath
# AdditionalOperationDirectory is searched recursively for the operation class,
# so point it at .github\labview (the parent of the PrintToSingleFileHtml folder).
$PrintToHtmlOp   = if ($OpsDir -ne '') { $OpsDir } else { Join-Path $HeadDir '.github\labview' }

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

# ── Helper: is this a real LabVIEW binary? ───────────────────────────────────
function Test-IsLabVIEWFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $false }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 4) { return $false }
        # LabVIEW files use the Mac resource fork format starting with RSRC
        $magic = [System.Text.Encoding]::ASCII.GetString($bytes[0..3])
        return ($magic -eq 'RSRC')
    } catch { return $false }
}

# ── Browser-compatibility fix for comparison reports ─────────────────────────
# CreateComparisonReport lays out the head-side diagram image with
#   position: relative; top: calc(-100% - 23px)
# inside an `aspect-ratio` box so an interactive sub-VI hotspot layer can sit on
# top of it. Safari does not resolve the percentage `top` against an
# aspect-ratio-derived height, so the image drops below its box and overlaps the
# change-description text underneath it. Inject a <style> that renders the image
# in normal flow and overlays the hotspot layer with absolute positioning (which
# needs no percentage-height resolution) — this fixes Safari/Firefox while
# keeping the hover tooltips aligned to the image in every browser.
function Add-OverlayFix([string]$HtmlPath) {
    if (-not (Test-Path $HtmlPath)) { return }
    $html = [System.IO.File]::ReadAllText($HtmlPath)
    if ($html.Contains('vidiff-overlay-fix')) { return }
    $css = 'td.diff-image>div[style*="aspect-ratio"]{aspect-ratio:auto!important;height:auto!important;max-width:100%!important;position:relative!important}td.diff-image>div[style*="aspect-ratio"]>div{height:auto!important}td.diff-image>div[style*="aspect-ratio"]>div>div{position:absolute!important;inset:0!important;height:auto!important}td.diff-image img.difference-image{position:static!important;top:auto!important}'
    $style = '<style id="vidiff-overlay-fix">' + $css + '</style>'
    if ($html.Contains('</head>')) {
        # </head> follows the stylesheet <link>, so the override lands after it.
        $html = $html.Replace('</head>', $style + '</head>')
    } else {
        $html = $style + $html
    }
    [System.IO.File]::WriteAllText($HtmlPath, $html, [System.Text.UTF8Encoding]::new($false))
}

# ── Parse changed-file list ──────────────────────────────────────────────────
if ($ChangedFilesPath -ne '' -and (Test-Path $ChangedFilesPath)) {
    $ChangedFiles = Get-Content $ChangedFilesPath -Raw
}
if ($ChangedFiles -eq '') {
    $ChangedFiles = $Env:CHANGED_FILES
}
# Split on CR?LF and trim each entry: a file written with \r\n line endings would
# otherwise leave a trailing \r that breaks the '\.(vi|ctl)$' end-anchored match.
$Files = $ChangedFiles -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\.(vi|ctl)$' }
Write-Host "Changed VI/CTL files to diff: $($Files.Count)"

if ($Files.Count -eq 0) {
    Write-Host 'No .vi/.ctl files changed - nothing to diff.'
    exit 0
}

$Results   = [System.Collections.Generic.List[hashtable]]::new()
$Processed = 0
$Errors    = 0

# LabVIEWCLI prints operation output to stderr; relax ErrorActionPreference so that
# informational stderr is not treated as a terminating error. Each operation's
# success is judged by $LASTEXITCODE inside the loop.
$ErrorActionPreference = 'Continue'

foreach ($RelPath in $Files) {
    $RelPath  = $RelPath.Trim().TrimStart('/')
    $BasePath = Join-Path $BaseDir $RelPath
    $HeadPath = Join-Path $HeadDir $RelPath
    $SafeName = ($RelPath -replace '[/\\]','-') -replace '[^a-zA-Z0-9._-]','_'
    $OutDir   = Join-Path $ReportDir $SafeName
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    $BaseExists = Test-Path $BasePath
    $HeadExists = Test-Path $HeadPath
    $BaseIsVI   = Test-IsLabVIEWFile $BasePath
    $HeadIsVI   = Test-IsLabVIEWFile $HeadPath

    Write-Host "-- $RelPath (base=$BaseExists/$BaseIsVI head=$HeadExists/$HeadIsVI)"

    try {
        if ($BaseExists -and $BaseIsVI -and $HeadExists -and $HeadIsVI) {
            # Modified — single-step HTML comparison report.
            # -Headless is REQUIRED for LabVIEW 2026+ inside Windows containers.
            $HtmlOut = Join-Path $OutDir 'index.html'
            & $CliExe `
                -LogToConsole  TRUE `
                -OperationName CreateComparisonReport `
                -VI1           $BasePath `
                -VI2           $HeadPath `
                -ReportType    html `
                -ReportPath    $HtmlOut `
                -LabVIEWPath   $LabVIEWPath `
                -Headless
            if ($LASTEXITCODE -ne 0) { throw "CreateComparisonReport failed (exit $LASTEXITCODE)" }
            Add-OverlayFix $HtmlOut
            $Results.Add(@{File=$RelPath; Type='modified'; Html="$SafeName/index.html"})

        } elseif ($HeadExists -and $HeadIsVI) {
            # Added — snapshot of new file only
            $HtmlOut = Join-Path $OutDir 'index.html'
            & $CliExe `
                -OperationName                PrintToSingleFileHtml `
                -LabVIEWPath                  $LabVIEWPath `
                -AdditionalOperationDirectory $PrintToHtmlOp `
                -LogToConsole                 TRUE `
                -VI                           $HeadPath `
                -OutputPath                   $HtmlOut `
                -o -c `
                -Headless
            if ($LASTEXITCODE -ne 0) { throw "PrintToSingleFileHtml (added) failed (exit $LASTEXITCODE)" }
            $Results.Add(@{File=$RelPath; Type='added'; Html="$SafeName/index.html"})

        } elseif ($BaseExists -and $BaseIsVI) {
            # Deleted — snapshot of old file
            $HtmlOut = Join-Path $OutDir 'index.html'
            & $CliExe `
                -OperationName                PrintToSingleFileHtml `
                -LabVIEWPath                  $LabVIEWPath `
                -AdditionalOperationDirectory $PrintToHtmlOp `
                -LogToConsole                 TRUE `
                -VI                           $BasePath `
                -OutputPath                   $HtmlOut `
                -o -c `
                -Headless
            if ($LASTEXITCODE -ne 0) { throw "PrintToSingleFileHtml (deleted) failed (exit $LASTEXITCODE)" }
            $Results.Add(@{File=$RelPath; Type='deleted'; Html="$SafeName/index.html"})

        } else {
            Write-Host "  Skipping '$RelPath' - not a valid LabVIEW binary"
            continue
        }
        $Processed++
    } catch {
        Write-Warning "  ERROR processing ${RelPath}: $_"
        $Errors++
    }
}

Write-Host ""
Write-Host "=== VIDiff complete: $Processed processed, $Errors errors ==="

# ── Machine-readable manifest (consumed by the VI Browser to flag changed VIs) ─
function ConvertTo-JsonString([string]$s) { ($s -replace '\\', '\\') -replace '"', '\"' }
$fileEntries = $Results | ForEach-Object {
    '    {"file": "' + (ConvertTo-JsonString $_.File) + '", "type": "' + $_.Type +
    '", "report": "' + (ConvertTo-JsonString $_.Html) + '"}'
}
$ChangesJson = "{`n  `"platform`": `"windows`",`n  `"files`": [`n" + ($fileEntries -join ",`n") + "`n  ]`n}"
[System.IO.File]::WriteAllText((Join-Path $ReportDir 'changes.json'), $ChangesJson, [System.Text.UTF8Encoding]::new($false))

# ── Human-facing index page (system light/dark theme + change-type labels) ────
function Encode-Html([string]$s) { ($s -replace '&', '&amp;' -replace '<', '&lt;') -replace '>', '&gt;' }
$Rows = ($Results | ForEach-Object {
    $linktext = if ($_.Type -eq 'modified') { 'View diff report &rarr;' } else { 'View snapshot &rarr;' }
    "<tr><td><span class=`"badge $($_.Type)`">$($_.Type)</span></td>" +
    "<td class=`"file`">$(Encode-Html $_.File)</td>" +
    "<td><a href=`"$($_.Html)`">$linktext</a></td></tr>"
}) -join "`n"
if (-not $Rows) { $Rows = '<tr><td colspan="3" style="color:var(--fg-muted)">No comparable VI changes in this revision.</td></tr>' }

$IndexHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>VIDiff - LabVIEW-CI-with-Containers</title>
  <style>
    :root{--bg:#0d1117;--surface:#161b22;--border:#30363d;--fg:#e6edf3;--fg-muted:#8b949e;--link:#58a6ff;--row:#21262d;--hover:#1c2128}
    @media(prefers-color-scheme:light){:root{--bg:#fff;--surface:#f6f8fa;--border:#d0d7de;--fg:#1f2328;--fg-muted:#57606a;--link:#0969da;--row:#eaeef2;--hover:#f3f4f6}}
    *{box-sizing:border-box}
    body{margin:0;padding:24px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--fg)}
    h1{font-size:1.3em;margin:0 0 4px}
    .sub{color:var(--fg-muted);font-size:.85em;margin-bottom:18px}
    table{border-collapse:collapse;width:100%;background:var(--surface);border:1px solid var(--border);border-radius:8px;overflow:hidden}
    th{text-align:left;padding:9px 12px;border-bottom:1px solid var(--border);color:var(--fg-muted);font-size:.74em;text-transform:uppercase;letter-spacing:.04em}
    td{padding:9px 12px;border-bottom:1px solid var(--row);font-size:.9em;vertical-align:middle}
    tr:last-child td{border-bottom:none}
    tr:hover td{background:var(--hover)}
    a{color:var(--link);text-decoration:none}a:hover{text-decoration:underline}
    .badge{display:inline-block;padding:2px 9px;border-radius:20px;font-size:.7em;font-weight:600;color:#fff;text-transform:uppercase;letter-spacing:.03em}
    .modified{background:#9a6700}.added{background:#1a7f37}.deleted{background:#cf222e}
    .file{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.84em;word-break:break-all}
    .note{color:var(--fg-muted);font-size:.8em;margin-top:14px}
  </style>
</head>
<body>
  <h1>VIDiff - LabVIEW-CI-with-Containers</h1>
  <div class="sub">$Processed file(s) compared &nbsp;|&nbsp; $Errors error(s)</div>
  <table>
    <thead><tr><th>Change</th><th>VI</th><th>Report</th></tr></thead>
    <tbody>$Rows</tbody>
  </table>
  <p class="note"><strong>modified</strong> VIs show a true side-by-side diff. <strong>added</strong> / <strong>deleted</strong> VIs have no counterpart to compare, so a single-version snapshot is shown.</p>
</body>
</html>
"@

[System.IO.File]::WriteAllText((Join-Path $ReportDir 'index.html'), $IndexHtml, [System.Text.UTF8Encoding]::new($false))
Write-Host "Index -> $(Join-Path $ReportDir 'index.html')"

if ($Errors -gt 0) { exit 1 }
exit 0
