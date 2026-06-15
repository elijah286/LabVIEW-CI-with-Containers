<#
.SYNOPSIS
    Renders a worklist of VIs to content-addressed HTML snapshots inside a
    LabVIEW Windows container.

.DESCRIPTION
    Each line of the worklist is "<blobsha>`t<vi_rel_path>". For each entry the
    VI is rendered (front panel + block diagram) to:

        <OutByBlobDir>\<ab>\<blobsha>.html

    Snapshots are content-addressed by the file's git blob SHA, so a snapshot is
    only produced once per unique VI content. Entries whose output already exists
    are skipped. A failed render writes a small placeholder so the gallery never
    links to a missing file.

.PARAMETER WorkspaceRoot
    Root of the checked-out commit tree to read VIs from (a git worktree mount).

.PARAMETER OpsDir
    Directory that contains the PrintToSingleFileHtml LabVIEWCLI operation
    (i.e. the repo's .github\labview folder). Passed as
    -AdditionalOperationDirectory.

.PARAMETER OutByBlobDir
    Root of the content-addressed snapshot store (…\vi-snapshots\by-blob).

.PARAMETER WorkListPath
    TSV worklist file: "<blobsha>`t<vi_rel_path>" per line.

.PARAMETER LabVIEWPath
    Optional explicit path to LabVIEW.exe. Auto-discovered when blank.
#>
param(
    [string]$WorkspaceRoot = 'C:\workspace',
    [string]$OpsDir        = 'C:\ops',
    [string]$OutByBlobDir  = 'C:\out\by-blob',
    [string]$WorkListPath  = 'C:\out\worklist.tsv',
    [string]$LabVIEWPath   = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Resolve-LabVIEWPath([string]$PreferredPath) {
    if ($PreferredPath -and (Test-Path $PreferredPath)) { return $PreferredPath }
    $candidates = @(Get-ChildItem 'C:\Program Files\National Instruments' -Directory -Filter 'LabVIEW *' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'LabVIEW.exe' } |
        Where-Object { Test-Path $_ })
    if ($candidates.Count -gt 0) { return $candidates[0] }
    throw "LabVIEW.exe not found. Checked '$PreferredPath' and C:\Program Files\National Instruments\LabVIEW *"
}

function Resolve-LabVIEWCLI([string]$LabVIEWExePath) {
    $cliCmd = Get-Command LabVIEWCLI.exe -ErrorAction SilentlyContinue
    if ($null -eq $cliCmd) { $cliCmd = Get-Command LabVIEWCLI -ErrorAction SilentlyContinue }
    if ($null -ne $cliCmd -and $cliCmd.Source) { return $cliCmd.Source }
    $candidate = Join-Path (Split-Path $LabVIEWExePath) 'LabVIEWCLI.exe'
    if (Test-Path $candidate) { return $candidate }
    throw "LabVIEWCLI not found on PATH and not beside LabVIEW.exe ('$candidate')."
}

function Write-Placeholder([string]$Path, [string]$Rel, [string]$Reason) {
    $dir = Split-Path $Path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $safeRel    = $Rel    -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
    $safeReason = $Reason -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
    $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8">
<title>Snapshot unavailable</title>
<style>body{margin:0;padding:24px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0d1117;color:#e6edf3}
.card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:20px;max-width:680px}
h1{font-size:1.1em;margin:0 0 8px}.muted{color:#8b949e;font-size:.85em}</style></head>
<body><div class="card"><h1>Snapshot unavailable</h1>
<div class="muted">$safeRel</div><p class="muted">$safeReason</p></div></body></html>
"@
    [System.IO.File]::WriteAllText($Path, $html, [System.Text.UTF8Encoding]::new($false))
}

$ResolvedLV = Resolve-LabVIEWPath $LabVIEWPath
$CliExe     = Resolve-LabVIEWCLI $ResolvedLV

# OpsDir must contain the PrintToSingleFileHtml operation class.
$OpClass = Join-Path $OpsDir 'PrintToSingleFileHtml'
if (-not (Test-Path $OpClass)) {
    Write-Error "PrintToSingleFileHtml operation not found under '$OpsDir'."
    exit 1
}

Write-Host "=== Render VI Snapshots ==="
Write-Host "  Workspace : $WorkspaceRoot"
Write-Host "  LabVIEW   : $ResolvedLV"
Write-Host "  CLI       : $CliExe"
Write-Host "  Ops       : $OpsDir"
Write-Host "  Out       : $OutByBlobDir"

if (-not (Test-Path $WorkListPath)) {
    Write-Host "  Worklist is empty - nothing to render."
    exit 0
}

$lines = Get-Content $WorkListPath | Where-Object { $_.Trim() -ne '' }
Write-Host "  Worklist  : $($lines.Count) VI(s)"
Write-Host ""

$Rendered = 0; $Skipped = 0; $Errors = 0

# LabVIEWCLI prints operation output to stderr; relax ErrorActionPreference for the
# render loop so informational stderr is not treated as a terminating error. Each
# render's success is judged by $LASTEXITCODE and whether the output file exists.
$ErrorActionPreference = 'Continue'

foreach ($line in $lines) {
    $parts = $line -split "`t", 2
    if ($parts.Count -ne 2) { continue }
    $blob = $parts[0].Trim()
    $rel  = $parts[1].Trim()
    if ($blob.Length -lt 2 -or $rel -eq '') { continue }

    $OutDir  = Join-Path $OutByBlobDir $blob.Substring(0, 2)
    $OutFile = Join-Path $OutDir ($blob + '.html')
    if (Test-Path $OutFile) { $Skipped++; continue }

    $ViPath = Join-Path $WorkspaceRoot ($rel -replace '/', '\')
    if (-not (Test-Path $ViPath)) {
        Write-Warning "  MISSING: $rel"
        Write-Placeholder -Path $OutFile -Rel $rel -Reason 'VI file not found in commit tree.'
        $Errors++
        continue
    }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    try {
        # -Headless is REQUIRED for LabVIEW 2026+ inside Windows containers.
        & $CliExe `
            -OperationName                PrintToSingleFileHtml `
            -LabVIEWPath                  $ResolvedLV `
            -AdditionalOperationDirectory $OpsDir `
            -LogToConsole                 TRUE `
            -VI                           $ViPath `
            -OutputPath                   $OutFile `
            -o -c `
            -Headless
        if ($LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
        if (-not (Test-Path $OutFile)) { throw 'no output produced' }
        Write-Host "  OK: $rel"
        $Rendered++
    } catch {
        Write-Warning "  ERROR: $rel - $_"
        Write-Placeholder -Path $OutFile -Rel $rel -Reason "Render failed: $_"
        $Errors++
    }
}

Write-Host ""
Write-Host "=== Render complete: $Rendered rendered, $Skipped skipped, $Errors errors ==="
# Partial galleries are acceptable; the orchestrator decides the commit status.
exit 0
