<#
.SYNOPSIS
    Runs LabVIEW VI Analyzer (Windows container) and generates an HTML report.

.PARAMETER WorkspaceRoot
    Absolute path to the project inside the container. Default: C:\workspace

.PARAMETER ReportDir
    Output directory for the XML results and HTML report.

.PARAMETER ConfigTemplate
    Path to the .viancfg template file (uses __WORKSPACE_PATH__ placeholder).
    Retained for backward compatibility; the built-in suite uses directory mode.

.PARAMETER LabVIEWPath
    Path to LabVIEW.exe inside the container.

.PARAMETER ConfigManifest
    Path to .github/labview-ci.yml. Its config.viAnalyzer section maps .viancfg
    test configurations to subsets of the project. Defaults to the file under
    $WorkspaceRoot. Absent / no viAnalyzer block -> the full built-in suite.

.PARAMETER FilesFilter
    Pipe-delimited list of repo-relative VI paths to analyze in isolation (the
    single-VI re-run). When set, only these VIs run, using -ConfigOverride.

.PARAMETER ConfigOverride
    Repo-relative path to a .viancfg used for the single-VI re-run (-FilesFilter).
#>
param(
    [string]$WorkspaceRoot   = 'C:\workspace',
    [string]$ReportDir       = 'C:\report',
    [string]$ConfigTemplate  = 'C:\workspace\.github\labview\via-configs\via-config-default.viancfg',
    [string]$LabVIEWPath     = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe',
    [string]$ConfigManifest  = '',
    [string]$FilesFilter     = '',
    [string]$ConfigOverride  = ''
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

# --- config.viAnalyzer support -------------------------------------------------
# Parse the viAnalyzer block of .github/labview-ci.yml (same flat format the
# Configure dialog / reconfigure workflow write). Returns @{ default; rules }.
function Read-ViaConfig([string]$ManifestPath) {
    $cfg = @{ default = ''; rules = @() }
    if (-not $ManifestPath -or -not (Test-Path -LiteralPath $ManifestPath)) { return $cfg }
    $lines = Get-Content -LiteralPath $ManifestPath
    $i = 0
    while ($i -lt $lines.Count -and $lines[$i] -notmatch '^\s{2}viAnalyzer:\s*$') { $i++ }
    if ($i -ge $lines.Count) { return $cfg }
    $i++
    $cur = $null; $inRules = $false
    for (; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s{0,3}\S') { break }
        if ($line -match '^\s{4}default:\s*"?([^"\s]+)"?') { $cfg.default = $Matches[1]; $inRules = $false; continue }
        if ($line -match '^\s{4}rules:\s*$') { $inRules = $true; continue }
        if ($inRules) {
            if ($line -match '^\s{6}-\s*config:\s*"?([^"]+?)"?\s*$') {
                $cur = @{ config = $Matches[1].Trim(); paths = @() }
                $cfg.rules += $cur
                continue
            }
            if ($null -ne $cur -and $line -match '^\s{8}paths:\s*"?([^"]*?)"?\s*$') {
                $cur.paths = @($Matches[1] -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                continue
            }
        }
    }
    return $cfg
}

# First .viancfg in the repo (excluding CI tooling) -> the pipeline's auto-default
# when the project committed a config but didn't pick one in the dialog.
function Get-FirstViancfg([string]$Root) {
    $found = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.viancfg' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](\.github|actions|ci-out|build)[\\/]' } |
        Sort-Object FullName)
    if ($found.Count -gt 0) {
        return ($found[0].FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/')
    }
    return ''
}

function ConvertTo-ContainerPath([string]$Root, [string]$Rel) {
    return (Join-Path $Root ($Rel -replace '/', '\'))
}

# Build a runtime .viancfg from a base config with <ItemsToAnalyze> rewritten to
# the given absolute item paths (so a config's TEST settings apply to a chosen
# subset). __WORKSPACE_PATH__ is also expanded.
function Build-ScopedConfig([string]$BaseConfigPath, [string[]]$ItemAbsPaths, [string]$OutPath, [string]$Workspace) {
    $xml = Get-Content -LiteralPath $BaseConfigPath -Raw
    $xml = $xml -replace '__WORKSPACE_PATH__', $Workspace
    $itemXml = ($ItemAbsPaths | ForEach-Object {
        "`t`t<Item>`r`n`t`t`t<Path>`"$_`"</Path>`r`n`t`t`t<Removed>FALSE</Removed>`r`n`t`t</Item>"
    }) -join "`r`n"
    $block = "<ItemsToAnalyze>`r`n$itemXml`r`n`t</ItemsToAnalyze>"
    $rx = [regex]'(?s)<ItemsToAnalyze>.*?</ItemsToAnalyze>'
    if ($rx.IsMatch($xml)) {
        $xml = $rx.Replace($xml, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $block }, 1)
    } else {
        $xml = $xml -replace '</Config>', ($block + "`r`n</Config>")
    }
    [System.IO.File]::WriteAllText($OutPath, $xml, [System.Text.UTF8Encoding]::new($false))
}

# Minimal JSON string encoder (PowerShell's ConvertTo-Json collapses single-element
# arrays, which would corrupt passes[]/paths[]; we build the manifest by hand).
function ConvertTo-JsonString([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        switch ($ch) {
            '"'  { [void]$sb.Append('\"') }
            '\'  { [void]$sb.Append('\\') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            default {
                if ([int]$ch -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    return '"' + $sb.ToString() + '"'
}

function Invoke-ViaPass([string]$ConfigArg, [string]$ReportPath) {
    Write-Host "  RunVIAnalyzer -ConfigPath '$ConfigArg' -ReportPath '$ReportPath'"
    & $CliExe `
        -LogToConsole   TRUE `
        -OperationName  RunVIAnalyzer `
        -ConfigPath     $ConfigArg `
        -ReportPath     $ReportPath `
        -ReportSaveType HTML `
        -LabVIEWPath    $LabVIEWPath `
        -Headless
    return $LASTEXITCODE
}

function Write-PlaceholderReport([string]$Path, [string]$Message) {
    $html = '<html><body><table>' +
        '<tr><td>VIs Analyzed</td><td>0</td></tr>' +
        '<tr><td>Total Tests Run</td><td>0</td></tr>' +
        '<tr><td>Passed Tests</td><td>0</td></tr>' +
        '<tr><td>Failed Tests</td><td>0</td></tr></table>' +
        '<a name="fail"></a><p>' + $Message + '</p></body></html>'
    [System.IO.File]::WriteAllText($Path, $html, [System.Text.UTF8Encoding]::new($false))
}

$LabVIEWPath = Resolve-LabVIEWPath $LabVIEWPath
$CliExe   = Resolve-LabVIEWCLI $LabVIEWPath
$HtmlOut  = Join-Path $ReportDir 'index.html'
$PassesDir = Join-Path $ReportDir 'passes'
if (-not $ConfigManifest) { $ConfigManifest = Join-Path $WorkspaceRoot '.github\labview-ci.yml' }

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

Write-Host "=== VI Analyzer (Windows) ==="
Write-Host "  Workspace  : $WorkspaceRoot"
Write-Host "  LabVIEW    : $LabVIEWPath"

# --- Build the analysis plan from config.viAnalyzer ---------------------------
# Each "pass" runs RunVIAnalyzer with one configuration over one scope; the
# friendly-report builder then merges them. With no configuration this collapses
# to a SINGLE directory-mode pass = the historical full-default-suite behavior:
# passing the workspace DIRECTORY as -ConfigPath makes LabVIEWCLI run the FULL
# DEFAULT VI Analyzer test set over every VI under it (the invocation that
# produced the historical working reports). A rule instead applies a committed
# .viancfg's tests to a chosen subset (its <ItemsToAnalyze> is rewritten to the
# scope); the built-in suite still uses directory mode so it never regresses to a
# .viancfg with an empty <TestConfigData> (which would run ZERO tests).
$filterList = @()
if (-not $FilesFilter -and $env:VIA_FILES) { $FilesFilter = $env:VIA_FILES }
if (-not $ConfigOverride -and $env:VIA_CONFIG) { $ConfigOverride = $env:VIA_CONFIG }
if ($FilesFilter) { $filterList = @($FilesFilter -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

$passes = @()
$singleMode = $false

if ($filterList.Count -gt 0) {
    # Single-VI re-run with a chosen .viancfg (the "Re-run" action on a report).
    if (-not $ConfigOverride) { throw "A single-VI re-run (-FilesFilter) requires -ConfigOverride (a .viancfg)." }
    $abs = @($filterList | ForEach-Object { ConvertTo-ContainerPath $WorkspaceRoot $_ })
    $scoped = Join-Path $ReportDir 'via-rerun.viancfg'
    Build-ScopedConfig (ConvertTo-ContainerPath $WorkspaceRoot $ConfigOverride) $abs $scoped $WorkspaceRoot
    $passes = @(@{ kind = 'rule'; config = $ConfigOverride; label = $ConfigOverride; paths = $filterList; configArg = $scoped; report = $HtmlOut })
    $singleMode = $true
    Write-Host "  Mode       : single-VI re-run ($($filterList.Count) VI) with $ConfigOverride"
} else {
    $via = Read-ViaConfig $ConfigManifest
    $def = $via.default
    if (-not $def) {
        $auto = Get-FirstViancfg $WorkspaceRoot
        if ($auto) { $def = $auto; Write-Host "  Auto-detected default config: $auto" } else { $def = 'builtin' }
    }
    $rules = @($via.rules)
    if ($def -eq 'builtin' -and $rules.Count -eq 0) {
        $passes = @(@{ kind = 'default'; config = 'builtin'; label = 'Built-in full test suite'; paths = @(); configArg = $WorkspaceRoot; report = $HtmlOut })
        $singleMode = $true
        Write-Host "  Mode       : full built-in suite (analyze workspace directory)"
    } else {
        Write-Host "  Mode       : multi-configuration (default=$def, rules=$($rules.Count))"
        New-Item -ItemType Directory -Force -Path $PassesDir | Out-Null
        $idx = 0
        foreach ($r in $rules) {
            if ($r.config -eq 'none') {
                $passes += @{ kind = 'exclude'; config = 'none'; label = 'Excluded (not tested)'; paths = $r.paths; configArg = $null; report = $null }
            } else {
                $abs = @($r.paths | ForEach-Object { ConvertTo-ContainerPath $WorkspaceRoot $_ })
                $scoped = Join-Path $PassesDir ("rule{0}.viancfg" -f $idx)
                Build-ScopedConfig (ConvertTo-ContainerPath $WorkspaceRoot $r.config) $abs $scoped $WorkspaceRoot
                $passes += @{ kind = 'rule'; config = $r.config; label = $r.config; paths = $r.paths; configArg = $scoped; report = ("rule{0}.html" -f $idx) }
                $idx++
            }
        }
        if ($def -eq 'builtin') {
            $passes += @{ kind = 'default'; config = 'builtin'; label = 'Built-in full test suite'; paths = @(); configArg = $WorkspaceRoot; report = 'default.html' }
        } elseif ($def -ne 'none') {
            $scoped = Join-Path $PassesDir 'default.viancfg'
            Build-ScopedConfig (ConvertTo-ContainerPath $WorkspaceRoot $def) @($WorkspaceRoot) $scoped $WorkspaceRoot
            $passes += @{ kind = 'default'; config = $def; label = $def; paths = @(); configArg = $scoped; report = 'default.html' }
        }
    }
}
Write-Host ""

# ── Recompile the workspace to this image's LabVIEW version BEFORE analyzing ──
# The VI Analyzer only analyzes VIs already saved in the running LabVIEW's
# version; VIs saved in an OLDER version (e.g. the LV2019 example project) are
# silently skipped, producing an empty "0 VIs analyzed" report even though the
# VIs load fine. A headless MassCompile pass mutates every VI in the workspace up
# to the current version in place, so the following RunVIAnalyzer sees and
# analyzes them. Best-effort: a non-zero MassCompile exit (e.g. one library VI
# that can't compile against the CI image) must not block analysis — we relax
# ErrorActionPreference, log the exit code, and continue regardless.
Write-Host "=== Pre-analysis MassCompile (upgrade VIs to image LabVIEW version) ==="
$preStart = Get-Date
$prevEAP  = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $CliExe `
        -LogToConsole       TRUE `
        -OperationName      MassCompile `
        -DirectoryToCompile $WorkspaceRoot `
        -LabVIEWPath        $LabVIEWPath `
        -Headless 2>&1 | Out-Host
    Write-Host ("  MassCompile exit={0} duration={1}s" -f $LASTEXITCODE, [math]::Round(((Get-Date) - $preStart).TotalSeconds, 1))
} catch {
    Write-Warning "  Pre-analysis MassCompile skipped: $($_.Exception.Message)"
}
$ErrorActionPreference = $prevEAP
Write-Host ""

$Start = Get-Date

# --- Run each analysis pass ---------------------------------------------------
# -ReportSaveType HTML writes the native, richly formatted report; the friendly-
# report step parses it (and merges passes for a multi-configuration run).
# -Headless is REQUIRED for LabVIEW 2026+ in Windows containers, otherwise
# LabVIEWCLI cannot establish a VI Server connection (error -350000).
$overallExit = 0
$ran = 0
foreach ($p in $passes) {
    if ($p.kind -eq 'exclude') {
        Write-Host "=== Excluded (not tested): $($p.paths -join ', ') ==="
        continue
    }
    $reportPath = if ($singleMode) { $p.report } else { (Join-Path $PassesDir $p.report) }
    Write-Host "=== VI Analyzer pass: $($p.label) ==="
    $ec = Invoke-ViaPass $p.configArg $reportPath
    $ran++
    Write-Host "  pass exit=$ec"
    if ($ec -ne 0 -and $ec -ne 3 -and $overallExit -eq 0) { $overallExit = $ec }
}

$Duration = [math]::Round(((Get-Date) - $Start).TotalSeconds, 1)
Write-Host ""
Write-Host "=== VI Analyzer finished ($ran pass(es), duration=${Duration}s) ==="

if ($singleMode) {
    if (Test-Path $HtmlOut) {
        $size = (Get-Item $HtmlOut).Length
        Write-Host "Native VI Analyzer report -> $HtmlOut ($size bytes)"
    } else {
        Write-Warning "No VI Analyzer report was generated at $HtmlOut"
    }
} elseif ($ran -eq 0) {
    # Nothing was configured to analyze (e.g. default = none with no rules).
    Write-PlaceholderReport $HtmlOut 'No VIs are configured for analysis (default = none and no rules matched).'
    Write-Host "No analysis passes ran; wrote a placeholder report."
} else {
    # Emit passes/manifest.json for the friendly-report builder to merge. Built by
    # hand because ConvertTo-Json collapses single-element passes[]/paths[] arrays.
    $entries = foreach ($p in $passes) {
        $parts = @()
        $parts += '"kind":' + (ConvertTo-JsonString $p.kind)
        $parts += '"config":' + (ConvertTo-JsonString $p.config)
        $parts += '"label":' + (ConvertTo-JsonString $p.label)
        $pathsJson = @($p.paths | ForEach-Object { ConvertTo-JsonString $_ }) -join ','
        $parts += '"paths":[' + $pathsJson + ']'
        if ($p.report) { $parts += '"report":' + (ConvertTo-JsonString $p.report) }
        '{' + ($parts -join ',') + '}'
    }
    $json = '{"passes":[' + ($entries -join ',') + ']}'
    [System.IO.File]::WriteAllText((Join-Path $PassesDir 'manifest.json'), $json, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Wrote $($passes.Count) pass(es) -> $(Join-Path $PassesDir 'manifest.json')"
}

# Exit code 3 = analysis ran but found rule failures -> success (failures are in
# the report). Any other non-zero from a pass is a real error.
if ($overallExit -ne 0) {
    exit $overallExit
}
exit 0
