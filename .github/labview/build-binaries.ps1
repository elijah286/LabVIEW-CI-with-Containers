<#
.SYNOPSIS
    Executes LabVIEW build specifications (EXE, PPL, shared library, source
    distribution, zip, installer, ...) headlessly, stages the built artifacts
    into a dist/ folder with checksums + a provenance manifest, then writes a
    machine-readable summary.json and a fallback HTML report.

.DESCRIPTION
    Windows counterpart of build-binaries.sh. For every build specification found
    in the project's .lvproj files, the runner invokes the built-in
    'LabVIEWCLI -OperationName ExecuteBuildSpec' operation. ExecuteBuildSpec is
    build-type agnostic: it runs whatever the named specification is. The runner
    is platform-aware only for OS gating: Installer and .NET Interop Assembly
    specifications are Windows-only, so on Linux they are skipped (never failed).

    Output collection: each build specification writes to the local destination
    directory recorded in the .lvproj (Bld_localDestDir). After a successful
    build the runner copies that directory's contents into
    ci-out/builds/dist/<project>/<spec>/, records SHA-256 + size per file, and
    appends the spec to dist/manifest.json (provenance for artifact upload and
    release promotion).

.PARAMETER WorkspaceRoot
    Absolute path inside the container to the project root. Default: C:\workspace

.PARAMETER ReportDir
    Directory to write summary.json, builds.log, dist/, and index.html into.

.PARAMETER LabVIEWPath
    Path to LabVIEW.exe inside the container.

.PARAMETER Projects
    Optional semicolon-separated list of .lvproj paths (relative to the workspace)
    to restrict the build to. Empty = discover and build every project found.
#>
param(
    [string]$WorkspaceRoot = 'C:\workspace',
    [string]$ReportDir     = 'C:\report',
    [string]$LabVIEWPath   = 'C:\Program Files\National Instruments\LabVIEW 2024\LabVIEW.exe',
    [string]$Projects      = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# LabVIEW build-spec Item Type values that only build on Windows. On Linux these
# are skipped (recorded as status 'skipped' with a note, not a failure). The exact
# Type attribute strings are matched case-insensitively as substrings so minor
# LabVIEW-version wording differences do not break the gate.
$WindowsOnlyTypePattern = 'installer|\.net|interop'

function Resolve-LabVIEWPath([string]$PreferredPath) {
  if ($PreferredPath -and (Test-Path $PreferredPath)) {
    return $PreferredPath
  }
  $candidates = @(Get-ChildItem 'C:\Program Files\National Instruments' -Directory -Filter 'LabVIEW *' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'LabVIEW.exe' } |
    Where-Object { Test-Path $_ })
  if ($candidates.Count -gt 0) { return $candidates[0] }
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

# Turn an arbitrary name into a filesystem-safe slug for dist/ subfolders.
function Get-Slug([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return 'unnamed' }
  $slug = ($s -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
  if ([string]::IsNullOrEmpty($slug)) { return 'unnamed' }
  return $slug
}

function Get-Sha256([string]$Path) {
  try { return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
  catch { return '' }
}

# Read config.builds from .github/labview-ci.yml. Returns @{ RunAll = <bool>;
# Sel = @{ '<project>::<name>' = @('windows','linux') } }. When RunAll is true
# (default, or no config) every discovered spec builds on every supported OS.
function Get-BuildsSelection([string]$Root) {
  $result = @{ RunAll = $true; Sel = @{} }
  $cfg = Join-Path $Root '.github/labview-ci.yml'
  if (-not (Test-Path $cfg)) { return $result }
  $inBuilds = $false; $inSpecs = $false; $saw = $false
  foreach ($line in [System.IO.File]::ReadAllLines($cfg)) {
    if ($line -match '^\s{2}builds:\s*$') { $inBuilds = $true; continue }
    if ($inBuilds) {
      if ($line -match '^\s{0,1}\S') { break }
      if ($line -match '^\s{4}runAll:\s*(true|false)') { $result.RunAll = ($Matches[1] -eq 'true'); $inSpecs = $false; $saw = $true; continue }
      if ($line -match '^\s{4}specs:\s*$') { $inSpecs = $true; $saw = $true; continue }
      if ($inSpecs -and ($line -match '^\s{6}-\s*"?([^"]+?)"?\s*$')) {
        $parts = $Matches[1] -split '::'
        if ($parts.Count -ge 3) {
          $os = if ($parts[2] -eq 'none') { @() } else { $parts[2] -split '\+' }
          $result.Sel[$parts[0] + '::' + $parts[1]] = $os
        }
        $saw = $true
      }
    }
  }
  if (-not $saw) { $result.RunAll = $true }
  return $result
}

# Parse a .lvproj and return the build specifications it declares. Each entry:
#   @{ name = <spec name>; type = <Item Type attr>; target = <target name>;
#      destDir = <resolved absolute Bld_localDestDir or ''> }
# The build specs live under the "Build Specifications" (Type="Build") item, one
# per target. Bld_localDestDir is a Path property giving the local output dir.
function Get-BuildSpecs([string]$ProjectPath) {
  $specs = @()
  try {
    [xml]$doc = Get-Content -LiteralPath $ProjectPath -Raw
  } catch {
    Write-Warning "  Could not parse project XML: $ProjectPath"
    return $specs
  }
  $projDir = Split-Path -Parent $ProjectPath
  $buildRoots = @($doc.SelectNodes("//Item[@Type='Build']"))
  foreach ($broot in $buildRoots) {
    # The parent target Item (e.g. "My Computer") is the immediate ancestor of
    # the Build Specifications item.
    $targetName = 'My Computer'
    $parent = $broot.ParentNode
    if ($parent -and $parent.Attributes -and $parent.Attributes['Name']) {
      $targetName = $parent.Attributes['Name'].Value
    }
    foreach ($item in @($broot.ChildNodes)) {
      if ($item.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
      if ($item.LocalName -ne 'Item') { continue }
      $name = if ($item.Attributes['Name']) { $item.Attributes['Name'].Value } else { '' }
      $type = if ($item.Attributes['Type']) { $item.Attributes['Type'].Value } else { '' }
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      # Resolve the local destination directory from Bld_localDestDir if present.
      $destDir = ''
      foreach ($prop in @($item.SelectNodes("Property[@Name='Bld_localDestDir']"))) {
        $raw = ("" + $prop.InnerText).Trim()
        if ($raw) {
          # LabVIEW substitutes build tokens in the destination at build time:
          # NI_AB_PROJECTNAME -> the project name (the .lvproj filename without
          # extension) and NI_AB_TARGETNAME -> the target name. Expand them here so
          # the collected output directory matches where LabVIEW actually wrote.
          $projName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
          $raw = $raw.Replace('NI_AB_PROJECTNAME', $projName).Replace('NI_AB_TARGETNAME', $targetName)
          if ([System.IO.Path]::IsPathRooted($raw)) { $destDir = $raw }
          else { $destDir = [System.IO.Path]::GetFullPath((Join-Path $projDir $raw)) }
          break
        }
      }
      $specs += [ordered]@{ name = $name; type = $type; target = $targetName; destDir = $destDir }
    }
  }
  return $specs
}

$LabVIEWPath = Resolve-LabVIEWPath $LabVIEWPath
$CliExe      = Resolve-LabVIEWCLI $LabVIEWPath
$LogFile     = Join-Path $ReportDir 'builds.log'
$HtmlOut     = Join-Path $ReportDir 'index.html'
$DistDir     = Join-Path $ReportDir 'dist'

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
New-Item -ItemType Directory -Force -Path $DistDir   | Out-Null

Write-Host "=== Build LabVIEW binaries ==="
Write-Host "  Workspace : $WorkspaceRoot"
Write-Host "  LabVIEW   : $LabVIEWPath"
Write-Host "  CLI       : $CliExe"
Write-Host "  Dist      : $DistDir"
Write-Host ""

# Discover projects. Explicit -Projects wins; otherwise every .lvproj outside the
# CI tooling directories.
$ProjectFiles = @()
if (-not [string]::IsNullOrWhiteSpace($Projects)) {
  foreach ($p in ($Projects -split ';')) {
    $p = $p.Trim()
    if ([string]::IsNullOrEmpty($p)) { continue }
    $full = if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $WorkspaceRoot $p }
    if (Test-Path $full) { $ProjectFiles += (Resolve-Path $full).Path }
    else { Write-Warning "  Configured project not found: $p" }
  }
} else {
  $ProjectFiles = @(Get-ChildItem -LiteralPath $WorkspaceRoot -Recurse -File -Filter '*.lvproj' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '(?i)\\(\.github|actions|ci-out|build)\\' } |
    ForEach-Object { $_.FullName })
}

$AllLog = New-Object System.Text.StringBuilder
$SpecResults = @()
$Start = Get-Date
$BuildsCfg = Get-BuildsSelection $WorkspaceRoot

foreach ($proj in $ProjectFiles) {
  $projRel = $proj
  if ($proj.ToLowerInvariant().StartsWith($WorkspaceRoot.ToLowerInvariant())) {
    $projRel = $proj.Substring($WorkspaceRoot.Length).TrimStart('\','/')
  }
  $specs = Get-BuildSpecs $proj
  if ($specs.Count -eq 0) {
    [void]$AllLog.AppendLine("Project has no build specifications: $projRel")
    continue
  }
  foreach ($spec in $specs) {
    # Honor the Builds config: when not building all, skip specs the user did not
    # select for this (Windows) platform.
    if (-not $BuildsCfg.RunAll) {
      $allowed = $BuildsCfg.Sel[(($projRel -replace '\\','/') + '::' + $spec.name)]
      if (-not $allowed -or ($allowed -notcontains 'windows')) { continue }
    }
    $specStart = Get-Date
    $result = [ordered]@{
      project  = $projRel
      name     = $spec.name
      type     = $spec.type
      target   = $spec.target
      status   = 'built'
      outputs  = @()
      message  = ''
      duration = 0
    }

    # OS gate: Installer / .NET Interop are Windows-only. This runner IS Windows,
    # so nothing is gated here; the parallel gate on Linux lives in the .sh runner.
    Write-Host "--- Building '$($spec.name)' [$($spec.type)] target '$($spec.target)' in $projRel ---"
    [void]$AllLog.AppendLine("=== ExecuteBuildSpec '$($spec.name)' [$($spec.type)] target '$($spec.target)' in $projRel ===")

    # LabVIEWCLI prints operation output to stderr; relax ErrorActionPreference so
    # merging via 2>&1 does not raise a terminating NativeCommandError. Success is
    # judged by the real $LASTEXITCODE. -Headless is REQUIRED for LabVIEW 2026+ in
    # Windows containers (otherwise VI Server fails with -350000).
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $cliArgs = @(
      '-LogToConsole', 'TRUE',
      '-OperationName', 'ExecuteBuildSpec',
      '-ProjectPath',   $proj,
      '-TargetName',    $spec.target,
      '-BuildSpecName', $spec.name,
      '-LabVIEWPath',   $LabVIEWPath,
      '-Headless'
    )
    $out = & $CliExe @cliArgs 2>&1 | Out-String
    $ExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    [void]$AllLog.AppendLine($out)

    if ($ExitCode -ne 0) {
      $result.status  = 'failed'
      $result.message = "ExecuteBuildSpec exited $ExitCode"
      Write-Host "  FAILED (exit $ExitCode)"
    } else {
      # Collect outputs from the spec's local destination directory.
      $stageDir = Join-Path $DistDir (Join-Path (Get-Slug $projRel) (Get-Slug $spec.name))
      New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
      $collected = @()
      $srcDir = $spec.destDir
      if ($srcDir -and (Test-Path $srcDir)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $srcDir -Recurse -File -ErrorAction SilentlyContinue)) {
          $rel = $f.FullName.Substring($srcDir.Length).TrimStart('\','/')
          $target = Join-Path $stageDir $rel
          New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
          Copy-Item -LiteralPath $f.FullName -Destination $target -Force
          $collected += [ordered]@{ file = $rel; size = $f.Length; sha256 = (Get-Sha256 $target) }
        }
      }
      $result.outputs = $collected
      if ($collected.Count -eq 0) {
        $result.message = "Built, but no output files were located (destination dir: '$srcDir')."
        Write-Host "  BUILT (no output files located; verify Bld_localDestDir)"
      } else {
        Write-Host "  BUILT ($($collected.Count) file(s))"
      }
    }
    $result.duration = [math]::Round(((Get-Date) - $specStart).TotalSeconds, 1)
    $SpecResults += $result
  }
}

$Duration = [math]::Round(((Get-Date) - $Start).TotalSeconds, 1)

$Total   = $SpecResults.Count
$Built   = @($SpecResults | Where-Object { $_.status -eq 'built' }).Count
$Failed  = @($SpecResults | Where-Object { $_.status -eq 'failed' }).Count
$Skipped = @($SpecResults | Where-Object { $_.status -eq 'skipped' }).Count

if ($Total -le 0) {
  $StatusWord = 'passed'   # nothing to build is not a failure
} elseif ($Failed -gt 0) {
  $StatusWord = 'failed'
} elseif ($Skipped -gt 0) {
  $StatusWord = 'partial'
} else {
  $StatusWord = 'passed'
}

$LogText = $AllLog.ToString()
if ([string]::IsNullOrEmpty($LogText)) { $LogText = '(no build specifications found)' }
[System.IO.File]::WriteAllText($LogFile, $LogText, [System.Text.UTF8Encoding]::new($false))

# Machine-readable summary consumed by the dashboard Builds column and the
# workflow commit status.
$Summary = [ordered]@{
  platform        = 'windows'
  status          = $StatusWord
  total           = $Total
  built           = $Built
  skipped         = $Skipped
  failed          = $Failed
  duration        = $Duration
  labview_version = (Split-Path -Leaf (Split-Path -Parent $LabVIEWPath))
  specs           = $SpecResults
}
[System.IO.File]::WriteAllText((Join-Path $ReportDir 'summary.json'), ($Summary | ConvertTo-Json -Depth 8 -Compress), [System.Text.UTF8Encoding]::new($false))

# Provenance manifest alongside the staged artifacts (Tier A upload + Tier B
# release promotion read this).
$Manifest = [ordered]@{
  repo            = "$env:GITHUB_REPOSITORY"
  sha             = "$env:GITHUB_SHA"
  ref             = "$env:GITHUB_REF"
  platform        = 'windows'
  arch            = "$env:PROCESSOR_ARCHITECTURE"
  labview_version = (Split-Path -Leaf (Split-Path -Parent $LabVIEWPath))
  built_at        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  specs           = $SpecResults
}
[System.IO.File]::WriteAllText((Join-Path $DistDir 'manifest.json'), ($Manifest | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))

Write-Host ""
Write-Host "=== Result: $StatusWord ($Built built, $Skipped skipped, $Failed failed of $Total; duration=${Duration}s) ==="

# ---- Fallback HTML report (build-binaries-report.py overwrites this) ---------
function Encode-Html([string]$s) { $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
$LogHtml  = Encode-Html $LogText
$ReportTs = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')
$StatusColor = if ($StatusWord -eq 'passed') { '#2ea043' } elseif ($StatusWord -eq 'failed') { '#da3633' } else { '#bb8009' }
$HdrRepo  = "$env:GITHUB_REPOSITORY"
$HdrSha   = "$env:GITHUB_SHA"
$HdrShort = if ($HdrSha.Length -ge 7) { $HdrSha.Substring(0, 7) } else { $HdrSha }
$HdrCfg   = "window.LVCI={context:'builds-report',repo:'$HdrRepo',pagesUrl:'../..',sha:'$HdrSha',short:'$HdrShort',platform:'windows',rawUrl:'builds.log'};"

$Html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Builds &mdash; LabVIEW-CI-with-Containers</title>
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
      <h1>Builds &mdash; LabVIEW-CI-with-Containers</h1>
      <span class="badge">$StatusWord</span>
      <div class="meta">
        <span>Date: $ReportTs</span>
        <span>Duration: ${Duration}s</span>
        <span>Specs: $Total</span>
        <span>Built: $Built</span>
        <span>Skipped: $Skipped</span>
        <span>Failed: $Failed</span>
      </div>
    </div>
    <pre>$LogHtml</pre>
  </div>
</body>
</html>
"@
[System.IO.File]::WriteAllText($HtmlOut, $Html, [System.Text.UTF8Encoding]::new($false))

if ($StatusWord -eq 'failed') { exit 1 } else { exit 0 }
