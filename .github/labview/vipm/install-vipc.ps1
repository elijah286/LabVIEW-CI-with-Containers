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
# VIPM is an OPTIONAL CI add-on (used only to bake in VIPM-distributed packages
# such as Antidoc). It is fetched from an external, vendor-controlled installer
# URL that can move or 404 at any time, so a download/install failure must NOT
# brick the core CI image (LabVIEW + VI Analyzer were installed above). Treat this
# section as best-effort: on failure, warn and skip the add-ons (exit 0) instead
# of failing the whole image build.
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

foreach ($vipc in $vipcFiles) {
    Write-Host "Applying VIPC: $($vipc.Name)"
    & $VipmExe apply_vipc `
        -vipc_file          $vipc.FullName `
        -labview_version    $LabVIEWVersion `
        -accept_agreements  true
    if ($LASTEXITCODE -ne 0) {
        Write-Error "VIPM failed to apply '$($vipc.Name)' - exit code $LASTEXITCODE"
        exit 1
    }
}

Write-Host 'All VIPC files applied successfully.'
