<#
.SYNOPSIS
    Exports every VI and CTL in the workspace to a standalone HTML snapshot
    (front panel + block diagram) using the PrintToSingleFileHtml LabVIEWCLI
    custom operation.

.PARAMETER WorkspaceRoot
    Root directory to scan for VIs (container path). Default: C:\workspace

.PARAMETER OutputDir
    Where to write exported HTML files. Default: C:\workspace\ci-out\vi-snapshots

.PARAMETER LabVIEWPath
    Path to LabVIEW.exe inside the container.

.NOTES
    PrintToSingleFileHtml VIs must be present at:
        <WorkspaceRoot>\.github\labview\PrintToSingleFileHtml\
    Copy them from:
        https://github.com/ni/labview-for-containers/.../helper-scripts/vidiff/PrintToSingleFileHtml/
#>
param(
    [string]$WorkspaceRoot = 'C:\workspace',
    [string]$OutputDir     = 'C:\workspace\ci-out\vi-snapshots',
    [string]$LabVIEWPath   = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$ResolvedLabVIEWPath = $null
$CliExe              = $null
# AdditionalOperationDirectory is searched recursively for the operation class,
# so point it at .github\labview (the parent of the PrintToSingleFileHtml folder).
$PrintToHtmlOp = Join-Path $WorkspaceRoot '.github\labview'

function Resolve-LabVIEWPath([string]$PreferredPath) {
    if ($PreferredPath -and (Test-Path $PreferredPath)) {
        return $PreferredPath
    }
    $candidates = @(
        Get-ChildItem 'C:\Program Files\National Instruments' -Directory -Filter 'LabVIEW *' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'LabVIEW.exe' } |
            Where-Object { Test-Path $_ }
    )
    if ($candidates -and $candidates.Count -gt 0) {
        return $candidates[0]
    }
    throw 'Could not locate LabVIEW.exe. Pass -LabVIEWPath explicitly.'
}

function Resolve-LabVIEWCLI([string]$ResolvedLVPath) {
    $lvDir = Split-Path $ResolvedLVPath -Parent
    $near  = Join-Path $lvDir 'LabVIEWCLI.exe'
    if (Test-Path $near) {
        return $near
    }

    $sharedCli = 'C:\Program Files\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
    if (Test-Path $sharedCli) {
        return $sharedCli
    }

    $found = Get-ChildItem 'C:\Program Files\National Instruments' -Recurse -Filter 'LabVIEWCLI.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if ($found) {
        return $found
    }

    throw 'Could not locate LabVIEWCLI.exe.'
}

$ResolvedLabVIEWPath = Resolve-LabVIEWPath -PreferredPath $LabVIEWPath
$CliExe              = Resolve-LabVIEWCLI -ResolvedLVPath $ResolvedLabVIEWPath

# Verify the custom operation VIs are present
$PrintToHtmlClass = Join-Path $PrintToHtmlOp 'PrintToSingleFileHtml'
if (-not (Test-Path $PrintToHtmlClass)) {
    Write-Error "PrintToSingleFileHtml operation directory not found: $PrintToHtmlClass`nCopy the VIs from https://github.com/ni/labview-for-containers/tree/main/examples/cicd-examples/helper-scripts/vidiff/PrintToSingleFileHtml/"
    exit 1
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# Exclude patterns
$ExcludeDirs = @('.github', 'ci-out', 'build', '.git')

function Should-Skip([string]$Path) {
    foreach ($ex in $ExcludeDirs) {
        if ($Path -like "*\$ex\*" -or $Path -like "*\$ex") { return $true }
    }
    return $false
}

function Test-IsLabVIEWFile([string]$Path) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 4) { return $false }
        $magic = [System.Text.Encoding]::ASCII.GetString($bytes[0..3])
        return ($magic -eq 'RSRC' -or $magic -eq 'LVIN' -or $magic -eq 'LVCC')
    } catch { return $false }
}

# Find all .vi and .ctl files
$allFiles = Get-ChildItem -Path $WorkspaceRoot -Recurse -Include '*.vi','*.ctl' |
    Where-Object { -not (Should-Skip $_.FullName) }

Write-Host "=== VI Snapshot Export ==="
Write-Host "  Found $($allFiles.Count) VI/CTL files"
Write-Host "  Output: $OutputDir"
Write-Host "  LabVIEW: $ResolvedLabVIEWPath"
Write-Host "  LabVIEWCLI: $CliExe"
Write-Host ""

$Exported = 0; $Skipped = 0; $Errors = 0

foreach ($vi in $allFiles) {
    $RelPath  = $vi.FullName.Substring($WorkspaceRoot.Length).TrimStart('\')
    $SafeName = ($RelPath -replace '[/\\]','-').TrimStart('-')

    if (-not (Test-IsLabVIEWFile $vi.FullName)) {
        Write-Host "  SKIP (not LV binary): $RelPath"
        $Skipped++
        continue
    }

    $HtmlOut  = Join-Path $OutputDir ($SafeName + '.html')
    $HtmlDir  = Split-Path $HtmlOut
    New-Item -ItemType Directory -Force -Path $HtmlDir | Out-Null

    try {
        # -Headless is REQUIRED for LabVIEW 2026+ inside Windows containers, otherwise
        # LabVIEWCLI cannot establish a VI Server connection (error -350000).
        & $CliExe `
            -OperationName                PrintToSingleFileHtml `
            -LabVIEWPath                  $ResolvedLabVIEWPath `
            -AdditionalOperationDirectory $PrintToHtmlOp `
            -LogToConsole                 TRUE `
            -VI                           $vi.FullName `
            -OutputPath                   $HtmlOut `
            -o -c `
            -Headless
        if ($LASTEXITCODE -ne 0) { throw "Exit code $LASTEXITCODE" }
        Write-Host "  OK: $RelPath -> $SafeName.html"
        $Exported++
    } catch {
        Write-Warning "  ERROR: $RelPath - $_"
        $Errors++
    }
}

Write-Host ""
Write-Host "=== Export complete: $Exported exported, $Skipped skipped, $Errors errors ==="

if ($Exported -eq 0) {
    Write-Error 'No VI snapshots were exported.'
    exit 1
}

if ($Errors -gt 0) {
    Write-Warning 'Some snapshots failed to export, but at least one snapshot was generated.'
}

exit 0
