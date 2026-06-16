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

# ── Select the FULL default VI Analyzer test suite ───────────────────────────
# The native VI Analyzer requires <TestConfigData> to explicitly enumerate every
# test to run; an EMPTY <TestConfigData> makes LabVIEW run ZERO tests and report a
# misleading "VIs Analyzed 1 / Total Tests Run 0" (the empty-report bug). The full
# default suite (~90 tests) ships as test libraries (*.llb) with the VI Analyzer
# Toolkit, but their location varies by LabVIEW version (historically
# <LV>\project\_VI Analyzer\_tests; newer builds put them under vi.lib). So probe
# the known locations, then fall back to a scoped search for any test library
# whose path contains "_VI Analyzer", and select them all. Best-effort: on any
# failure (or none found) we keep the known-good fallback tests already committed
# in the config template, so the report is never empty.
try {
    $lvDir = (Split-Path $LabVIEWPath).TrimEnd('\', '/')

    # Fast path: probe known layouts (newest-style locations included).
    $testsRoot = $null
    $llbs      = @()
    $candidates = @(
        'project\_VI Analyzer\_tests',
        'vi.lib\addons\_VI Analyzer\_tests',
        'vi.lib\addons\analyzer\_tests',
        'resource\Framework\Providers\VIAnalyzer\_tests'
    ) | ForEach-Object { Join-Path $lvDir $_ }
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $llbs = @(Get-ChildItem -LiteralPath $c -Recurse -Filter '*.llb' -File -ErrorAction SilentlyContinue)
            if ($llbs.Count -gt 0) { $testsRoot = $c; break }
        }
    }

    # Fallback: scoped recursive search for *.llb whose path mentions the VI
    # Analyzer (flexible: "_VI Analyzer", "VI Analyzer", "VIAnalyzer", "analyzer").
    # Scoped first to the dirs that can hold add-on libraries; the *.llb filter is
    # applied by the filesystem so this is bounded.
    if ($llbs.Count -eq 0) {
        foreach ($r in @('vi.lib', 'project', 'resource')) {
            $base = Join-Path $lvDir $r
            if (-not (Test-Path $base)) { continue }
            $hits = @(Get-ChildItem -LiteralPath $base -Recurse -Filter '*.llb' -File -ErrorAction SilentlyContinue |
                      Where-Object { $_.FullName -match 'analy' })
            if ($hits.Count -gt 0) { $llbs = $hits; $testsRoot = $base; break }
        }
    }

    # Last resort: search the WHOLE LabVIEW dir for analyzer test libraries. Only
    # reached when the scoped probes all miss, so the one-time full walk is worth it.
    if ($llbs.Count -eq 0) {
        $hits = @(Get-ChildItem -LiteralPath $lvDir -Recurse -Filter '*.llb' -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.FullName -match 'analy' })
        if ($hits.Count -gt 0) { $llbs = $hits; $testsRoot = $lvDir }
    }

    if ($llbs.Count -gt 0) {
        # [char]34 is a double-quote, sourced as a variable so the XML lines below
        # need no literal or escaped quotes (kept pure-ASCII and free of
        # backtick-quote escaping, which keeps the PowerShell parser unambiguous).
        $q  = [char]34
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('<TestConfigData>')
        foreach ($llb in ($llbs | Sort-Object FullName)) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($llb.Name)
            # RelativePath is resolved by VIA against BasePath "LabVIEW" (the LabVIEW
            # program dir), so emit each test path relative to $lvDir regardless of
            # whether the suite lives under project\ or vi.lib\.
            $rel  = $llb.FullName.Substring($lvDir.Length).TrimStart('\', '/').Replace('\', '/')
            [void]$sb.AppendLine("`t`t<Test>")
            [void]$sb.AppendLine("`t`t`t<Name>${q}$name${q}</Name>")
            [void]$sb.AppendLine("`t`t`t<Ranking>1</Ranking>")
            [void]$sb.AppendLine("`t`t`t<MaxFailures>1000</MaxFailures>")
            [void]$sb.AppendLine("`t`t`t<BasePath>${q}LabVIEW${q}</BasePath>")
            [void]$sb.AppendLine("`t`t`t<RelativePath>${q}$rel${q}</RelativePath>")
            [void]$sb.AppendLine("`t`t`t<Selected>TRUE</Selected>")
            [void]$sb.AppendLine("`t`t`t<Controls>")
            [void]$sb.AppendLine("`t`t`t</Controls>")
            [void]$sb.AppendLine("`t`t</Test>")
        }
        [void]$sb.Append("`t</TestConfigData>")
        $newBlock = $sb.ToString()

        # Replace the template's <TestConfigData>...</TestConfigData> wholesale
        # (substring, not regex, to avoid metacharacter pitfalls in test paths).
        $startTag = '<TestConfigData>'
        $endTag   = '</TestConfigData>'
        $si = $ConfigXml.IndexOf($startTag)
        $ei = $ConfigXml.IndexOf($endTag)
        if ($si -ge 0 -and $ei -gt $si) {
            $ConfigXml = $ConfigXml.Substring(0, $si) + $newBlock + $ConfigXml.Substring($ei + $endTag.Length)
            Write-Host ("  Test suite : selected {0} tests from {1}" -f $llbs.Count, $testsRoot)
        } else {
            Write-Warning "  Test suite : could not locate <TestConfigData> in template - using committed fallback tests"
        }
    } else {
        Write-Warning "  Test suite : no VI Analyzer test libraries found under LabVIEW - using committed fallback tests"
        # Comprehensive diagnostic (only on the not-found path): reveal the real
        # layout so the correct test location can be wired into the probe list.
        try {
            Write-Host "  Test suite : (diag) top-level of $lvDir :"
            Get-ChildItem -LiteralPath $lvDir -Force -ErrorAction SilentlyContinue |
                Select-Object -First 60 |
                ForEach-Object { Write-Host ("      [{0}] {1}" -f ($(if ($_.PSIsContainer) { 'D' } else { 'F' })), $_.Name) }

            $allLlb = @(Get-ChildItem -LiteralPath $lvDir -Recurse -Filter '*.llb' -File -ErrorAction SilentlyContinue)
            Write-Host ("  Test suite : (diag) total *.llb under LabVIEW = {0}; first 25:" -f $allLlb.Count)
            $allLlb | Select-Object -First 25 | ForEach-Object { Write-Host ("      {0}" -f $_.FullName) }

            Write-Host "  Test suite : (diag) paths matching 'analy' (first 30):"
            Get-ChildItem -LiteralPath $lvDir -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'analy' } |
                Select-Object -First 30 |
                ForEach-Object { Write-Host ("      {0}" -f $_.FullName) }
        } catch {
            Write-Host ("  Test suite : (diag) listing failed: " + $_.Exception.Message)
        }
    }
} catch {
    Write-Warning ("  Test suite enumeration failed (" + $_.Exception.Message + ") - using committed fallback tests")
}

[System.IO.File]::WriteAllText($ConfigFile, $ConfigXml, [System.Text.UTF8Encoding]::new($false))
Write-Host "  Config out : $ConfigFile"
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
