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
      LABVIEW_VERSION     LabVIEW year passed to `vipm apply_vipc`; MUST match the
                          LabVIEW in the NI base image. Default: 2026.
      VIPM_INSTALLER_URL  VIPM community installer (https://vipm.jki.net) for a
                          VIPM build that supports LABVIEW_VERSION.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference   = 'SilentlyContinue'

$VipmDir          = 'C:\Program Files\JKI\VI Package Manager'
$VipmExe          = "$VipmDir\vipm.exe"
$VipcDir          = 'C:\vipm'
$LabVIEWVersion   = if ($Env:LABVIEW_VERSION)    { $Env:LABVIEW_VERSION }    else { '2026' }  # match the LabVIEW version in the NI base image
$VipmInstallerUrl = if ($Env:VIPM_INSTALLER_URL) { $Env:VIPM_INSTALLER_URL } else { 'https://vipm.jki.net/l/download/vipm_2024_x64.exe' }

# -- 1. Install VIPM if not already present -----------------------------------
# VIPM is normally pre-installed into the image from the NI Package Manager feed
# (package 'ni-vipm', done in labview-ci.Dockerfile), so this script just finds
# vipm.exe and applies the .vipc. If it is NOT already present we fall back to the
# external VIPM community installer, which is OPTIONAL and fetched from a
# vendor-controlled URL that can move or 404 at any time, so a download/install
# failure must NOT brick the core CI image (LabVIEW + VI Analyzer were installed
# above). Treat the fallback as best-effort: on failure, warn and skip the add-ons
# (exit 0) instead of failing the whole image build.
if (-not (Test-Path $VipmExe)) {
    # The nipkg-installed VIPM may land at a slightly different path than the
    # default; search the common install roots before resorting to a download.
    $found = Get-ChildItem -Path 'C:\Program Files\JKI', 'C:\Program Files (x86)\JKI' `
        -Filter 'vipm.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
        $VipmExe = $found.FullName
        Write-Host "Found VIPM at: $VipmExe"
    }
}
if (-not (Test-Path $VipmExe)) {
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

# Diagnostics: record which VIPM CLI we have. VIPM 2024+ ships a rewritten CLI
# where the legacy 'apply_vipc' verb was replaced by 'vipm install <file.vipc>';
# older VIPM builds use 'apply_vipc'. We try the new syntax first and fall back
# to the legacy one, so this works across VIPM generations.
& $VipmExe version 2>&1 | Out-Host

# Optional VIPM Pro activation. The modern VIPM CLI requires VIPM Pro activation
# for headless/CI use (see https://docs.vipm.io/latest/cli/github-actions/).
# Supply credentials via the VIPM_SERIAL_NUMBER / VIPM_FULL_NAME / VIPM_EMAIL
# build secrets to enable it. Best-effort: a failure here does not stop the build.
if ($Env:VIPM_SERIAL_NUMBER) {
    Write-Host 'Activating VIPM Pro from VIPM_SERIAL_NUMBER ...'
    & $VipmExe activate `
        --serial-number $Env:VIPM_SERIAL_NUMBER `
        --name          $Env:VIPM_FULL_NAME `
        --email         $Env:VIPM_EMAIL 2>&1 | Out-Host
} else {
    Write-Host 'VIPM_SERIAL_NUMBER not set; skipping VIPM Pro activation (the modern VIPM CLI may require it for headless installs).'
}

# Refresh repository metadata (new CLI verb; harmless/ignored if unsupported).
& $VipmExe package-list-refresh 2>&1 | Out-Host

$applyFailed = $false
foreach ($vipc in $vipcFiles) {
    Write-Host "Applying VIPC: $($vipc.Name)"
    # New VIPM CLI (2024+): 'vipm install <file.vipc> --labview-version <year>'.
    & $VipmExe install $vipc.FullName --labview-version $LabVIEWVersion 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  modern 'install' verb failed (exit $LASTEXITCODE); trying legacy 'apply_vipc' ..."
        & $VipmExe apply_vipc `
            -vipc_file          $vipc.FullName `
            -labview_version    $LabVIEWVersion `
            -accept_agreements  true 2>&1 | Out-Host
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "VIPM could not apply '$($vipc.Name)' (exit $LASTEXITCODE)."
        $applyFailed = $true
    }
}

if ($applyFailed) {
    Write-Warning ('One or more VIPC files could not be applied. VIPM-distributed add-ons ' +
        '(Antidoc, Caraya, VI Tester, and the UTF JUnit Report library that the RunUnitTests ' +
        'CLI operation links against) may be absent. The modern VIPM CLI requires VIPM Pro ' +
        'activation for headless use - set the VIPM_SERIAL_NUMBER / VIPM_FULL_NAME / VIPM_EMAIL ' +
        'build secrets to enable it. Core image (LabVIEW + VI Analyzer + UTF) is unaffected.')
    # Best-effort: never fail the whole image build over optional VIPM add-ons.
    exit 0
}

Write-Host 'All VIPC files applied successfully.'
