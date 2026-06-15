<#
.SYNOPSIS
    Bootstrap the LabVIEW CI installer (PowerShell / Windows entry point).

.DESCRIPTION
    Fetches the tooling (unless run from a checkout) and hands off to install.py,
    which does the actual catalog-driven copy. This wrapper only locates Python,
    acquires the source, and forwards your flags.

.EXAMPLE
    From the root of the repo you want to add CI to:

    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/elijah286/challenge-of-champions/main/.github/labview-ci/install.ps1))) `
        --activities masscompile,vi-analyzer,vidiff,dashboard --os windows,linux --labview-version 2026

.NOTES
    All flags are forwarded to install.py (run with --help to see them).
    Bootstrap-only flags handled here:
      --source-repo OWNER/NAME   tooling repo to fetch from (default below)
      --source-ref  REF          branch/tag/sha of the tooling repo (default main)
      --source      DIR          use a local tooling checkout instead of fetching
    Requires Python 3 and `tar` (built into Windows 10+).
#>
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)

$ErrorActionPreference = 'Stop'

$SourceRepo = 'elijah286/challenge-of-champions'
$SourceRef  = 'main'
$SrcDir     = $null
$Pass       = @()

for ($i = 0; $i -lt $Rest.Count; $i++) {
    switch ($Rest[$i]) {
        '--source-repo' { $SourceRepo = $Rest[++$i] }
        '--source-ref'  { $SourceRef  = $Rest[++$i] }
        '--source'      { $SrcDir     = $Rest[++$i] }
        default         { $Pass      += $Rest[$i] }
    }
}

$py = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
if (-not $py) { throw 'Python 3 is required but was not found on PATH.' }

$target = $PWD.Path

if (-not $SrcDir) {
    if (Test-Path '.github/labview-ci/install.py') {
        $SrcDir = $PWD.Path
    }
    else {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('lvci-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $archive = Join-Path $tmp 'tooling.tar.gz'
        $url = "https://codeload.github.com/$SourceRepo/tar.gz/refs/heads/$SourceRef"
        Write-Host "Fetching LabVIEW CI tooling from $SourceRepo@$SourceRef ..."
        Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
        tar -xzf $archive -C $tmp
        $SrcDir = (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName
    }
}

$installer = Join-Path $SrcDir '.github/labview-ci/install.py'
if (-not (Test-Path $installer)) {
    throw "Tooling not found under $SrcDir (.github/labview-ci/install.py missing)."
}

& $py.Source $installer --source $SrcDir --target $target @Pass
exit $LASTEXITCODE
