<#
.SYNOPSIS
    Run the configured LabVIEW unit-test frameworks headlessly and emit one JUnit
    XML file per tool into -ResultsDir. Runs INSIDE the LabVIEW CI container
    (same environment as run-vi-analyzer.ps1). Its JUnit output is consumed by
    build-unittest-report.py, which merges every *.xml into one friendly report.

.DESCRIPTION
    Reads `config.unitTests.tools[]` from .github/labview-ci.yml. For each enabled
    tool it resolves the configured test locations (each a directory to recurse or
    a glob / file-extension pattern) and invokes that tool's headless runner via
    g-cli (already baked into the CI image), writing JUnit XML.

    Caraya is the reference implementation. JKI VI Tester and NI UTF are scaffolded
    with the same contract. The exact g-cli command for each tool is a per-tool
    template that can be overridden from the config (`command:` key) so the precise
    invocation can be corrected on a real worker without editing this script.

    HEADLESS: LabVIEW must run -Headless in LabVIEW 2026+ Windows containers (same
    constraint run-vi-analyzer.ps1 documents) or VI Server fails with -350000. g-cli
    launches LabVIEW the same way, so we pass the LabVIEW path/version through.

.PARAMETER WorkspaceRoot
    Absolute path to the checked-out project inside the container. Default C:\workspace.

.PARAMETER ResultsDir
    Directory to write the per-tool JUnit XML into. build-unittest-report.py reads
    every *.xml here and infers the tool from the file name (caraya*.xml -> Caraya,
    vitester*/vi-tester* -> VI Tester, utf*/unit-test* -> UTF).

.PARAMETER ConfigPath
    Path to labview-ci.yml. Default: <WorkspaceRoot>\.github\labview-ci.yml.
#>
param(
    [string]$WorkspaceRoot  = 'C:\workspace',
    [string]$ResultsDir     = 'C:\workspace\ci-out\unit-tests\results',
    [string]$ConfigPath     = '',
    [string]$LabVIEWVersion = '2026',
    [string]$LabVIEWPath    = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

if (-not $ConfigPath) { $ConfigPath = Join-Path $WorkspaceRoot '.github\labview-ci.yml' }
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

# -- Resolve LabVIEW / LabVIEWCLI / g-cli (mirror run-vi-analyzer.ps1) ----------
function Resolve-LabVIEWPath([string]$PreferredPath) {
    if ($PreferredPath -and (Test-Path $PreferredPath)) { return $PreferredPath }
    $candidates = @(Get-ChildItem 'C:\Program Files\National Instruments' -Directory -Filter 'LabVIEW *' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'LabVIEW.exe' } |
        Where-Object { Test-Path $_ })
    if ($candidates.Count -gt 0) { return $candidates[0] }
    throw "LabVIEW.exe not found (preferred '$PreferredPath')."
}

function Resolve-Cmd([string[]]$names) {
    foreach ($n in $names) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c -and $c.Source) { return $c.Source }
    }
    return $null
}

function Sync-PathFromRegistry {
    # VIPM-installed CLIs (e.g. g-cli) add their directory to the MACHINE PATH in the
    # registry at install time, but a Windows container's process PATH is baked from
    # the image ENV layer and does NOT pick that up (the g-cli docs note you must
    # "restart any terminals or build agents after install"). Re-read the persisted
    # PATH from the registry and merge in anything missing so Get-Command can see a
    # freshly-baked g-cli without an image rebuild. Best-effort: never aborts the run.
    try {
        $machine = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name 'Path' -ErrorAction SilentlyContinue).Path
        $user    = (Get-ItemProperty -Path 'HKCU:\Environment' -Name 'Path' -ErrorAction SilentlyContinue).Path
        $current = @($env:Path -split ';')
        foreach ($raw in @($machine, $user)) {
            if (-not $raw) { continue }
            foreach ($entry in ([System.Environment]::ExpandEnvironmentVariables($raw) -split ';')) {
                $e = $entry.Trim()
                if ($e -and ($current -notcontains $e)) { $env:Path = $env:Path.TrimEnd(';') + ';' + $e; $current += $e }
            }
        }
    } catch { Write-Host "  (PATH refresh from registry skipped: $($_.Exception.Message))" }
}

function Resolve-LabVIEWCLI([string]$LabVIEWExePath) {
    $cli = Get-Command 'LabVIEWCLI.exe' -ErrorAction SilentlyContinue
    if ($null -eq $cli) { $cli = Get-Command 'LabVIEWCLI' -ErrorAction SilentlyContinue }
    if ($null -ne $cli -and $cli.Source) { return $cli.Source }
    if ($LabVIEWExePath) {
        $candidate = Join-Path (Split-Path $LabVIEWExePath) 'LabVIEWCLI.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

# The vendored NI "UTF JUnit Report" runner VI (Apache-2.0, github.com/LabVIEW-DCAF/
# UTF-Test): runs every .lvtest in a project through the NI Unit Test Framework and
# writes a JUnit-compatible report. Driven headlessly via LabVIEWCLI RunVI below.
$UtfRunnerVi = Join-Path $WorkspaceRoot '.github\labview\utf-junit\run utf and report.vi'

$LabVIEWPath = Resolve-LabVIEWPath $LabVIEWPath
Sync-PathFromRegistry
$GCli        = Resolve-Cmd @('g-cli', 'g-cli.exe')
$CliExe      = Resolve-LabVIEWCLI $LabVIEWPath

Write-Host "=== Unit Tests (Windows) ==="
Write-Host "  Workspace : $WorkspaceRoot"
Write-Host "  Results   : $ResultsDir"
Write-Host "  LabVIEW   : $LabVIEWPath  (v$LabVIEWVersion)"
Write-Host "  LabVIEWCLI: $(if ($CliExe) { $CliExe } else { '<not found>' })"
Write-Host "  g-cli     : $(if ($GCli) { $GCli } else { '<not found on PATH>' })"
Write-Host "  UTF runner: $(if (Test-Path -LiteralPath $UtfRunnerVi) { $UtfRunnerVi } else { '<not vendored>' })"
Write-Host "  Config    : $ConfigPath"
Write-Host ""

# -- Minimal reader for config.unitTests.tools[] -------------------------------
# Repo convention is regex/state-machine YAML parsing (see the awk parsers in the
# container workflows). We only need this fixed, shallow shape:
#   config:
#     unitTests:
#       tools:
#         caraya:
#           enabled: true
#           command: "<optional g-cli override with {ver} {dir} {out} tokens>"
#           locations:
#             - "tests/"
#             - "**/*.vi"
#         vi-tester:
#           enabled: false
#           locations: []
# Only tools with `enabled: true` are returned. Blank/empty locations = whole project.
function Read-UnitTestTools([string]$path) {
    $tools = @()
    if (-not (Test-Path $path)) { return ,$tools }
    $inUT = $false; $inTools = $false; $inLoc = $false
    $cur = $null
    foreach ($raw in (Get-Content -LiteralPath $path)) {
        $line = ($raw -replace '\t', '    ')
        if ($line -match '^\s*unitTests:\s*$') { $inUT = $true; $inTools = $false; $inLoc = $false; $cur = $null; continue }
        if (-not $inUT) { continue }
        if ($line -match '^\s{2}tools:\s*$')   { $inTools = $true; continue }

        # A tool entry is a map key under tools:, e.g. "    caraya:" (4-space indent).
        $m = [regex]::Match($line, '^\s{4}([A-Za-z0-9_.-]+):\s*$')
        if ($inTools -and $m.Success) {
            if ($cur -and $cur.enabled) { $tools += $cur }
            $cur = [ordered]@{ tool = $m.Groups[1].Value.ToLower(); enabled = $false; command = ''; locations = @() }
            $inLoc = $false
            continue
        }
        if ($null -ne $cur) {
            if ($line -match '^\s{6}enabled:\s*(true|false)\s*$') { $cur.enabled = ($Matches[1] -eq 'true'); $inLoc = $false; continue }
            $cm = [regex]::Match($line, '^\s{6}command:\s*"?(.+?)"?\s*$')
            if ($cm.Success) { $cur.command = $cm.Groups[1].Value; $inLoc = $false; continue }
            if ($line -match '^\s{6}locations:\s*\[\s*\]\s*$') { $cur.locations = @(); $inLoc = $false; continue }
            if ($line -match '^\s{6}locations:\s*$') { $inLoc = $true; continue }
            if ($inLoc) {
                $lm = [regex]::Match($line, '^\s{8}-\s*"?([^"]+?)"?\s*$')
                if ($lm.Success) { $cur.locations += $lm.Groups[1].Value; continue }
            }
        }
        # A top-level key (column 0) ends the unitTests block.
        if ($line -match '^\S') {
            if ($cur -and $cur.enabled) { $tools += $cur }
            $cur = $null; $inUT = $false; $inTools = $false; $inLoc = $false
        }
    }
    if ($cur -and $cur.enabled) { $tools += $cur }
    return ,$tools
}

# -- Resolve a tool's locations (dir OR glob/extension) to scan-root directories -
function Resolve-TestRoots([string[]]$locations) {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($loc in $locations) {
        if (-not $loc) { continue }
        $rel  = ($loc -replace '/', '\')
        $full = Join-Path $WorkspaceRoot $rel
        if (Test-Path -LiteralPath $full -PathType Container) {
            $roots.Add((Resolve-Path -LiteralPath $full).Path); continue
        }
        # Glob / extension: expand and take each match's parent directory.
        try {
            $matches = Get-ChildItem -Path (Join-Path $WorkspaceRoot $rel) -Recurse -File -ErrorAction SilentlyContinue
            foreach ($f in $matches) { $roots.Add($f.DirectoryName) }
        } catch { }
    }
    return ($roots | Sort-Object -Unique)
}

# -- Per-tool default g-cli command templates ---------------------------------
# Tokens: {ver}=LabVIEW year, {dir}=a resolved test-root directory, {out}=JUnit
# output path, {lv}=LabVIEW.exe path. A `command:` in the tool's config overrides
# the default. THESE DEFAULTS ARE BEST-EFFORT and must be confirmed on a real
# worker (the exact g-cli plugin name + flags per tool); the override key exists
# so that confirmation needs no script change.
$DEFAULT_CMD = @{
    # Caraya CLI g-cli extension (lvos_lib_caraya_cli_extension): run every Caraya
    # test under a directory and export JUnit. Reference implementation.
    'caraya'    = 'g-cli --lv-ver {ver} -- caraya -- --directory "{dir}" --junit "{out}"'
    # JKI VI Tester via sas_workshops_lib_vitester_for_g_cli (scaffold).
    'vi-tester' = 'g-cli --lv-ver {ver} -- vitester -- --directory "{dir}" --junit "{out}"'
}

# NI Unit Test Framework runs the .lvtest files of a PROJECT (not a flat directory of
# test VIs), so UTF has its own runner (Invoke-UtfTests) rather than the generic
# {dir} template. The default drives the vendored "run utf and report.vi" through
# LabVIEWCLI RunVI, passing the project path and the JUnit output path as arguments;
# -Headless is required for LabVIEW 2026 Windows containers (mirrors run-vi-analyzer).
# Tokens: {cli}=LabVIEWCLI, {runner}=vendored runner VI, {lv}=LabVIEW.exe,
# {proj}=.lvproj path, {out}=JUnit output path, {ver}=LabVIEW year. Override per tool
# with the config `command:` key once the exact invocation is confirmed on a worker.
$UTF_DEFAULT_CMD = '"{cli}" -OperationName RunVI -VIPath "{runner}" -LabVIEWPath "{lv}" -Arguments "{proj}" "{out}" -Headless'

function Invoke-Tool($tool, [int]$index) {
    $id   = $tool.tool
    $tmpl = if ($tool.command) { $tool.command } elseif ($DEFAULT_CMD.ContainsKey($id)) { $DEFAULT_CMD[$id] } else { '' }
    $locs = @($tool.locations | Where-Object { $_ -and $_.Trim() })
    # Empty locations means "the whole project" (the config page documents this).
    $roots = if ($locs.Count -gt 0) { Resolve-TestRoots $locs } else { @($WorkspaceRoot) }

    Write-Host "--- tool: $id ---"
    if ($roots.Count -eq 0) { Write-Warning "  no test locations resolved for '$id' (locations: $($tool.locations -join ', ')) - skipping."; return }
    if (-not $tmpl)         { Write-Warning "  no headless command known for '$id' yet (set config.unitTests.tools[].command to enable) - skipping."; return }
    if (-not $GCli -and $tmpl -match '(^|\s)g-cli(\s|$)') { Write-Warning "  g-cli not found on PATH; cannot run '$id'."; return }

    $i = 0
    foreach ($dir in $roots) {
        $out = Join-Path $ResultsDir ("{0}-{1}.xml" -f $id, ($index * 100 + $i))
        $cmd = $tmpl.Replace('{ver}', $LabVIEWVersion).Replace('{dir}', $dir).Replace('{out}', $out).Replace('{lv}', $LabVIEWPath)
        Write-Host "  [$id] $cmd"
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            & cmd.exe /c $cmd 2>&1 | Out-Host
            Write-Host ("  [$id] exit={0}" -f $LASTEXITCODE)
        } catch {
            Write-Warning "  [$id] runner error: $($_.Exception.Message)"
        }
        $ErrorActionPreference = $prevEAP
        if (Test-Path -LiteralPath $out) { Write-Host "  [$id] wrote $out" }
        else { Write-Warning "  [$id] produced no JUnit at $out (check the command/plugin for this tool)." }
        $i++
    }
}

# -- NI Unit Test Framework (UTF) ---------------------------------------------
# UTF tests live as .lvtest files inside a .lvproj. Resolve the project(s) to run
# from the tool's locations (a .lvproj path, or a directory/glob to search), keeping
# only projects that actually reference UTF tests so we never launch LabVIEW for
# nothing. Empty locations means "search the whole project".
function Resolve-UtfProjects([string[]]$locations) {
    $found = New-Object System.Collections.Generic.List[string]
    # A location may itself be a .lvproj.
    foreach ($loc in @($locations)) {
        if (-not $loc) { continue }
        $full = Join-Path $WorkspaceRoot ($loc -replace '/', '\')
        if ((Test-Path -LiteralPath $full -PathType Leaf) -and ($full -match '\.lvproj$')) {
            $found.Add((Resolve-Path -LiteralPath $full).Path)
        }
    }
    $roots = if (@($locations | Where-Object { $_ -and $_.Trim() }).Count -gt 0) { Resolve-TestRoots $locations } else { @($WorkspaceRoot) }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $projs = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.lvproj' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '(?i)\\\.github\\' -and $_.FullName -notmatch '(?i)\\ci-out\\' })
        foreach ($p in $projs) {
            $txt = Get-Content -LiteralPath $p.FullName -Raw -ErrorAction SilentlyContinue
            if ($txt -and ($txt -match 'Type="TestItem"' -or $txt -match '\.lvtest')) { $found.Add($p.FullName) }
        }
    }
    return ($found | Sort-Object -Unique)
}

function Invoke-UtfTests($tool, [int]$index) {
    $id = $tool.tool
    Write-Host "--- tool: $id (NI Unit Test Framework) ---"
    $projects = @(Resolve-UtfProjects $tool.locations)
    if ($projects.Count -eq 0) {
        Write-Warning "  no UTF project (.lvproj containing .lvtest) found for locations: $($tool.locations -join ', ') - skipping."
        return
    }
    if (-not $CliExe) { Write-Warning "  LabVIEWCLI not found; cannot run UTF."; return }
    if (-not (Test-Path -LiteralPath $UtfRunnerVi)) {
        Write-Warning "  vendored UTF runner VI not found at '$UtfRunnerVi' - cannot run UTF."
        return
    }
    $tmpl = if ($tool.command) { $tool.command } else { $UTF_DEFAULT_CMD }

    $i = 0
    foreach ($proj in $projects) {
        $out     = Join-Path $ResultsDir ("utf-{0}.xml" -f ($index * 100 + $i))
        $projDir = Split-Path -LiteralPath $proj
        Write-Host "  [utf] project: $proj"

        # Record existing XML so we can harvest whatever JUnit the runner writes, and
        # wherever it writes it (it may honour {out} or emit beside the project).
        $before = @{}
        Get-ChildItem -LiteralPath $projDir -Recurse -File -Filter '*.xml' -ErrorAction SilentlyContinue |
            ForEach-Object { $before[$_.FullName] = $_.LastWriteTimeUtc }

        $cmd = $tmpl.Replace('{cli}', $CliExe).Replace('{runner}', $UtfRunnerVi).Replace('{lv}', $LabVIEWPath).Replace('{proj}', $proj).Replace('{out}', $out).Replace('{ver}', $LabVIEWVersion)
        Write-Host "  [utf] $cmd"

        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            & cmd.exe /c $cmd 2>&1 | Out-Host
            Write-Host ("  [utf] exit={0}" -f $LASTEXITCODE)
        } catch {
            Write-Warning "  [utf] runner error: $($_.Exception.Message)"
        }
        $ErrorActionPreference = $prevEAP

        # Harvest: prefer the explicit {out}; otherwise copy any JUnit-looking XML the
        # runner produced under the project tree during this run.
        if (-not (Test-Path -LiteralPath $out)) {
            $new = @(Get-ChildItem -LiteralPath $projDir -Recurse -File -Filter '*.xml' -ErrorAction SilentlyContinue |
                Where-Object { -not $before.ContainsKey($_.FullName) -or $_.LastWriteTimeUtc -gt $before[$_.FullName] } |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -match '<testsuite' })
            if ($new.Count -gt 0) {
                Copy-Item -LiteralPath $new[0].FullName -Destination $out -Force
                Write-Host "  [utf] harvested $($new[0].FullName) -> $out"
            }
        }
        if (Test-Path -LiteralPath $out) { Write-Host "  [utf] wrote $out" }
        else { Write-Warning "  [utf] produced no JUnit (confirm the RunVI invocation/runner on a real worker; override with the tool's command: key)." }
        $i++
    }
}

# -- Main ---------------------------------------------------------------------
$tools = Read-UnitTestTools $ConfigPath
if (-not $tools -or $tools.Count -eq 0) {
    Write-Warning "No config.unitTests.tools configured in $ConfigPath - nothing to run."
    Write-Host "Wrote 0 JUnit file(s) to $ResultsDir."
    exit 0
}

Write-Host ("Configured tools: {0}" -f (($tools | ForEach-Object { $_.tool }) -join ', '))
Write-Host ""

$idx = 0
foreach ($t in $tools) {
    if ($t.tool -eq 'utf') { Invoke-UtfTests $t $idx } else { Invoke-Tool $t $idx }
    $idx++; Write-Host ""
}

$xml = @(Get-ChildItem -Path $ResultsDir -Filter '*.xml' -File -ErrorAction SilentlyContinue)
Write-Host "=== Unit Tests finished: wrote $($xml.Count) JUnit file(s) to $ResultsDir ==="
# Always exit 0: pass/fail is derived from the JUnit content by
# build-unittest-report.py (its summary.json drives the commit status), exactly
# like the Mass Compile report. A runner-level error surfaces as a missing/empty
# report, not a hard CI failure here.
exit 0
