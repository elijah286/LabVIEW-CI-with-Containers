<#
.SYNOPSIS
    Installs VIPM and applies all .vipc dependency files found in C:\vipm.
    This script runs INSIDE the Docker build container (Windows Server Core).

    Used to bake third-party VIPM add-ons into the CI image -- e.g. Antidoc
    (wovalab_lib_antidoc_cli), Wovalab's LabVIEW code-documentation generator,
    which is distributed only through VIPM and is the supported way to produce
    project documentation headlessly in CI/CD.

.NOTES
    These values can be overridden at image-build time via environment variables
    so the script does not need editing for each LabVIEW major version:
      LABVIEW_VERSION     LabVIEW year passed to `vipm install`; MUST match the
                          LabVIEW in the NI base image. Default: 2026.
      LABVIEW_BITNESS     LabVIEW bitness passed to `vipm install`. Default: 64.
      VIPM_INSTALLER_URL  VIPM community installer (https://vipm.jki.net) for a
                          VIPM build that supports LABVIEW_VERSION.

    Headless install model: the modern vipm CLI installs packages in Community
    Edition (no VIPM Pro license needed) -- the script sets VIPM_COMMUNITY_EDITION,
    VIPM_NONINTERACTIVE, VIPM_ASSUME_YES and NO_COLOR for unattended runs. It also
    launches LabVIEW headless before installing, because vipm requires a running
    LabVIEW or it fails with "IO error: Failed to load". VIPM Pro activation is
    still honored if VIPM_SERIAL_NUMBER / VIPM_FULL_NAME / VIPM_EMAIL are supplied.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference   = 'SilentlyContinue'

$VipmDir          = 'C:\Program Files\JKI\VI Package Manager'
$VipmExe          = $null
$VipcDir          = 'C:\vipm'
$LabVIEWVersion   = if ($Env:LABVIEW_VERSION)    { $Env:LABVIEW_VERSION }    else { '2026' }  # match the LabVIEW version in the NI base image
$LabVIEWBitness   = if ($Env:LABVIEW_BITNESS)    { $Env:LABVIEW_BITNESS }    else { '64' }    # NI base image ships 64-bit LabVIEW
$VipmInstallerUrl = if ($Env:VIPM_INSTALLER_URL) { $Env:VIPM_INSTALLER_URL } else { 'https://vipm.jki.net/l/download/vipm_2024_x64.exe' }

# Run VIPM non-interactively in Community Edition so headless installs need no
# VIPM Pro activation (verified against the official vipm-io GitHub Action, which
# defaults to Community Edition). These env vars are read by the modern vipm CLI;
# older CLIs ignore them harmlessly.
$Env:VIPM_COMMUNITY_EDITION = '1'
$Env:VIPM_NONINTERACTIVE    = '1'
$Env:VIPM_ASSUME_YES        = '1'
$Env:NO_COLOR               = '1'

# -- 1. Install VIPM if not already present -----------------------------------
# VIPM is normally pre-installed into the image from the NI Package Manager feed
# (package 'ni-vipm', done in labview-ci.Dockerfile), so this script just finds
# vipm.exe and applies the .vipc. If it is NOT already present we fall back to the
# external VIPM community installer, which is OPTIONAL and fetched from a
# vendor-controlled URL that can move or 404 at any time, so a download/install
# failure must NOT brick the core CI image (LabVIEW + VI Analyzer were installed
# above). Treat the fallback as best-effort: on failure, warn and skip the add-ons
# (exit 0) instead of failing the whole image build.
# Prefer the MODERN vipm CLI (C:\Program Files\JKI\VIPM) over the legacy
# LabVIEW-based CLI (C:\Program Files\JKI\VI Package Manager\...). The modern CLI
# has first-class headless/container support (refresh, -y, Community Edition mode)
# and installs packages without a VIPM Pro license.
$vipmCandidates = @(
    'C:\Program Files\JKI\VIPM\vipm.exe',
    'C:\Program Files (x86)\JKI\VIPM\vipm.exe',
    "$VipmDir\vipm.exe",
    "$VipmDir\support\vipm.exe"
)
$VipmExe = $vipmCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $VipmExe) {
    # Fall back to a recursive search of the JKI install roots, preferring any
    # path under a '\VIPM\' folder (the modern CLI) over the legacy product folder.
    $found = Get-ChildItem -Path 'C:\Program Files\JKI', 'C:\Program Files (x86)\JKI' `
        -Filter 'vipm.exe' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object @{ Expression = { $_.FullName -notmatch '\\VIPM\\' } }, FullName |
        Select-Object -First 1
    if ($found) { $VipmExe = $found.FullName }
}
if ($VipmExe) { Write-Host "Using VIPM CLI: $VipmExe" }
if (-not $VipmExe -or -not (Test-Path $VipmExe)) {
    Write-Host 'VIPM not found - downloading installer...'
    $InstallerFile = Join-Path $Env:TEMP 'vipm-installer.exe'
    try {
        Invoke-WebRequest -Uri $VipmInstallerUrl -OutFile $InstallerFile -UseBasicParsing

        Write-Host 'Running VIPM installer silently...'
        $p = Start-Process -FilePath $InstallerFile `
            -ArgumentList '/SILENT', '/NORESTART' `
            -Wait -PassThru
        if ($p.ExitCode -ne 0) {
            throw "VIPM installer exited with code $($p.ExitCode)"
        }
        Write-Host "VIPM installed to: $VipmDir"
        $VipmExe = $vipmCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $VipmExe) { $VipmExe = "$VipmDir\vipm.exe" }
    }
    catch {
        Write-Warning ("VIPM add-on install SKIPPED: could not install VIPM from '" + $VipmInstallerUrl + "' (" + $_.Exception.Message + "). " +
            "Core image (LabVIEW + VI Analyzer) is unaffected; VIPM-only add-ons such as Antidoc are NOT baked in. " +
            "Provide a reachable VIPM_INSTALLER_URL to enable them.")
        exit 0
    }
}

# -- 2. Apply each .vipc file -------------------------------------------------
$vipcFiles = @(Get-ChildItem $VipcDir -Filter '*.vipc')
if ($vipcFiles.Count -eq 0) {
    Write-Host 'No .vipc files found - nothing to apply.'
    exit 0
}

# Native VIPM commands below emit to stderr on normal progress; do not let that
# abort the script - we drive control flow off $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'

# Diagnostics: record which VIPM CLI we have. The 'ni-vipm' build baked into this
# image is the modern VIPM CLI (2024+), whose 'install' verb REJECTS the
# config.xml-only .vipc generated by build-tooling-vipc.py ("Code 42: this file
# does not appear to be a valid VI package configuration") and which no longer has
# the legacy 'apply_vipc' verb at all. So instead of applying the .vipc FILE, we
# read the package list out of its config.xml and install each package BY NAME
# using the documented 'vipm install <name>@<version>' form - the reliable path
# that needs no VIPM Pro activation (verified against VIPM 2026 Free Edition).
& $VipmExe --version 2>&1 | Out-Host
& $VipmExe about    2>&1 | Out-Host

# Optional VIPM Pro activation. With VIPM_COMMUNITY_EDITION=1 set above, headless
# installs work WITHOUT a Pro license, so activation is optional. If the
# VIPM_SERIAL_NUMBER / VIPM_FULL_NAME / VIPM_EMAIL build secrets are supplied we
# still activate Pro (best-effort: a failure here does not stop the build).
if ($Env:VIPM_SERIAL_NUMBER) {
    Write-Host 'Activating VIPM Pro from VIPM_SERIAL_NUMBER ...'
    & $VipmExe activate `
        --serial-number $Env:VIPM_SERIAL_NUMBER `
        --name          $Env:VIPM_FULL_NAME `
        --email         $Env:VIPM_EMAIL 2>&1 | Out-Host
} else {
    Write-Host 'VIPM_SERIAL_NUMBER not set; using VIPM Community Edition (no Pro license required).'
}

# The modern vipm CLI requires LabVIEW to be RUNNING (headless) before it can
# install/build packages -- otherwise it fails to load with "IO error: Failed to
# load". The Docker build step that calls this script does NOT have LabVIEW
# running, so launch it headless in the background now and wait for the VI Server
# port (default 3363) to come up. Best-effort: if LabVIEW can't be found/started
# we still attempt the install (it may already be running).
$LabVIEWProc = $null
$lvExe = @(
    'C:\Program Files\National Instruments',
    'C:\Program Files (x86)\National Instruments'
) | Where-Object { Test-Path $_ } |
    ForEach-Object { Get-ChildItem -Path $_ -Directory -Filter 'LabVIEW*' -ErrorAction SilentlyContinue } |
    ForEach-Object { Join-Path $_.FullName 'LabVIEW.exe' } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if ($lvExe) {
    Write-Host "Launching headless LabVIEW for VIPM: $lvExe"
    try {
        $LabVIEWProc = Start-Process -FilePath $lvExe -ArgumentList '--headless' -PassThru
        $deadline = (Get-Date).AddSeconds(180)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $client.Connect('127.0.0.1', 3363)
                if ($client.Connected) { $client.Close(); $ready = $true; break }
            } catch { Start-Sleep -Seconds 3 }
        }
        if ($ready) { Write-Host 'Headless LabVIEW VI Server is ready (port 3363).' }
        else        { Write-Warning 'Timed out waiting for LabVIEW VI Server (port 3363); attempting VIPM install anyway.' }
    } catch {
        Write-Warning ("Could not launch headless LabVIEW (" + $_.Exception.Message + "); attempting VIPM install anyway.")
    }
} else {
    Write-Warning 'LabVIEW.exe not found; attempting VIPM install without pre-launching LabVIEW.'
}

# Refresh repository metadata so installs see current package versions
# (correct modern verb is 'refresh'; best-effort -- ignored if unsupported).
& $VipmExe refresh 2>&1 | Out-Host

# Read the package list out of a .vipc's config.xml and return install specs.
# The config.xml lists each package as '<Package><Name>pkg_name-1.2.3.4</Name>...';
# the modern 'vipm install' wants 'pkg_name@1.2.3.4' (the hyphen form is misread as
# a file path). Names without a trailing dotted version (e.g. 'jki_vi_tester')
# install the latest available.
function Get-VipcPackageSpecs([string]$VipcPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = [System.IO.Compression.ZipFile]::OpenRead($VipcPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.Name -eq 'config.xml' } | Select-Object -First 1
        if (-not $entry) { return @() }
        $reader = New-Object System.IO.StreamReader($entry.Open())
        try { [xml]$cfg = $reader.ReadToEnd() } finally { $reader.Close() }
    } finally { $zip.Dispose() }
    $names = @($cfg.VI_Package_Configuration.Target.Package | ForEach-Object { $_.Name })
    $specs = foreach ($n in $names) {
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        if ($n -match '^(?<n>.+)-(?<v>\d+(?:\.\d+)+)$') { '{0}@{1}' -f $Matches.n, $Matches.v } else { $n.Trim() }
    }
    return @($specs)
}

$applyFailed = $false
$InstallFlags = @('-y', '--labview-version', $LabVIEWVersion, '--labview-bitness', $LabVIEWBitness)
foreach ($vipc in $vipcFiles) {
    Write-Host "Resolving packages from VIPC: $($vipc.Name)"
    $specs = @(Get-VipcPackageSpecs $vipc.FullName)
    if ($specs.Count -eq 0) {
        # Could not parse package names - last resort: try installing the file directly
        # (works only if a real, VIPM-editor-made .vipc was dropped in).
        Write-Host "  no packages parsed from config.xml; trying 'vipm install <file.vipc>' directly ..."
        & $VipmExe install $vipc.FullName @InstallFlags 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "VIPM could not install from '$($vipc.Name)' (exit $LASTEXITCODE)."
            $applyFailed = $true
        }
        continue
    }
    Write-Host ("  Installing by name: " + ($specs -join ', '))
    & $VipmExe install @specs @InstallFlags 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  batch install failed (exit $LASTEXITCODE); retrying each package individually ..."
        foreach ($spec in $specs) {
            & $VipmExe install $spec @InstallFlags 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "  package '$spec' failed (exit $LASTEXITCODE)."
                $applyFailed = $true
            }
        }
    }
}

# Stop the headless LabVIEW we launched for the install (best-effort).
if ($LabVIEWProc -and -not $LabVIEWProc.HasExited) {
    Write-Host 'Stopping headless LabVIEW...'
    try { $LabVIEWProc | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
}

if ($applyFailed) {
    Write-Warning ('One or more VIPM packages could not be installed. VIPM-distributed add-ons ' +
        '(Antidoc, Caraya, VI Tester, and the UTF JUnit Report library that the RunUnitTests ' +
        'CLI operation links against to emit its JUnit report) may be absent, so headless UTF ' +
        'may fail with LabVIEW CLI error -350053. Check the install log above for the failing ' +
        'package(s) and confirm they exist on the configured VIPM repository. Core image ' +
        '(LabVIEW + VI Analyzer + UTF) is unaffected.')
    # Best-effort: never fail the whole image build over optional VIPM add-ons.
    exit 0
}

Write-Host 'All VIPM packages installed successfully.'
