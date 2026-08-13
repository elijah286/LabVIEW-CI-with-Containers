<#
.SYNOPSIS
    Generates a Software Bill of Materials (SBOM) for LabVIEW projects using JKI's VIPM CLI.
    Emits an SPDX-compliant JSON file (sbom.json) and an HTML widget (sbom_widget.html)
    intended for dashboard integration.
    Reference: https://docs.vipm.io/latest/sbom/getting-started/
    Development by: Daniel Coons, TSC

.PARAMETER WorkspaceRoot
    Absolute path to the checked-out project repository. Default: C:\workspace.

.PARAMETER ResultsDir
    Directory where sbom.json and sbom_widget.html will be saved. Default: C:\workspace\ci-out\sbom.
#>
param(
    [string]$WorkspaceRoot = 'C:\workspace',
    [string]$ResultsDir    = 'C:\workspace\ci-out\sbom'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# Ensure output directory exists
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

# -- Helper Functions ---------------------------------------------------------
function Resolve-Cmd([string[]]$names) {
    foreach ($n in $names) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c -and $c.Source) { return $c.Source }
    }
    return $null
}

function Sync-PathFromRegistry {
    # VIPM-installed CLIs add their directory to system PATH, but Windows container
    # processes don't always inherit registry PATH updates automatically.
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
    } catch { 
        Write-Host "  (PATH refresh from registry skipped: $($_.Exception.Message))" 
    }
}

function Resolve-VIPMCLI {
    Sync-PathFromRegistry
    $cli = Resolve-Cmd @('vipm', 'vipm.exe')
    if ($cli) { return $cli }

    $standardPaths = @(
        "C:\Program Files (x86)\JKI\VI Package Manager\vipm.exe",
        "C:\Program Files\JKI\VI Package Manager\vipm.exe"
    )
    foreach ($p in $standardPaths) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Resolve-LabVIEWVersion {
    # Detect installed LabVIEW version from the filesystem path.
    # Paths are typically: C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe
    $lvExe = Get-ChildItem "C:\Program Files*\National Instruments\LabVIEW*\LabVIEW.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $lvExe) { return $null }
    
    # Extract year (4 consecutive digits) from the path, e.g. "LabVIEW 2026" -> "2026"
    if ($lvExe.FullName -match "LabVIEW[\s]*([0-9]{4})") {
        return $Matches[1]
    }
    return $null
}

function Resolve-SbomVendor([object]$component) {
    if (-not $component) { return 'N/A' }

    $supplier = $component.supplier
    if ($supplier -and $supplier.name) { return [string]$supplier.name }
    if ($supplier -and ($supplier -is [string])) { return [string]$supplier }

    foreach ($prop in @('publisher', 'vendor')) {
        $value = $component.$prop
        if ($value) { return [string]$value }
    }

    $purl = [string]$component.purl
    if ($purl.StartsWith('pkg:nipkg/')) { return 'NIPM' }
    if ($purl.StartsWith('pkg:vipm/')) { return 'VIPM' }

    return 'N/A'
}

function Resolve-SbomVendor([object]$component) {
    if (-not $component) { return 'N/A' }

    $supplier = $component.supplier
    if ($supplier -and $supplier.name) { return [string]$supplier.name }
    if ($supplier -and ($supplier -is [string])) { return [string]$supplier }

    foreach ($prop in @('publisher', 'vendor')) {
        $value = $component.$prop
        if ($value) { return [string]$value }
    }

    $purl = [string]$component.purl
    if ($purl.StartsWith('pkg:nipkg/')) { return 'NIPM' }
    if ($purl.StartsWith('pkg:vipm/')) { return 'VIPM' }

    return 'N/A'
}

# -- Main Generation Logic ----------------------------------------------------
function Invoke-SbomGeneration([string]$Workspace, [string]$OutDir) {
    Write-Host "=== JKI VIPM SBOM Generation ==="
    Write-Host "  Workspace : $Workspace"
    Write-Host "  Results   : $OutDir"

    $VipmCli = Resolve-VIPMCLI
    Write-Host "  VIPM CLI  : $(if ($VipmCli) { $VipmCli } else { '<not found>' })"
    Write-Host ""

    $sbomPackages = @()
    $outPath = $null
    
    # Detect the installed LabVIEW version early, before VIPM needs it
    $labviewVersion = Resolve-LabVIEWVersion
    if (-not $labviewVersion) {
        Write-Warning "Could not detect installed LabVIEW version. VIPM SBOM may fail if project targets a different year."
        $labviewVersion = '2026'  # fallback
    } else {
        Write-Host "  Detected LabVIEW version: $labviewVersion" -ForegroundColor Gray
    }

    if ($VipmCli -and (Test-Path $VipmCli)) {
        Write-Host "Generating native VIPM SBOM via VIPM CLI..." -ForegroundColor Cyan
        
        # 1. Locate main project file (.lvproj), ignoring CI/tooling folders
        $projFile = Get-ChildItem -Path $Workspace -Filter '*.lvproj' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](\.github|ci-out|build)[\\/]' } |
            Select-Object -First 1
        
        if ($projFile) {
            $projPath = $projFile.FullName
            $outPath  = Join-Path $OutDir "sbom.json"
            
            # 2. Configure LabVIEW.ini BEFORE launching LabVIEW
            $lvExe = Get-ChildItem "C:\Program Files*\National Instruments\LabVIEW*\LabVIEW.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            $lvProcess = $null

            if ($lvExe) {
                $iniPath = Join-Path (Split-Path $lvExe.FullName) "LabVIEW.ini"
                if (Test-Path $iniPath) {
                    Write-Host "Configuring VI Server permissions in $iniPath..." -ForegroundColor Cyan
                    $iniLines = @(
                        "",
                        "[LabVIEW]",
                        "server.tcp.enabled=True",
                        "server.tcp.port=3363",
                        "server.tcp.access=`"*`"",
                        "VIPropeties.AllowPort3363=True"
                    )
                    Add-Content -Path $iniPath -Value ($iniLines -join "`r`n") -ErrorAction SilentlyContinue
                }

                # 3. Launch LabVIEW process explicitly
                Write-Host "Launching background LabVIEW instance ($($lvExe.FullName))..." -ForegroundColor Cyan
                $lvProcess = Start-Process -FilePath $lvExe.FullName -ArgumentList "-LabVIEWCLI", "-headless" -PassThru -NoNewWindow
                
                # 4. Wait up to 30 seconds for Port 3363 to open
                Write-Host "Waiting for VI Server (Port 3363) to open..."
                $portOpen = $false
                for ($i = 0; $i -lt 15; $i++) {
                    $client = New-Object System.Net.Sockets.TcpClient
                    try {
                        $client.Connect("127.0.0.1", 3363)
                        if ($client.Connected) {
                            $portOpen = $true
                            $client.Close()
                            break
                        }
                    } catch {
                        Start-Sleep -Seconds 2
                    }
                }

                if ($portOpen) {
                    Write-Host "VI Server is active on port 3363!" -ForegroundColor Green
                } else {
                    Write-Warning "Timed out waiting for Port 3363 to open. Proceeding anyway..."
                }
            }

            try {
                # 5. Execute VIPM SBOM command
                Write-Host "Executing VIPM CLI..." -ForegroundColor Cyan
                Write-Host "  Targeting LabVIEW version: $labviewVersion (64-bit)" -ForegroundColor Gray
                # --allow-missing-files: instrument drivers (e.g. <instrlib>/...) are not installed
                # in the CI container; VIPM still generates the SBOM for all resolvable packages
                # and emits warnings for the missing references rather than aborting (exit code 18).
                & $VipmCli --labview-version $labviewVersion --labview-bitness 64 sbom "$projPath" --format "cyclonedx" --schema-version "1.5" --allow-missing-files --output "$outPath"
                $vipmExitCode = $LASTEXITCODE
                if ($vipmExitCode -ne 0) {
                    throw "VIPM CLI SBOM generation failed with exit code $vipmExitCode."
                }

                if (-not (Test-Path $outPath)) {
                    throw "VIPM CLI reported success but did not create output file: $outPath"
                }

                Write-Host "VIPM SBOM generated successfully!" -ForegroundColor Green
                $sbomRaw = Get-Content $outPath | ConvertFrom-Json
                if ($sbomRaw.components) {
                    $sbomPackages = @($sbomRaw.components | ForEach-Object {
                        [pscustomobject]@{
                            Name    = $_.name
                            Version = $_.version
                            Vendor  = Resolve-SbomVendor $_
                        }
                    })
                }
            } finally {
                # 6. Clean up background LabVIEW process
                if ($lvProcess -and -not $lvProcess.HasExited) {
                    Write-Host "Stopping background LabVIEW instance..." -ForegroundColor Yellow
                    Stop-Process -Id $lvProcess.Id -Force -ErrorAction SilentlyContinue
                }
            }
        } else {
            Write-Warning "No valid .lvproj file found in workspace."
        }
    }


    # Preserve the native VIPM/CycloneDX sbom.json emitted by VIPM.
    if ($outPath -and (Test-Path $outPath)) {
        Write-Host "Preserved native SBOM JSON -> $outPath" -ForegroundColor Green
    }

    # Generate HTML Widget for Dashboard Insertion
    $htmlWidget = @"
<div class="card sbom-card">
    <div class="card-header d-flex justify-content-between align-items-center">
        <h4>Software Bill of Materials (SBOM) - JKI VIPM Dependencies</h4>
        <a href="sbom.json" download class="btn btn-sm btn-outline-primary">Download SBOM JSON</a>
    </div>
    <div class="card-body">
        <table class="table table-sm table-striped">
            <thead>
                <tr>
                    <th>Package Name</th>
                    <th>Version</th>
                    <th>Vendor</th>
                </tr>
            </thead>
            <tbody>
"@
    foreach ($pkg in $sbomPackages) {
        $htmlWidget += @"
                <tr>
                    <td>$([System.Web.HttpUtility]::HtmlEncode($pkg.Name))</td>
                    <td>$([System.Web.HttpUtility]::HtmlEncode($pkg.Version))</td>
                    <td>$([System.Web.HttpUtility]::HtmlEncode($pkg.Vendor))</td>
                </tr>
"@
    }
    $htmlWidget += @"
            </tbody>
        </table>
    </div>
</div>
"@

    # Save HTML artifact
    $htmlPath = Join-Path $OutDir "sbom_widget.html"
    $htmlWidget | Set-Content -LiteralPath $htmlPath -Encoding UTF8
    Write-Host "Wrote HTML Dashboard Widget -> $htmlPath" -ForegroundColor Green
}

# Run SBOM Generator
Invoke-SbomGeneration -Workspace $WorkspaceRoot -OutDir $ResultsDir
