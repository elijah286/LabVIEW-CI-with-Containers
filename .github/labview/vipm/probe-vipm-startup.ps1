# =============================================================================
# VIPM startup compatibility probe
# =============================================================================
# Runs INSIDE a candidate NI LabVIEW container (docker exec) and answers one
# question: can the VIPM CLI complete its Desktop-engine startup handshake and a
# package-source refresh against the LabVIEW baked into THIS container?
#
# Background: every Windows worker "apply dependencies" bake wedged with
# "Operation 'wait for VIPM startup' timed out after 900s" after NI repointed
# nationalinstruments/labview:latest-windows from 2026 Q1 (LabVIEW 26.1) to
# 2026 Q3 (LabVIEW 26.3) on 2026-07-27, while VIPM 2026.3.0 build 3954 (built
# 2026-06-18, before Q3 shipped) stayed pinned in the base Dockerfile. This
# probe reproduces the exact install-vipc.ps1 startup sequence with a SHORT
# timeout, then captures the diagnostics the 900s bake failures never surfaced:
# process states, listening ports, JKI/VIPM log files, the Settings.ini VIPM
# actually left behind, and Windows Application-event errors.
#
# It is also the qualification gate for new container versions: a candidate
# (container tag, VIPM build) pair is only promoted into the catalog when this
# probe passes for it.
#
# Environment (all optional):
#   PROBE_VIPM_URL          VIPM installer to test (default: the baked-in pin)
#   PROBE_VIPM_TIMEOUT      seconds per vipm operation (default 240 - fail fast)
#   PROBE_SETTINGS_VERSION  override the seeded Settings.ini LabVIEW version
#                           string, e.g. '26.1 (64-bit)', to test whether the
#                           version STRING (not the binary) triggers the wedge
#   PROBE_VARIATIONS        '1' -> after a failed refresh, retry once with the
#                           Settings.ini version forced to '26.1 (64-bit)'
#   PROBE_OUT_DIR           where to copy captured logs (default C:\probe-out)
#
# Output contract: every phase prints '### PROBE <phase>' markers and the final
# line is 'PROBE RESULT: PASS|FAIL <detail>' so the workflow (and a human) can
# grep the verdict without reading the whole transcript.
# =============================================================================

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$OutDir = if ($Env:PROBE_OUT_DIR) { $Env:PROBE_OUT_DIR } else { 'C:\probe-out' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# Mirror install-vipc.ps1's environment exactly: non-interactive, CI hints on
# (they lengthen VIPM's internal grace periods), debug output on.
$Env:VIPM_NONINTERACTIVE = '1'
$Env:VIPM_ASSUME_YES     = '1'
$Env:NO_COLOR            = '1'
if (-not $Env:CI)             { $Env:CI = 'true' }
if (-not $Env:GITHUB_ACTIONS) { $Env:GITHUB_ACTIONS = 'true' }
$Env:VIPM_DEBUG   = '1'
$Env:VIPM_TIMEOUT = if ($Env:PROBE_VIPM_TIMEOUT) { $Env:PROBE_VIPM_TIMEOUT } else { '240' }

# Mirror install-vipc.ps1: LCWC base images bake ENV LV_RTE_HEADLESS=1 for
# runtime workflows (g-cli/Antidoc), but the VIPM Desktop engine is itself a
# LabVIEW-runtime app that never completes its startup handshake under a global
# headless default - the failure that broke every Windows dependency bake after
# 2026-07-22. install-vipc.ps1 clears it for its process tree, so the
# qualification probe does the same by default; set PROBE_KEEP_LV_RTE_HEADLESS=1
# to keep the variable and reproduce the wedge deliberately.
if ($Env:LV_RTE_HEADLESS -and $Env:PROBE_KEEP_LV_RTE_HEADLESS -ne '1') {
    Write-Host "Clearing LV_RTE_HEADLESS=$($Env:LV_RTE_HEADLESS) for the probe (matches install-vipc.ps1; set PROBE_KEEP_LV_RTE_HEADLESS=1 to keep it)."
    Remove-Item Env:LV_RTE_HEADLESS -ErrorAction SilentlyContinue
}

$VipmDir          = 'C:\Program Files\JKI\VI Package Manager'
$VipmInstallerUrl = if ($Env:PROBE_VIPM_URL) { $Env:PROBE_VIPM_URL } else { 'https://traffic.libsyn.com/secure/jkinc/vipm-26.3.3954-windows-setup.exe' }

function Write-Phase([string] $name) { Write-Host ''; Write-Host "### PROBE $name" }

# -- Phase 0: container inventory ---------------------------------------------
# What LabVIEW (exact ProductVersion), what OS build, is VIPM already present
# (NI could start bundling it), how much memory/disk does the container see.
Write-Phase 'inventory'
$os = Get-CimInstance Win32_OperatingSystem
Write-Host ("OS: " + $os.Caption + " build " + $os.BuildNumber)
Write-Host ("Memory: {0:N0} MB visible / {1:N0} MB free" -f ($os.TotalVisibleMemorySize/1KB), ($os.FreePhysicalMemory/1KB))
Write-Host ("User: " + (whoami))
Get-PSDrive -Name C | ForEach-Object { Write-Host ("Disk C: {0:N1} GB free" -f ($_.Free/1GB)) }

$lvExe = @(
    'C:\Program Files\National Instruments',
    'C:\Program Files (x86)\National Instruments'
) | Where-Object { Test-Path $_ } |
    ForEach-Object { Get-ChildItem -Path $_ -Directory -Filter 'LabVIEW*' -ErrorAction SilentlyContinue } |
    ForEach-Object { Join-Path $_.FullName 'LabVIEW.exe' } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $lvExe) { Write-Host 'PROBE RESULT: FAIL no LabVIEW.exe found in container'; exit 1 }

$lvInfo = (Get-Item $lvExe).VersionInfo
$lvVer  = '{0}.{1}' -f $lvInfo.ProductMajorPart, $lvInfo.ProductMinorPart
Write-Host ("LabVIEW: " + $lvExe)
Write-Host ("LabVIEW ProductVersion: " + $lvInfo.ProductVersion + " (target string " + $lvVer + ")")
Write-Host ("LabVIEW FileVersion: " + $lvInfo.FileVersion)

Write-Host 'Pre-existing JKI installs (empty = none):'
@('C:\Program Files\JKI', 'C:\Program Files (x86)\JKI', 'C:\ProgramData\JKI') |
    Where-Object { Test-Path $_ } |
    ForEach-Object { Get-ChildItem $_ -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("  " + $_.FullName) } }
Write-Host 'nipkg packages mentioning vipm (empty = none):'
try { nipkg list 2>$null | Select-String -Pattern 'vipm' | ForEach-Object { Write-Host ("  " + $_.Line) } } catch {}

# -- Phase 1: install VIPM ----------------------------------------------------
Write-Phase 'install-vipm'
if (Test-Path (Join-Path $VipmDir 'support\vipm.exe')) {
    Write-Host 'VIPM already present; skipping installer.'
} else {
    $setup = Join-Path $env:TEMP 'vipm-setup.exe'
    Write-Host "Downloading VIPM installer: $VipmInstallerUrl"
    Invoke-WebRequest -Uri $VipmInstallerUrl -OutFile $setup -UseBasicParsing
    Write-Host ('Downloaded {0:N1} MB; installing silently ...' -f ((Get-Item $setup).Length / 1MB))
    $p = Start-Process -Wait -PassThru -FilePath $setup -ArgumentList '/exenoui', '/qn'
    Write-Host ("VIPM installer exit code: " + $p.ExitCode)
    Remove-Item $setup -Force -ErrorAction SilentlyContinue
}
$VipmExe = @("$VipmDir\vipm.exe", "$VipmDir\support\vipm.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $VipmExe) { Write-Host 'PROBE RESULT: FAIL vipm.exe not found after install'; exit 1 }
& $VipmExe --version 2>&1 | Out-Host
& $VipmExe about     2>&1 | Out-Host

# -- Phase 2: seed Settings.ini (same shape install-vipc.ps1 writes) ----------
Write-Phase 'seed-settings'
$seedVer = if ($Env:PROBE_SETTINGS_VERSION) { $Env:PROBE_SETTINGS_VERSION } else { "$lvVer (64-bit)" }
$VipmSettingsDir = 'C:\ProgramData\JKI\VIPM'
$VipmSettings    = Join-Path $VipmSettingsDir 'Settings.ini'

function Write-VipmSettings([string] $ver) {
    $lvIni = '/' + (($lvExe -replace ':', '') -replace '\\', '/')
    $settingsText = @"
[General]
IsFirstLaunch="FALSE"

[Targets]
Names.<size(s)>="1"
Names 0="LabVIEW"
Versions.<size(s)>="1"
Versions 0="$ver"
Locations.<size(s)>="1"
Locations 0="$lvIni"
Ports="<size(s)=1> 3363"
Tested.<size(s)>="1"
Tested 0="TRUE"
Disabled.<size(s)>="1"
Disabled 0="FALSE"
Connection Timeout="120"
Active Target.Name="LabVIEW"
Active Target.Version="$ver"
CommunityEdition.<size(s)>="1"
CommunityEdition 0="TRUE"
"@
    New-Item -ItemType Directory -Path $VipmSettingsDir -Force | Out-Null
    Set-Content -Path $VipmSettings -Value $settingsText -Encoding ASCII
    Write-Host "Seeded VIPM Settings.ini for target: LabVIEW $ver"
}
Write-VipmSettings $seedVer

# -- Phase 3: start the stack (mirrors install-vipc.ps1) ----------------------
Write-Phase 'start-stack'
function Start-Stack {
    Write-Host "Launching headless LabVIEW: $lvExe"
    Start-Process -FilePath $lvExe -ArgumentList '--headless' | Out-Null
    $deadline = (Get-Date).AddSeconds(180)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect('127.0.0.1', 3363)
            if ($client.Connected) { $client.Close(); $ready = $true; break }
        } catch { Start-Sleep -Seconds 3 }
    }
    Write-Host ($(if ($ready) { 'Headless LabVIEW VI Server is ready (port 3363).' } else { 'WARNING: VI Server (3363) never came up.' }))

    $engineExe = Join-Path $VipmDir 'VI Package Manager.exe'
    if (Test-Path $engineExe) {
        Write-Host "Pre-launching VIPM engine: $engineExe"
        Start-Process -FilePath $engineExe | Out-Null
        Start-Sleep -Seconds 45
    } else {
        Write-Host "WARNING: $engineExe not found; the CLI will try to launch the engine itself."
    }
}
Start-Stack

# Snapshot the stack state BEFORE the refresh so a wedge can be compared
# against a known-good baseline.
function Show-StackState([string] $label) {
    Write-Host "--- stack state: $label ---"
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match 'LabVIEW|VI Package|vipm' } |
        ForEach-Object { Write-Host ("  proc " + $_.Id + " " + $_.ProcessName + " responding=" + $_.Responding + " mem=" + [int]($_.WorkingSet64/1MB) + "MB title='" + $_.MainWindowTitle + "'") }
    try {
        Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -in 3363, 5007, 5008, 5009 -or $_.OwningProcess -in (Get-Process -Name 'VI Package Manager', 'LabVIEW', 'vipm' -ErrorAction SilentlyContinue).Id } |
            ForEach-Object { Write-Host ("  listen " + $_.LocalAddress + ":" + $_.LocalPort + " pid=" + $_.OwningProcess) }
    } catch { netstat -ano | Select-String 'LISTEN' | ForEach-Object { Write-Host ("  " + $_.Line.Trim()) } }
    Write-Host '--- end stack state ---'
}
Show-StackState 'after launch, before refresh'

# -- Phase 4: the actual health check -----------------------------------------
Write-Phase 'refresh'
function Invoke-Refresh {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = & $VipmExe refresh --force 2>&1
    $exit = $LASTEXITCODE
    $sw.Stop()
    $out | Out-Host
    Write-Host ("refresh exit=" + $exit + " after " + [int]$sw.Elapsed.TotalSeconds + "s")
    $flat = (($out | Out-String) -replace '\s+', ' ')
    return [pscustomobject]@{ Exit = $exit; StartupTimedOut = ($flat -match 'wait for VIPM startup') }
}
$refresh = Invoke-Refresh
Show-StackState 'after refresh'

# -- Phase 5: capture diagnostics either way ----------------------------------
Write-Phase 'diagnostics'
# Any JKI/VIPM/LabVIEW log or config file touched since the container started
# gets copied out and its tail printed - these are the files the 900s bake
# failures never showed us.
$logRoots = @(
    'C:\ProgramData\JKI',
    "$env:APPDATA\JKI", "$env:LOCALAPPDATA\JKI",
    "$env:APPDATA\National Instruments", "$env:LOCALAPPDATA\National Instruments",
    "$env:USERPROFILE\Documents\LabVIEW Data"
) | Where-Object { Test-Path $_ }
foreach ($root in $logRoots) {
    Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.log', '.txt', '.ini', '.err' -or $_.Name -match 'error' } |
        ForEach-Object {
            $rel  = $_.FullName -replace '[:\\]+', '_'
            Copy-Item $_.FullName (Join-Path $OutDir $rel) -Force -ErrorAction SilentlyContinue
            Write-Host ("--- " + $_.FullName + " (last 40 lines) ---")
            Get-Content $_.FullName -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("  " + $_) }
        }
}
Write-Host '--- Settings.ini as VIPM left it ---'
Get-Content $VipmSettings -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("  " + $_) }
Write-Host '--- recent Application event log errors ---'
try {
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2 } -MaxEvents 25 -ErrorAction Stop |
        ForEach-Object { Write-Host ("  [" + $_.TimeCreated + "] " + $_.ProviderName + ": " + ($_.Message -replace "`r`n", ' | ')) }
} catch { Write-Host ("  (event log unavailable: " + $_.Exception.Message + ")") }

# -- Phase 6: optional variation - does the version STRING cause the wedge? ---
# If the honest seed (e.g. '26.3 (64-bit)') wedged, retry once with the last
# known-good string '26.1 (64-bit)' against the SAME binaries. PASS here means
# VIPM chokes on the version string / target matching, not on LabVIEW itself.
$variationResult = $null
if ($refresh.StartupTimedOut -and $Env:PROBE_VARIATIONS -eq '1' -and $seedVer -ne '26.1 (64-bit)') {
    Write-Phase 'variation-26.1-settings'
    foreach ($procName in @('vipm', 'VI Package Manager', 'LabVIEW')) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 10
    Remove-Item $VipmSettings -Force -ErrorAction SilentlyContinue
    Write-VipmSettings '26.1 (64-bit)'
    Start-Stack
    $variationResult = Invoke-Refresh
    Show-StackState 'after variation refresh'
}

# -- Verdict ------------------------------------------------------------------
Write-Phase 'verdict'
if (-not $refresh.StartupTimedOut -and $refresh.Exit -eq 0) {
    Write-Host "PROBE RESULT: PASS refresh succeeded with Settings.ini target '$seedVer'"
    exit 0
}
$detail = if ($refresh.StartupTimedOut) { 'VIPM Desktop startup handshake timed out' } else { "refresh exited $($refresh.Exit)" }
if ($variationResult) {
    if (-not $variationResult.StartupTimedOut -and $variationResult.Exit -eq 0) {
        Write-Host "PROBE RESULT: FAIL $detail with '$seedVer' BUT PASSED with '26.1 (64-bit)' - version-string/target matching is the trigger"
    } else {
        Write-Host "PROBE RESULT: FAIL $detail with '$seedVer' and also with '26.1 (64-bit)' - not the version string; engine cannot start against this container"
    }
} else {
    Write-Host "PROBE RESULT: FAIL $detail with Settings.ini target '$seedVer'"
}
exit 1
