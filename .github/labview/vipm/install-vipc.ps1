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

    Headless install model: the vipm CLI installs packages in Community Edition
    (no VIPM Pro license needed) -- the script sets VIPM_COMMUNITY_EDITION and
    NO_COLOR for unattended runs (the CLI is non-interactive by default). It also
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
$VipmInstallerUrl = if ($Env:VIPM_INSTALLER_URL) { $Env:VIPM_INSTALLER_URL } else { 'https://traffic.libsyn.com/secure/jkinc/vipm-26.3.3954-windows-setup.exe' }
# VIPM 26.3 Community Edition only installs packages when the working directory is
# inside a PUBLIC Git repository (otherwise it exits 6 with "VIPM Community Edition
# requires a public Git repository"). The worker image is built from this public
# repo, so we run the installs from a tiny working dir whose origin remote points
# at it. Override with VIPM_PUBLIC_REPO_URL (the build workflow passes the actual
# building repo's clone URL so forks use their own public repo).
$PublicRepoUrl    = if ($Env:VIPM_PUBLIC_REPO_URL) { $Env:VIPM_PUBLIC_REPO_URL } else { 'https://github.com/elijah286/LabVIEW-CI-with-Containers.git' }

# Run VIPM non-interactively so headless installs need no prompts. We deliberately
# do NOT set VIPM_COMMUNITY_EDITION here: forcing Community Edition mode turns ON
# VIPM's public-Git-repository entitlement gate (exit 6, "VIPM Community Edition
# requires a public Git repository"), which blocks installs inside the sealed
# `docker build` layer. The CLI already runs as Community Edition by default WITHOUT
# enforcing that gate, so installs proceed and no VIPM Pro license is needed.
# (If VIPM_COMMUNITY_EDITION=1 is supplied externally we honor it, and the MinGit +
# public-repo .git context below then satisfies the gate.) These env vars are read
# by the modern vipm CLI; older CLIs ignore them harmlessly.
$Env:VIPM_NONINTERACTIVE    = '1'
$Env:VIPM_ASSUME_YES        = '1'
$Env:NO_COLOR               = '1'
# Turn on VIPM's verbose debug log so a failing build records WHY an install
# fails - e.g. why `vipm refresh` reports success yet `vipm install <name>`
# returns exit 3 "package not found" (an empty resolver index), and why applying
# the .vipc file returns Code 42. Overridable: set VIPM_DEBUG=0 to quiet it once
# the install path is proven. See docs.vipm.io/latest/cli/environment-variables.
$Env:VIPM_DEBUG             = if ($null -ne $Env:VIPM_DEBUG -and $Env:VIPM_DEBUG -ne '') { $Env:VIPM_DEBUG } else { '1' }
# Make VIPM treat this `docker build` step as a CI environment. The official VIPM
# docs note the CLI auto-detects CI from these env vars and then uses its longer,
# CI-tuned default timeouts and non-interactive behavior; during `docker build`
# none of them are set, so VIPM falls back to short desktop defaults that can
# abort a cold headless LabVIEW. (VIPM_TIMEOUT still overrides the actual value.)
if (-not $Env:CI)             { $Env:CI = 'true' }
if (-not $Env:GITHUB_ACTIONS)  { $Env:GITHUB_ACTIONS = 'true' }
# VIPM has "several ways" to decide a repo is public, INCLUDING the environment
# (per JKI). In GitHub Actions these are set automatically, but inside `docker
# build` they are absent, so derive them from the public repo URL and export them
# for VIPM's environment-based public-repo detection. (Owner/name parsed from
# https://github.com/<owner>/<name>.git.) Do not clobber values already present.
if ($PublicRepoUrl -match 'github\.com[:/]+(?<owner>[^/]+)/(?<name>[^/]+?)(?:\.git)?/?$') {
    if (-not $Env:GITHUB_SERVER_URL)       { $Env:GITHUB_SERVER_URL = 'https://github.com' }
    if (-not $Env:GITHUB_REPOSITORY)        { $Env:GITHUB_REPOSITORY = "$($Matches.owner)/$($Matches.name)" }
    if (-not $Env:GITHUB_REPOSITORY_OWNER) { $Env:GITHUB_REPOSITORY_OWNER = $Matches.owner }
}
# Bound the per-operation timeout. During `docker build` the GITHUB_ACTIONS / CI
# env vars are NOT present, so VIPM does not apply its longer "CI" default timeouts
# and its short defaults (check_for_updates ~270s, library_list ~330s) can abort a
# cold, first-run headless LabVIEW before it finishes responding. VIPM_TIMEOUT
# overrides the default/CI-adjusted timeout, in seconds.
# See docs.vipm.io/latest/cli/environment-variables.
$Env:VIPM_TIMEOUT           = if ($Env:VIPM_TIMEOUT) { $Env:VIPM_TIMEOUT } else { '900' }

# VIPM 26.3 Community Edition shells out to a real `git` binary to verify that the
# working directory is a PUBLIC Git repository (see New-PublicRepoWorkdir below). The
# Windows base image has no git on PATH; labview-ci.Dockerfile bakes portable MinGit
# into C:\git, so make sure git is discoverable by vipm's child process. Without this
# vipm fails with "Cannot determine repository visibility: ... git: program not found".
foreach ($gitDir in @('C:\git\cmd', 'C:\Program Files\Git\cmd')) {
    if ((Test-Path (Join-Path $gitDir 'git.exe')) -and ($Env:Path -notlike "*$gitDir*")) {
        $Env:Path = "$gitDir;$Env:Path"
    }
}

# -- 1. Install VIPM if not already present -----------------------------------
# VIPM is normally pre-installed into the image by labview-ci.Dockerfile, which
# downloads the official VIPM 2026 Q3 (26.3.3954) Windows installer from the JKI
# CDN and runs it silently, so this script just finds vipm.exe and applies the
# .vipc. If it is NOT already present we fall back to downloading the same
# installer here ($VipmInstallerUrl, overridable via VIPM_INSTALLER_URL). That
# fallback is OPTIONAL and fetched from a vendor-controlled URL that can move or
# 404 at any time, so a download/install failure must NOT brick the core CI image
# (LabVIEW + VI Analyzer were installed above). Treat the fallback as best-effort:
# on failure, warn and skip the add-ons (exit 0) instead of failing the build.
# Prefer the MODERN vipm CLI (C:\Program Files\JKI\VIPM) over the legacy
# LabVIEW-based CLI (C:\Program Files\JKI\VI Package Manager\...). The modern CLI
# has first-class headless/container support (--refresh, Community Edition mode)
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
            -ArgumentList '/exenoui', '/qn' `
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
        exit 1
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

# The vipm CLI reads C:\ProgramData\JKI\VIPM\Settings.ini for its target LabVIEW
# configuration and ABORTS with "IO error: Failed to load ...Settings.ini ...
# (os error 2)" if that file is missing. In a fresh image VIPM was never launched
# interactively, so the file does not exist. Seed a minimal Settings.ini that
# points the CLI at the image's LabVIEW (so `--labview-version <year>` resolves)
# before any install. Only create it if absent so a real VIPM never gets clobbered.
$VipmSettingsDir = 'C:\ProgramData\JKI\VIPM'
$VipmSettings    = Join-Path $VipmSettingsDir 'Settings.ini'
if ($lvExe -and -not (Test-Path $VipmSettings)) {
    try {
        $fi  = (Get-Item $lvExe).VersionInfo
        $ver = '{0}.{1} ({2}-bit)' -f $fi.ProductMajorPart, $fi.ProductMinorPart, $LabVIEWBitness
        # INI wants the exe path in "/C/Program Files/.../LabVIEW.exe" form.
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
    } catch {
        Write-Warning ("Could not seed VIPM Settings.ini (" + $_.Exception.Message + "); vipm install may fail to load.")
    }
}
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

# The vipm CLI does not install packages itself -- it delegates to the VIPM "engine"
# application (VI Package Manager.exe, the LabVIEW-runtime VIPM app). When that engine
# is not already running the CLI tries to start it and BLOCKS on "wait for VIPM
# startup"; in a fresh headless container that startup never completed, so
# `vipm install` aborted after the full VIPM_TIMEOUT ("Operation 'wait for VIPM
# startup' timed out after 900s"). Locally the install works only because the VIPM
# engine is already running. Pre-launch the engine here (best-effort) and give it
# time to come up so the install can attach to an already-running engine.
$VipmEngineProc = $null
$vipmEngineExe = @(
    (Join-Path $VipmDir 'VI Package Manager.exe'),
    'C:\Program Files (x86)\JKI\VI Package Manager\VI Package Manager.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($vipmEngineExe -and -not (Get-Process -Name 'VI Package Manager' -ErrorAction SilentlyContinue)) {
    Write-Host "Pre-launching VIPM engine so the CLI can attach: $vipmEngineExe"
    try {
        $VipmEngineProc = Start-Process -FilePath $vipmEngineExe -PassThru -ErrorAction Stop
        # Give the LabVIEW-runtime engine time to initialize before the first install.
        Start-Sleep -Seconds 45
        Write-Host 'VIPM engine launch requested (allowed 45s to initialize).'
    } catch {
        Write-Warning ("Could not pre-launch the VIPM engine (" + $_.Exception.Message + "); the CLI will try to start it itself.")
    }
}

# NOTE: this vipm CLI (2026.1.0) has NO standalone 'refresh' command; the package
# list is refreshed via the global '--refresh' option passed to 'install' below.

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

function Split-VipmPackageSpec([string] $Spec) {
    $s = ([string]$Spec).Trim()
    $aliases = @{
        # Older VIPC files can use the short/legacy VI Tester name, while the
        # public VIPM repository indexes expose the package under this ID.
        'jki_vi_tester' = 'jki_labs_tool_vi_tester'
    }
    if ($s -match '^(?<name>[^@]+)@(?<version>.+)$') {
        $name = $Matches.name.Trim()
        if ($aliases.ContainsKey($name)) { $name = $aliases[$name] }
        return [pscustomobject]@{ Name = $name; Version = $Matches.version.Trim(); Minimum = $false }
    }
    if ($s -match '^(?<name>[A-Za-z0-9_\.\-]+)\s*>\=\s*(?<version>.+)$') {
        $name = $Matches.name.Trim()
        if ($aliases.ContainsKey($name)) { $name = $aliases[$name] }
        return [pscustomobject]@{ Name = $name; Version = $Matches.version.Trim(); Minimum = $true }
    }
    if ($aliases.ContainsKey($s)) { $s = $aliases[$s] }
    return [pscustomobject]@{ Name = $s; Version = ''; Minimum = $false }
}

function Get-NumericVersionKey([string] $Version) {
    $nums = @([regex]::Matches(([string]$Version), '\d+') | ForEach-Object { [int]$_.Value })
    while ($nums.Count -lt 6) { $nums += 0 }
    return ($nums[0..5] | ForEach-Object { '{0:D8}' -f $_ }) -join '.'
}

function ConvertFrom-VipmRepositoryIndex([string] $IndexPath, [string] $BaseUrl, [string] $Name) {
    $packages = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in Get-Content -LiteralPath $IndexPath -ErrorAction Stop) {
        if ($line -match '^\[Package\s+(?<id>.+)\]\s*$') {
            if ($current) { $packages.Add($current) }
            $id = $Matches.id.Trim()
            $pkgName = $id
            $pkgVersion = ''
            if ($id -match '^(?<name>.+)-(?<version>\d+(?:\.\d+)+(?:[A-Za-z0-9_.-]*)?)$') {
                $pkgName = $Matches.name
                $pkgVersion = $Matches.version
            }
            $current = [ordered]@{
                Id          = $id
                Name        = $pkgName
                Version     = $pkgVersion
                VersionKey  = Get-NumericVersionKey $pkgVersion
                Repository  = $Name
                BaseUrl     = $BaseUrl
                PackageUrl  = ''
                PackageMD5  = ''
                Dependencies = ''
            }
            continue
        }
        if (-not $current) { continue }
        if ($line -match '^(?<key>[^=]+)=(?<value>.*)$') {
            $key = $Matches.key.Trim()
            $value = $Matches.value.Trim()
            switch ($key) {
                'Package.URL' { $current.PackageUrl = $value }
                'Package.MD5' { $current.PackageMD5 = $value.ToLowerInvariant() }
                'Dependencies.Requires' { $current.Dependencies = $value }
            }
        }
    }
    if ($current) { $packages.Add($current) }
    return @($packages | ForEach-Object { [pscustomobject]$_ })
}

function Get-PublicVipmRepositoryPackages {
    $repoDir = Join-Path $env:TEMP 'vipm-public-indexes'
    New-Item -ItemType Directory -Force -Path $repoDir | Out-Null
    $repos = @(
        [pscustomobject]@{
            Name = 'NI LabVIEW Tools Network'
            Url = 'http://download.ni.com/evaluation/labview/lvtn/vipm/index.vipr'
            BaseUrl = 'http://download.ni.com/evaluation/labview/lvtn/vipm/'
            FileName = 'ni-lvtn.vipr'
        },
        [pscustomobject]@{
            Name = 'VIPM Community'
            Url = 'http://www.jkisoft.com/packages/jkisoft.ogpd'
            BaseUrl = 'http://www.jkisoft.com/packages/'
            FileName = 'vipm-community.ogpd'
        }
    )
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($repo in $repos) {
        $indexFile = Join-Path $repoDir $repo.FileName
        Write-Host "Downloading public VIPM repository index: $($repo.Url)"
        Invoke-WebRequest -Uri $repo.Url -OutFile $indexFile -UseBasicParsing -TimeoutSec 120 | Out-Null
        foreach ($pkg in (ConvertFrom-VipmRepositoryIndex $indexFile $repo.BaseUrl $repo.Name)) { $all.Add($pkg) }
    }
    Write-Host "Loaded $($all.Count) package versions from public VIPM indexes."
    return @($all.ToArray())
}

function Resolve-PublicVipmPackageUrl($Package) {
    $url = [string]$Package.PackageUrl
    if ($url -match '^https?://') { return $url }
    if ($url -match '^packages/') { return ([string]$Package.BaseUrl).TrimEnd('/') + '/' + $url }
    if ($url -match '^sf://opengtoolkit/(?<file>[^/]+)$') {
        $file = $Matches.file
        if ($Package.Name -match '^oglib_(?<lib>.+)$') {
            $lib = $Matches.lib
            $major = if ($Package.Version -match '^(?<major>\d+)\.') { $Matches.major } else { '4' }
            return "https://downloads.sourceforge.net/project/opengtoolkit/lib_$lib/$major.x/$file`?download"
        }
    }
    if ($url -match '^sf://(?<project>[^/]+)/(?<file>[^/]+)$') {
        return "https://downloads.sourceforge.net/project/$($Matches.project)/$($Matches.file)`?download"
    }
    if ($url) { return ([string]$Package.BaseUrl).TrimEnd('/') + '/' + $url.TrimStart('/') }
    return ''
}

function Select-PublicVipmPackage($Request, [object[]] $Packages) {
    $matches = @($Packages | Where-Object { $_.Name -eq $Request.Name })
    if ($matches.Count -eq 0) { return $null }
    if ($Request.Version) {
        if ($Request.Minimum) {
            $minKey = Get-NumericVersionKey $Request.Version
            $matches = @($matches | Where-Object { $_.VersionKey -ge $minKey })
        } else {
            $matches = @($matches | Where-Object { $_.Version -eq $Request.Version })
        }
    }
    return @($matches | Sort-Object VersionKey -Descending | Select-Object -First 1)[0]
}

function Get-PublicVipmDependencyRequests($Package) {
    $deps = @()
    $text = [string]$Package.Dependencies
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    foreach ($part in ($text -split ',')) {
        $p = $part.Trim()
        if ($p -match '^(?<name>[A-Za-z0-9_\.\-]+)\s*(?<op>>=|=|==)?\s*(?<version>[A-Za-z0-9_.\-]+)?') {
            $op = [string]$Matches.op
            $deps += [pscustomobject]@{
                Name = $Matches.name.Trim()
                Version = if ($Matches.version) { $Matches.version.Trim() } else { '' }
                Minimum = ($op -eq '>=' -or -not $op)
            }
        }
    }
    return @($deps)
}

function Save-PublicVipmPackage($Package, [string] $OutDir) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $ext = '.vip'
    if ([string]$Package.PackageUrl -match '\.(?<ext>vip|ogp)(?:$|\?)') { $ext = '.' + $Matches.ext }
    $fileName = '{0}-{1}{2}' -f $Package.Name, $Package.Version, $ext
    $outFile = Join-Path $OutDir $fileName
    if (Test-Path $outFile) { return $outFile }
    $url = Resolve-PublicVipmPackageUrl $Package
    if (-not $url) { throw "No downloadable package URL found for $($Package.Id) from $($Package.Repository)." }
    Write-Host "  Downloading $($Package.Id) from $url"
    Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing -MaximumRedirection 10 -TimeoutSec 300 -Headers @{ 'User-Agent' = 'LabVIEW-CI-with-Containers VIPM downloader' } | Out-Null
    $bytes = Get-Content -LiteralPath $outFile -Encoding Byte -TotalCount 4
    if ($bytes.Count -lt 4 -or $bytes[0] -ne 0x50 -or $bytes[1] -ne 0x4b) {
        throw "Downloaded file for $($Package.Id) is not a VIP/ZIP archive: $outFile"
    }
    if ($Package.PackageMD5) {
        $md5 = (Get-FileHash -LiteralPath $outFile -Algorithm MD5).Hash.ToLowerInvariant()
        if ($md5 -ne $Package.PackageMD5) { throw "MD5 mismatch for $($Package.Id): expected $($Package.PackageMD5), got $md5" }
    }
    return $outFile
}

function Get-LocalVipFilesForSpecs([string[]] $Specs) {
    $repoPackages = @(Get-PublicVipmRepositoryPackages)
    $rootRequests = @($Specs | ForEach-Object { Split-VipmPackageSpec $_ })
    $exactByName = @{}
    foreach ($root in $rootRequests) {
        if ($root.Version -and -not $root.Minimum) { $exactByName[$root.Name] = $root }
    }
    $resolved = New-Object System.Collections.Generic.List[object]
    $visiting = @{}
    $visited = @{}
    $visitedPackageIds = @{}

    function Resolve-One($Request, [bool]$IsDependency = $false) {
        if ($Request.Minimum -and $exactByName.ContainsKey($Request.Name)) {
            $Request = $exactByName[$Request.Name]
        }
        $key = '{0}@{1}:{2}' -f $Request.Name, $Request.Version, $Request.Minimum
        if ($visited.ContainsKey($key)) { return }
        if ($visiting.ContainsKey($key)) { return }
        $visiting[$key] = $true
        $pkg = Select-PublicVipmPackage $Request $repoPackages
        if (-not $pkg) {
            $vtext = if ($Request.Version) { " version '$($Request.Version)'" } else { '' }
            # A ROOT request that can't be resolved is fatal. A transitive
            # DEPENDENCY that isn't in any reachable index is skipped with a warning:
            # some packages declare a dependency whose content is bundled inside the
            # parent .vip and is never published standalone (e.g. the LUnit CLI lists
            # astemes_lib_lunit_cli_system, which ships inside the CLI package). VIPM
            # installs the parent fine without a separate file for it.
            if ($IsDependency) {
                Write-Warning ("  Skipping dependency '$($Request.Name)'$vtext" + ": not in the reachable public VIPM indexes (assumed bundled in its parent package).")
                $visited[$key] = $true
                $visiting.Remove($key)
                return
            }
            throw "Package '$($Request.Name)'$vtext was not found in the public VIPM indexes."
        }
        if ($visitedPackageIds.ContainsKey($pkg.Id)) {
            $visited[$key] = $true
            $visiting.Remove($key)
            return
        }
        foreach ($dep in (Get-PublicVipmDependencyRequests $pkg)) { Resolve-One $dep $true }
        $resolved.Add($pkg)
        $visitedPackageIds[$pkg.Id] = $true
        $visited[$key] = $true
        $visiting.Remove($key)
    }

    foreach ($root in $rootRequests) { Resolve-One $root $false }
    $downloadDir = Join-Path $env:TEMP 'vipm-package-files'
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($pkg in $resolved) { $files.Add((Save-PublicVipmPackage $pkg $downloadDir)) }
    return @($files.ToArray() | Select-Object -Unique)
}

$applyFailed = $false
# Set when a best-effort tooling VIPC (ci-tooling*) does not fully install. This is
# surfaced as a warning but does NOT fail the image build (the required essentials
# and project dependencies are what gate CI correctness).
$script:bestEffortFailed = $false
# Set once a VIPM call reports the engine-startup timeout. After that the headless
# VIPM engine is wedged and will NOT recover within this build, so every subsequent
# 'vipm install' would burn another full VIPM_TIMEOUT (900s) before failing. We use
# this flag to abort the remaining install attempts immediately rather than stacking
# 15-minute timeouts into a multi-hour hang (build 27910621710 ran 90+ min that way).
$script:VipmEngineDead = $false
#   * --labview-version / --labview-bitness are GLOBAL options and must PRECEDE the
#     'install' subcommand; they target the LabVIEW baked into the image.
#   * There is NO '--refresh' option on 'install' anymore - the package list is
#     updated by the SEPARATE 'vipm refresh' command (run once below). (In the older
#     2026.1.0 CLI '--refresh' was a global option; 26.3 removed it - passing it now
#     fails with exit 2 COMMAND_SYNTAX_ERROR: "unexpected argument '--refresh'".)
#   * The CLI is non-interactive via the VIPM_NONINTERACTIVE / VIPM_ASSUME_YES env
#     vars set above, so no '-y' is required.
$GlobalFlags = @('--labview-version', $LabVIEWVersion, '--labview-bitness', $LabVIEWBitness)

# Run 'vipm install' with the global LabVIEW target flags in front of the subcommand.
# Exit 2 (COMMAND_SYNTAX_ERROR) means this CLI build rejected the flag position; fall
# back to the bare form, which targets the active LabVIEW from the seeded Settings.ini.
function Invoke-VipmInstall {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Targets)
    $out = & $VipmExe @GlobalFlags install @Targets 2>&1
    $out | Out-Host
    if ($LASTEXITCODE -eq 2) {
        Write-Host '  (install rejected global LabVIEW flags; retrying bare form against active target)'
        $out = & $VipmExe install @Targets 2>&1
        $out | Out-Host
    }
    # Stash the CLI text so callers can distinguish failure causes that share exit
    # code 8 (IO_ERROR) - e.g. the engine-startup timeout vs. the engine rejecting
    # the .vipc file itself. Capture WIDE: Out-String wraps at the host buffer width
    # (default 120) and can split a message mid-phrase, which previously made the
    # detector below MISS a wrapped 'wait for VIPM startup' line - so the build kept
    # stacking 900s timeouts for every remaining package instead of bailing once.
    $script:LastVipmOutput = ($out | Out-String -Width 8192)
    # Match against a whitespace-flattened copy so a wrap can never hide the phrase.
    $flatVipmOutput = ($script:LastVipmOutput -replace '\s+', ' ')
    # A 'wait for VIPM startup' timeout means the engine is wedged for the rest of
    # this build; record it so callers stop hammering it (each retry costs ~900s).
    if ($flatVipmOutput -match 'wait for VIPM startup') { $script:VipmEngineDead = $true }
    return $LASTEXITCODE
}

# Install a set of package SPECS (name@version) using the by-name path first and,
# when the container resolver index is empty, the public-index local-file fallback.
# Returns $true only if every spec installed. Stops early (returns $false) the
# moment the VIPM engine wedges so we never stack 900s timeouts.
function Install-VipmSpecs {
    param([string[]] $Specs)
    if (-not $Specs -or $Specs.Count -eq 0) { return $true }
    Write-Host ("  Installing by name: " + ($Specs -join ', '))
    $rc = Invoke-VipmInstall @Specs
    $failed = $false
    if ($rc -ne 0) {
        Write-Host "  batch install failed (exit $rc); retrying each package individually ..."
        foreach ($spec in $Specs) {
            $rc = Invoke-VipmInstall $spec
            if ($rc -ne 0) { Write-Warning "  package '$spec' failed (exit $rc)."; $failed = $true }
            if ($script:VipmEngineDead) { Write-Warning '  VIPM engine wedged; stopping per-package retries.'; return $false }
        }
    }
    if ($rc -eq 0 -and -not $failed) { return $true }
    if ($script:VipmEngineDead) { Write-Warning '  VIPM engine wedged; skipping the local-file fallback.'; return $false }
    Write-Host '  VIPM name-based resolution failed; downloading public .vip files and installing from local files ...'
    try {
        $vipFiles = @(Get-LocalVipFilesForSpecs $Specs)
        Write-Host ("  Installing local VIP files: " + (($vipFiles | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))
        $rc = Invoke-VipmInstall @vipFiles
        if ($rc -eq 0) { return $true }
        Write-Host "  local VIP file batch install failed (exit $rc); retrying each file individually ..."
        $localFailed = $false
        foreach ($vipFile in $vipFiles) {
            $rc = Invoke-VipmInstall $vipFile
            if ($rc -ne 0) { Write-Warning "  local package file '$vipFile' failed (exit $rc)."; $localFailed = $true }
            if ($script:VipmEngineDead) { Write-Warning '  VIPM engine wedged; stopping per-file retries.'; return $false }
        }
        return (-not $localFailed)
    } catch {
        Write-Warning ("  local VIP file fallback failed: " + $_.Exception.Message)
        return $false
    }
}

# Refresh all package sources once (best-effort - a refresh failure is only a warning
# because version-pinned installs can still resolve from the local cache).
#
# VIPM 26.3 Community Edition refuses to install ("exit 6: VIPM Community Edition
# requires a public Git repository") unless the current working directory is inside
# a PUBLIC Git repository. It only reads .git/config's origin URL (and verifies the
# repo is public). When Community Edition enforcement is active it shells out to a
# real `git` binary (MinGit, baked into C:\git by labview-ci.Dockerfile) to read
# .git/config's origin URL and verify the repo is public - so a minimal fabricated
# .git (no clone or commits required) plus git on PATH is enough. We default to NOT
# forcing CE (see above), but keep this public-repo context as a safety net so the
# install still works if CE enforcement is enabled. Verified locally against VIPM
# 26.3: with git present this clears the exit-6 gate and the install proceeds.
function New-PublicRepoWorkdir {
    param([string] $RepoUrl)
    $work = Join-Path $env:TEMP ('vipm-install-' + [Guid]::NewGuid().ToString('N'))

    # Preferred: actually CLONE the public repo so the working directory is a REAL
    # git checkout - a genuine remote, real HEAD/commits, and the project's own
    # .vipc present on disk - rather than a fabricated stub. If VIPM Community
    # Edition verifies repository visibility by shelling out to git (git rev-parse
    # HEAD / git ls-remote origin reaching GitHub), only a real clone satisfies it.
    # Shallow + single-branch + no-tags keeps it fast. Best-effort: any failure
    # (no git, no network in the build layer) falls back to the fabricated .git
    # context below, which is enough to read .git/config's origin URL.
    if (Get-Command git -ErrorAction SilentlyContinue) {
        try {
            Write-Host "Cloning public repo for VIPM CE context: $RepoUrl"
            & git clone --depth 1 --single-branch --no-tags --quiet $RepoUrl $work 2>&1 | Out-Host
            if (($LASTEXITCODE -eq 0) -and (Test-Path (Join-Path $work '.git'))) {
                Write-Host "  Cloned public repo into $work"
                return $work
            }
            Write-Warning "  git clone failed (exit $LASTEXITCODE); falling back to a fabricated .git context."
        } catch {
            Write-Warning ("  git clone threw (" + $_.Exception.Message + "); falling back to a fabricated .git context.")
        }
        if (Test-Path $work) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
    }

    # Fallback: minimal fabricated .git (origin URL only). Enough for VIPM to read
    # .git/config's origin remote, but with no commits a deeper `git rev-parse HEAD`
    # / `git ls-remote` check would not pass - hence the real clone is preferred.
    New-Item -ItemType Directory -Path (Join-Path $work '.git\objects')    -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $work '.git\refs\heads') -Force | Out-Null
    Set-Content -Path (Join-Path $work '.git\HEAD') -Value 'ref: refs/heads/main' -NoNewline -Encoding ascii
    $cfg = "[core]`n`trepositoryformatversion = 0`n`tbare = false`n" +
           "[remote `"origin`"]`n`turl = $RepoUrl`n`tfetch = +refs/heads/*:refs/remotes/origin/*`n"
    Set-Content -Path (Join-Path $work '.git\config') -Value $cfg -Encoding ascii
    return $work
}

$prevLocation   = Get-Location
$installWorkdir = $null
try {
    $installWorkdir = New-PublicRepoWorkdir $PublicRepoUrl
    Write-Host "Running VIPM installs from a public-repo context (origin=$PublicRepoUrl) to satisfy Community Edition."
    Set-Location $installWorkdir

    # Diagnostic (per JKI): show what `git` reports from the EXACT directory vipm
    # runs in - this is one of the signals VIPM uses to decide the repo is public.
    # If these don't show a clean working tree with a public origin remote, VIPM's
    # public-repo detection can't succeed regardless of anything else.
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-Host "--- git context for VIPM (cwd=$installWorkdir) ---"
        Write-Host '$ git status'
        & git status 2>&1 | Out-Host
        Write-Host '$ git remote -v'
        & git remote -v 2>&1 | Out-Host
        Write-Host '$ git rev-parse HEAD'
        & git rev-parse HEAD 2>&1 | Out-Host
        Write-Host '--- end git context ---'
    }

    # Force a full re-download of the package spec index. A fresh headless VIPM in a
    # container starts with an empty CLI spec cache (C:\ProgramData\JKI\VIPM\cache);
    # a plain `vipm refresh` reported "complete" but downloaded no specs, so every
    # package resolved as "not found" (exit 3). --force re-fetches the index.
    Write-Host 'Refreshing VIPM package sources (vipm refresh --force) ...'
    & $VipmExe refresh --force 2>&1 | Out-Host

    # Phase A (REQUIRED, installed FIRST): the UTF JUnit essentials the built-in
    # 'LabVIEWCLI -OperationName RunUnitTests' operation links against. Install them
    # before any heavy tooling VIPC so they land while the engine is fresh - even if
    # a later add-on (e.g. Antidoc) wedges the engine, headless UTF still works.
    # Without them RunUnitTests fails with LabVIEW CLI error -350053. Override the
    # list with VIPM_REQUIRED_PACKAGES (comma/semicolon separated name@version); set
    # it to a single '-' to disable the required pre-install entirely.
    $requiredRaw = if ($null -ne $Env:VIPM_REQUIRED_PACKAGES) { $Env:VIPM_REQUIRED_PACKAGES } else {
        'ni_lib_utf_junit_report@1.0.1.43,ni_lib_junit_results_api@1.0.1.6,ni_lib_simple_xml@1.0.0.4'
    }
    $requiredSpecs = @($requiredRaw -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '-' })
    if ($requiredSpecs.Count -gt 0) {
        Write-Host ("Installing REQUIRED UTF essentials first: " + ($requiredSpecs -join ', '))
        if (Install-VipmSpecs $requiredSpecs) {
            Write-Host 'REQUIRED UTF essentials installed.'
        } else {
            Write-Warning 'One or more REQUIRED UTF essentials failed to install; headless UTF (RunUnitTests) will fail with -350053.'
            $applyFailed = $true
        }
    }

    # Phase A2 (EARLY, BEST-EFFORT): unit-test framework packages that only resolve
    # through the public-index local-file fallback (the container's by-name resolver
    # is empty, so `vipm install <name>` returns exit 3). Astemes LUnit is the case:
    # it IS on the JKI/NI public indexes (downloadable), but must be installed HERE,
    # right after the UTF essentials while the headless VIPM engine is still fresh.
    # The later heavy ci-tooling.vipc local-file install (Caraya + VI Tester + their
    # OpenG dependency closures) can wedge the engine ('wait for VIPM startup'), and
    # once wedged nothing else installs - so LUnit, if left to that phase, never gets
    # a healthy engine. Installing it early mirrors how the (now-removed) local .vip
    # bundle made LUnit survive. Best-effort: a failure warns but does not fail the
    # build. Gated to unit-tests builds: defaults to empty when the required UTF
    # essentials are disabled (VIPM_REQUIRED_PACKAGES='-', i.e. Unit Tests capability
    # not installed). Override with VIPM_EARLY_PACKAGES ('-' disables).
    $earlyRaw = if ($null -ne $Env:VIPM_EARLY_PACKAGES) { $Env:VIPM_EARLY_PACKAGES }
                elseif ($requiredSpecs.Count -gt 0) { 'astemes_lib_lunit,astemes_lib_lunit_cli' }
                else { '' }
    $earlySpecs = @($earlyRaw -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '-' })
    if ($earlySpecs.Count -gt 0 -and -not $script:VipmEngineDead) {
        Write-Host ("Installing EARLY best-effort framework packages (engine still fresh): " + ($earlySpecs -join ', '))
        if (Install-VipmSpecs $earlySpecs) {
            Write-Host 'Early framework packages installed.'
        } else {
            $script:bestEffortFailed = $true
            Write-Warning 'One or more early framework packages (e.g. LUnit base/CLI) did not install; the LUnit CLI may be missing from the worker (run-unit-tests.ps1 will show the missing-tooling banner).'
        }
    }

    # Apply REQUIRED (project) VIPCs before BEST-EFFORT tooling VIPCs (ci-tooling*).
    # A best-effort add-on (Antidoc) can wedge the headless VIPM engine, so it must
    # run LAST - otherwise it would kill the engine before a required project VIPC
    # (the OpenG / domain dependencies the project's VIs load against) gets to apply.
    $vipcFiles = @($vipcFiles | Sort-Object @{ Expression = { if ($_.Name -like 'ci-tooling*') { 1 } else { 0 } } }, Name)

    foreach ($vipc in $vipcFiles) {
        # Tooling VIPCs (ci-tooling*.vipc) carry opportunistic add-ons (Antidoc,
        # Caraya, VI Tester). Antidoc's heavy dependency tree can wedge the headless
        # VIPM engine, so a tooling VIPC failure is BEST-EFFORT: it warns but does not
        # fail the image build (the required essentials above are already installed).
        # Any other (project) VIPC is REQUIRED - its packages are what the project's
        # VIs load against, so a failure must fail the build.
        $bestEffort = ($vipc.Name -like 'ci-tooling*')
        $label = if ($bestEffort) { 'best-effort tooling' } else { 'required project' }
        $vipcFailed = $false

        if ($script:VipmEngineDead) {
            Write-Warning ("  Skipping '$($vipc.Name)' ($label): the VIPM engine wedged earlier in this build and will not recover.")
            $vipcFailed = $true
        }
        else {
            Write-Host "Applying VIPC: $($vipc.Name) [$label]"
            # Preferred path: install the .vipc file directly (the form VIPM documents:
            # `vipm install -y project.vipc`).
            Write-Host "  Installing from file: vipm install -y '$($vipc.Name)'"
            $rc = Invoke-VipmInstall '-y' $vipc.FullName
            if ($rc -eq 0 -and $script:LastVipmOutput -match 'No packages were installed') {
                Write-Warning "  VIPM accepted '$($vipc.Name)' but reported that no packages were installed; falling back to package-level install."
                $rc = 42
            }
            if ($rc -ne 0) {
                if (($rc -eq 8 -or $rc -eq 124) -and ($script:LastVipmOutput -match 'wait for VIPM startup')) {
                    # Engine never came online; the by-name fallback would hit the same
                    # wall and burn another VIPM_TIMEOUT, so surface it immediately.
                    Write-Warning ("  VIPM could not install '$($vipc.Name)' (exit $rc): the VIPM engine never came online ('wait for VIPM startup').")
                    $vipcFailed = $true
                }
                else {
                    # Code 42 etc. mean the engine is up but rejected the .vipc-FILE
                    # apply path; the by-name + local-file fallback can still succeed.
                    Write-Host "  install from file failed (exit $rc); falling back to per-package names ..."
                    $specs = @(Get-VipcPackageSpecs $vipc.FullName)
                    if ($specs.Count -eq 0) {
                        Write-Warning "VIPM could not install from '$($vipc.Name)' (exit $rc) and no package names could be parsed."
                        $vipcFailed = $true
                    }
                    elseif (-not (Install-VipmSpecs $specs)) {
                        $vipcFailed = $true
                    }
                }
            }
        }

        if ($vipcFailed) {
            if ($bestEffort) {
                $script:bestEffortFailed = $true
                Write-Warning ("  '$($vipc.Name)' did not fully install, but it is best-effort tooling - continuing the build.")
            } else {
                $applyFailed = $true
            }
        }
    }
}
finally {
    Set-Location $prevLocation
    if ($installWorkdir -and (Test-Path $installWorkdir)) {
        Remove-Item -Recurse -Force $installWorkdir -ErrorAction SilentlyContinue
    }
}

# Stop the headless LabVIEW we launched for the install (best-effort).
if ($LabVIEWProc -and -not $LabVIEWProc.HasExited) {
    Write-Host 'Stopping headless LabVIEW...'
    try { $LabVIEWProc | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
}

# Stop the VIPM engine we pre-launched for the install (best-effort).
if ($VipmEngineProc -and -not $VipmEngineProc.HasExited) {
    Write-Host 'Stopping VIPM engine...'
    try { $VipmEngineProc | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
}

if ($applyFailed) {
    $message = ('One or more REQUIRED VIPM packages could not be installed (a project .vipc ' +
        'dependency or a UTF JUnit essential the RunUnitTests CLI links against). Headless UTF ' +
        'may fail with LabVIEW CLI error -350053, or project VIs may not load. Check the install ' +
        'log above for the failing package(s) and confirm they exist on the configured VIPM repository.')
    if ($Env:VIPM_ALLOW_MISSING_PACKAGES -eq '1') {
        Write-Warning ($message + ' VIPM_ALLOW_MISSING_PACKAGES=1 is set, so the image build will continue without those packages.')
        exit 0
    }
    Write-Error ($message + ' Failing the image build so CI cannot publish or run against a worker image with stale/missing required dependencies. Set VIPM_ALLOW_MISSING_PACKAGES=1 only for emergency best-effort builds.')
    exit 1
}

if ($script:bestEffortFailed) {
    Write-Warning ('Some best-effort tooling add-ons (e.g. Antidoc / Caraya / VI Tester from ci-tooling.vipc) ' +
        'did not fully install - typically because a heavy dependency tree wedged the headless VIPM engine. ' +
        'The image is still valid: the required project dependencies and UTF JUnit essentials are present. ' +
        'Bake the missing add-on separately (e.g. a dedicated VIPC) if you need it in the worker.')
}

Write-Host 'Required VIPM packages installed successfully.'
