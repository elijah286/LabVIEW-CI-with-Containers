<#
.SYNOPSIS
    Generates LabVIEW project documentation with Antidoc (Wovalab) inside the CI
    container, then writes summary.json and a safety-net index.html so the
    dashboard always has something to link to.

.DESCRIPTION
    Antidoc is distributed only through VIPM (package wovalab_lib_antidoc_cli) and
    is baked into the custom CI worker image (Configure -> "Use Antidoc"). The CLI
    runs through g-cli (the Wiresmith g-cli launcher, an Antidoc dependency) and
    emits an AsciiDoc document plus its diagram assets. This script locates g-cli
    and the project, runs the Antidoc CLI headlessly, captures the output, and
    ALWAYS emits an index.html so the dashboard never links to a 404 -- mirroring
    run-vi-analyzer.ps1 / masscompile.ps1.

    The friendly, navigable report (which embeds / renders the generated docs) is
    built afterwards on the runner host by build-antidoc-report.py; this script
    only needs to produce the raw documentation, a machine-readable summary.json,
    and a basic fallback page.

.PARAMETER WorkspaceRoot
    Absolute path inside the container to the project root.
    Default: C:\workspace (the GitHub Actions volume mount point).

.PARAMETER ReportDir
    Directory to write the documentation (under .\doc), antidoc.log, summary.json
    and index.html into.

.PARAMETER LabVIEWPath
    Path to LabVIEW.exe inside the container. Its year drives g-cli --lv-ver.

.PARAMETER ProjectPath
    Optional explicit .lvproj to document. When empty the script auto-detects a
    single .lvproj at the workspace root, else the first project found anywhere
    (excluding the .github tooling and ci-out output).

.PARAMETER Title
    Optional document title. Defaults to the repository name (GITHUB_REPOSITORY)
    or the project file name.
#>
param(
    [string]$WorkspaceRoot = 'C:\workspace',
    [string]$ReportDir     = 'C:\report',
    [string]$LabVIEWPath   = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe',
    [string]$ProjectPath   = '',
    [string]$Title         = ''
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

  # Documentation generation must never hard-crash the job before it can emit a
  # report; an empty result is handled (and surfaced) by the caller.
  return $PreferredPath
}

function Resolve-LabVIEWYear([string]$LvPath) {
  if ($LvPath -and ($LvPath -match 'LabVIEW\s+(\d{4})')) { return $Matches[1] }
  if ($env:LABVIEW_VERSION) { return $env:LABVIEW_VERSION }
  return '2026'
}

function Sync-PathFromRegistry {
  # The g-cli installer (and other VIPM-installed CLIs) add their directory to the
  # MACHINE PATH in the registry at install time. A Windows container's process
  # PATH, however, is baked from the image ENV layer at build time and does NOT
  # pick up that registry change -- the g-cli docs note you must "restart any
  # terminals or build agents after install to include the new path variable".
  # Re-read the persisted PATH from the registry and merge in anything missing so
  # Get-Command can see a freshly-baked g-cli without an image rebuild. Best-effort:
  # a failure here must never crash doc-gen before it can emit a report.
  try {
    $regPaths = @()
    $machine = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name 'Path' -ErrorAction SilentlyContinue).Path
    $user    = (Get-ItemProperty -Path 'HKCU:\Environment' -Name 'Path' -ErrorAction SilentlyContinue).Path
    foreach ($raw in @($machine, $user)) {
      if ($raw) { $regPaths += [System.Environment]::ExpandEnvironmentVariables($raw) }
    }
    $current = @($env:Path -split ';')
    foreach ($entry in (($regPaths -join ';') -split ';')) {
      $e = $entry.Trim()
      if ($e -and ($current -notcontains $e)) {
        $env:Path = $env:Path.TrimEnd(';') + ';' + $e
        $current += $e
      }
    }
  } catch {
    Write-Host "  (PATH refresh from registry skipped: $($_.Exception.Message))"
  }
}

function Resolve-GCli {
  # Antidoc CLI runs through g-cli (wiresmith_technology_lib_g_cli). The installer
  # adds g-cli to the machine PATH in the registry, so refresh the process PATH from
  # the registry first (a Windows container does not inherit that change), then try
  # PATH, then the known install locations, then a bounded recursive search.
  Sync-PathFromRegistry

  $cmd = Get-Command 'g-cli.exe' -ErrorAction SilentlyContinue
  if ($null -eq $cmd) { $cmd = Get-Command 'g-cli' -ErrorAction SilentlyContinue }
  if ($null -ne $cmd -and $cmd.Source) { return $cmd.Source }

  $pf  = ${env:ProgramFiles};      if (-not $pf)  { $pf  = 'C:\Program Files' }
  $pfx = ${env:ProgramFiles(x86)}; if (-not $pfx) { $pfx = 'C:\Program Files (x86)' }

  # g-cli has shipped under a few folder names ("G CLI" with a space from the
  # Wiresmith/NI installers, "G-CLI" with a hyphen historically); check both, in
  # both Program Files roots and the NI Shared area.
  $candidates = @(
    (Join-Path $pf  'National Instruments\Shared\G CLI\g-cli.exe'),
    (Join-Path $pfx 'National Instruments\Shared\G CLI\g-cli.exe'),
    (Join-Path $pf  'Wiresmith Technology\G CLI\g-cli.exe'),
    (Join-Path $pfx 'Wiresmith Technology\G CLI\g-cli.exe'),
    (Join-Path $pf  'G CLI\g-cli.exe'),
    (Join-Path $pfx 'G CLI\g-cli.exe'),
    (Join-Path $pf  'National Instruments\G-CLI\g-cli.exe'),
    (Join-Path $pfx 'National Instruments\G-CLI\g-cli.exe'),
    (Join-Path $pf  'G-CLI\g-cli.exe'),
    (Join-Path $pfx 'G-CLI\g-cli.exe')
  )
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }

  # Last resort: a bounded recursive search of the common install roots. -Depth
  # keeps this from walking the entire drive while still covering nested vendor
  # folders (e.g. Program Files\National Instruments\Shared\G CLI\).
  foreach ($root in @($pf, $pfx)) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    try {
      $hit = Get-ChildItem -LiteralPath $root -Filter 'g-cli.exe' -File -Recurse -Depth 5 -ErrorAction SilentlyContinue |
        Select-Object -First 1
      if ($hit) { return $hit.FullName }
    } catch { }
  }
  return ''
}

function Find-Project([string]$Root, [string]$Explicit) {
  if ($Explicit -and (Test-Path $Explicit)) { return (Resolve-Path $Explicit).Path }

  # Prefer a .lvproj sitting at the workspace root (the usual project layout).
  $rootProj = @(Get-ChildItem -LiteralPath $Root -File -Filter '*.lvproj' -ErrorAction SilentlyContinue |
    Sort-Object Name)
  if ($rootProj.Count -gt 0) { return $rootProj[0].FullName }

  # Else the first project found anywhere, skipping the CI tooling + output.
  $any = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.lvproj' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '(?i)\\\.github\\' -and $_.FullName -notmatch '(?i)\\ci-out\\' } |
    Sort-Object FullName)
  if ($any.Count -gt 0) { return $any[0].FullName }
  return ''
}

function ConvertTo-RepoRelative([string]$Full, [string]$Base) {
  if (-not $Full) { return '' }
  $b = ($Base.TrimEnd('\') + '\')
  if ($Full.ToLowerInvariant().StartsWith($b.ToLowerInvariant())) {
    return $Full.Substring($b.Length).Replace('\', '/')
  }
  return (Split-Path $Full -Leaf)
}

$LabVIEWPath = Resolve-LabVIEWPath $LabVIEWPath
$LvYear      = Resolve-LabVIEWYear $LabVIEWPath
$GCli        = Resolve-GCli
$Project     = Find-Project $WorkspaceRoot $ProjectPath

$DocDir   = Join-Path $ReportDir 'doc'
$LogFile  = Join-Path $ReportDir 'antidoc.log'
$HtmlOut  = Join-Path $ReportDir 'index.html'
$MetaFile = Join-Path $ReportDir 'antidoc-meta.json'

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
New-Item -ItemType Directory -Force -Path $DocDir    | Out-Null

if (-not $Title) {
  if ($env:GITHUB_REPOSITORY) { $Title = ($env:GITHUB_REPOSITORY -split '/')[-1] }
  elseif ($Project)           { $Title = [System.IO.Path]::GetFileNameWithoutExtension($Project) }
  else                        { $Title = 'LabVIEW Project' }
}

Write-Host "=== Antidoc ==="
Write-Host "  Workspace : $WorkspaceRoot"
Write-Host "  Project   : $Project"
Write-Host "  Title     : $Title"
Write-Host "  Output    : $DocDir"
Write-Host "  g-cli     : $GCli"
Write-Host "  LabVIEW   : $LabVIEWPath ($LvYear)"
Write-Host ""

# Start the log fresh so the report builder always finds a file.
Set-Content -Path $LogFile -Value "Antidoc run started $(Get-Date -Format o)" -Encoding UTF8

$Start    = Get-Date
$ExitCode = 0

if (-not $GCli) {
  $msg = 'ERROR: g-cli was not found in the worker image (searched the refreshed PATH, the registry PATH, and the common install locations). Antidoc runs through g-cli (wiresmith_technology_lib_g_cli), which installs as a dependency of the Antidoc CLI. Enable "Use Antidoc" in Configure so the Antidoc VIPC is baked into the worker image, and confirm the image has been rebuilt since.'
  Write-Warning $msg
  Add-Content -Path $LogFile -Value $msg
  $ExitCode = 9
}
elseif (-not $Project) {
  $msg = "ERROR: No .lvproj found under $WorkspaceRoot. Antidoc documents a LabVIEW project; add one to the repository or pass -ProjectPath."
  Write-Warning $msg
  Add-Content -Path $LogFile -Value $msg
  $ExitCode = 8
}
else {
  # LabVIEWCLI/g-cli print operation output to stderr; relax ErrorActionPreference
  # so merging it with 2>&1 does not raise a terminating NativeCommandError. Judge
  # success by the real $LASTEXITCODE plus whether a document was produced.
  $prevEAP = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'

  # The Antidoc CLI registers a g-cli tool named 'antidoc' (renamed from the v1
  # 'antidoccli'; the modern package installs antidoc.vi, so calling 'antidoccli'
  # fails with "VI to launch does not exist: antidoccli.vi"). Everything after '--'
  # is passed to Antidoc:  -addon lvproj (document a LabVIEW project -- the add-on
  # is mandatory and is baked into the worker image alongside the CLI)  -pp <project>
  # -t <title>  -out <output directory>. If a future Antidoc CLI renames these
  # flags, adjust them here -- the rest of the pipeline keys off whatever files land
  # in $DocDir, not the exact command line.
  #
  # --timeout bounds ONLY the launch handshake (how long g-cli waits for LabVIEW to
  # connect back), not the doc-gen itself. g-cli defaults to 60s, but a cold worker
  # container has to launch LabVIEW AND load Antidoc's large VI hierarchy before the
  # tool can connect, which routinely exceeds 60s -> "No connection established with
  # application / Timed out waiting for app to connect to g-cli". Give it 10 minutes
  # so a cold start never trips the handshake; override with ANTIDOC_CONNECT_TIMEOUT_MS.
  $ConnectTimeoutMs = if ($env:ANTIDOC_CONNECT_TIMEOUT_MS) { $env:ANTIDOC_CONNECT_TIMEOUT_MS } else { '600000' }

  # THE fix for "No connection established / Timed out waiting for app to connect":
  # g-cli launches LabVIEW.exe DIRECTLY (not via `LabVIEWCLI -Headless`). In NI's
  # official LabVIEW container (2026 Q1+), a direct launch without headless mode
  # comes up at the ACTIVATION WIZARD and never runs the VI, so g-cli times out --
  # which is exactly why Mass Compile / VI Analyzer (LabVIEWCLI -Headless) work but
  # Antidoc (a g-cli tool) does not. NI's global override makes EVERY LabVIEW launch
  # headless (no activation, dialogs suppressed): set LV_RTE_HEADLESS=1. See NI's
  # ni/labview-for-containers docs (Headless LabVIEW -> "Setting Headless Mode as
  # default"; FAQ 9 + 11). g-cli inherits this env var and passes it to LabVIEW.
  if (-not $env:LV_RTE_HEADLESS) { $env:LV_RTE_HEADLESS = '1' }

  # A stray LabVIEW / VIPM process left running in the container interferes with
  # g-cli launching its own fresh, attachable LabVIEW (g-cli may attach to the wrong
  # instance, or the handshake never completes). Wovalab's own Antidoc CI kills these
  # before every g-cli step; mirror that. Best-effort: a fresh container usually has
  # none, so this is a no-op there.
  foreach ($proc in @('LabVIEW', 'VI Package Manager', 'VIPM File Handler')) {
    Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  }

  # -v (verbose) makes g-cli log exactly how it launches LabVIEW and whether the app
  # connected / the process exited, so a "no connection" failure is diagnosable from
  # the report log instead of a silent timeout.
  Add-Content -Path $LogFile -Value "LV_RTE_HEADLESS=$($env:LV_RTE_HEADLESS) (forces LabVIEW to launch headless so a direct g-cli launch does not hit the activation wizard)"
  Add-Content -Path $LogFile -Value "Launching: $GCli -v --lv-ver $LvYear --timeout $ConnectTimeoutMs antidoc -- -addon lvproj -pp `"$Project`" -t `"$Title`" -out `"$DocDir`""
  & $GCli -v --lv-ver $LvYear --timeout $ConnectTimeoutMs antidoc -- -addon lvproj -pp $Project -t $Title -out $DocDir 2>&1 |
    Tee-Object -FilePath $LogFile -Append

  $ExitCode = $LASTEXITCODE
  $ErrorActionPreference = $prevEAP

  # Post-mortem on failure: a still-running LabVIEW means the tool VI launched but
  # never connected (broken VI / stuck init) rather than LabVIEW failing to start.
  if ($ExitCode -ne 0) {
    $lv = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue)
    if ($lv.Count -gt 0) {
      Add-Content -Path $LogFile -Value "Post-mortem: LabVIEW.exe is STILL RUNNING after the g-cli timeout ($($lv.Count) process[es]) -- the tool VI launched but never connected (likely a broken/unloadable antidoc.vi or its dependency chain in the worker image)."
    } else {
      Add-Content -Path $LogFile -Value 'Post-mortem: no LabVIEW.exe running after failure -- LabVIEW did not launch or exited early (check activation / the g-cli LabVIEW library for this LabVIEW version).'
    }
    # Clean up any stuck LabVIEW so it never lingers into a later step.
    Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  }
}

$Duration = [math]::Round(((Get-Date) - $Start).TotalSeconds, 1)

# Keep going even if classification hits an unexpected condition: we always want
# to emit an index.html so the dashboard never links to a 404.
$ErrorActionPreference = 'Continue'

# Inventory whatever Antidoc produced.
$DocFiles  = @(Get-ChildItem -LiteralPath $DocDir -Recurse -File -ErrorAction SilentlyContinue)
$AdocFiles = @($DocFiles | Where-Object { $_.Extension -ieq '.adoc' } | Sort-Object Length -Descending)
$HtmlFiles = @($DocFiles | Where-Object { $_.Extension -ieq '.html' -or $_.Extension -ieq '.htm' } | Sort-Object Length -Descending)

$PrimaryKind = 'none'
$PrimaryPath = ''
if ($HtmlFiles.Count -gt 0) {
  $PrimaryKind = 'html'
  $PrimaryPath = 'doc/' + (ConvertTo-RepoRelative $HtmlFiles[0].FullName $DocDir)
}
elseif ($AdocFiles.Count -gt 0) {
  $PrimaryKind = 'adoc'
  $PrimaryPath = 'doc/' + (ConvertTo-RepoRelative $AdocFiles[0].FullName $DocDir)
}

$Generated  = ($DocFiles.Count -gt 0) -and ($PrimaryKind -ne 'none')
$StatusWord = if ($Generated) { 'passed' } else { 'failed' }

$RelFiles = @($DocFiles | ForEach-Object { 'doc/' + (ConvertTo-RepoRelative $_.FullName $DocDir) } | Sort-Object)

Write-Host ""
Write-Host "=== Result: $StatusWord (files=$($DocFiles.Count) primary=$PrimaryKind exit=$ExitCode duration=${Duration}s) ==="

# Machine-readable summary consumed by build-antidoc-report.py + the workflow.
$Summary = [ordered]@{
    status    = $StatusWord
    title     = $Title
    project   = (ConvertTo-RepoRelative $Project $WorkspaceRoot)
    lvVersion = $LvYear
    primary   = [ordered]@{ kind = $PrimaryKind; path = $PrimaryPath }
    fileCount = $DocFiles.Count
    files     = $RelFiles
    exit      = $ExitCode
    duration  = $Duration
}
[System.IO.File]::WriteAllText(
  $MetaFile,
  ($Summary | ConvertTo-Json -Depth 6),
  [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText(
  (Join-Path $ReportDir 'summary.json'),
  ($Summary | ConvertTo-Json -Depth 6 -Compress),
  [System.Text.UTF8Encoding]::new($false))

# ---- Safety-net HTML report -------------------------------------------------
# build-antidoc-report.py overwrites this with the friendly, navigable report;
# this minimal page is what the dashboard shows if that builder is skipped or
# fails. It still renders inside the shared dashboard chrome (lvci-header.js).
function Encode-Html([string]$s) {
    $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
}

$LogText = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($LogText)) { $LogText = '(no output captured)' }
$LogHtml  = Encode-Html $LogText
$ReportTs = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')

$StatusLabel = if ($Generated) { 'documentation generated' } else { 'no documentation produced' }
$StatusColor = if ($Generated) { '#2ea043' } else { '#da3633' }

$HdrRepo  = "$env:GITHUB_REPOSITORY"
$HdrSha   = "$env:GITHUB_SHA"
$HdrShort = if ($HdrSha.Length -ge 7) { $HdrSha.Substring(0, 7) } else { $HdrSha }
$HdrCfg   = "window.LVCI={context:'antidoc-report',repo:'$HdrRepo',pagesUrl:'../..',sha:'$HdrSha',short:'$HdrShort',platform:'windows',rawUrl:'antidoc.log'};"
$TitleHtml = Encode-Html $Title

$Html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Antidoc - $TitleHtml</title>
  <script>$HdrCfg</script>
  <script src="../../lvci-header.js" defer></script>
  <style>
    *{box-sizing:border-box}
    body{margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0d1117;color:#e6edf3}
    .wrap{max-width:1180px;margin:0 auto;padding:20px}
    .card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:20px;margin-bottom:16px}
    h1{margin:0 0 12px;font-size:1.3em}
    .badge{display:inline-block;padding:3px 10px;border-radius:4px;font-weight:700;font-size:.85em;color:#fff;background:$StatusColor}
    .meta{margin-top:10px;font-size:.82em;color:#8b949e;display:flex;flex-wrap:wrap;gap:16px}
    pre{background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:14px;font-size:.75em;white-space:pre-wrap;word-break:break-all;overflow-y:auto;max-height:65vh;margin:0}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>Antidoc - $TitleHtml</h1>
      <span class="badge">$StatusLabel</span>
      <div class="meta">
        <span>Date: $ReportTs</span>
        <span>Duration: ${Duration}s</span>
        <span>Files: $($DocFiles.Count)</span>
        <span>Exit: $ExitCode</span>
      </div>
    </div>
    <pre>$LogHtml</pre>
  </div>
</body>
</html>
"@

[System.IO.File]::WriteAllText($HtmlOut, $Html, [System.Text.UTF8Encoding]::new($false))
Write-Host "HTML report -> $HtmlOut"

if ($StatusWord -eq 'failed') { exit 1 } else { exit 0 }
