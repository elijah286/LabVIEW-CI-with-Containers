<#
  windows-render.ps1 - in-container entrypoint for VI Browser 2.0 rendering on
  Windows. This is the Windows counterpart of docker-entrypoint.sh (Linux): it
  prepares a COM-ready headless LabVIEW inside the stock NI LabVIEW Windows
  container, then runs the SAME portable batch runner (runner.exe, built from
  .github/labview/toimages/main.go) which shells out to lvctl.exe per VI.

  Linux drives LabVIEW over VI Server TCP under Xvfb; Windows drives the very same
  lvctl engine over COM/ActiveX (viserver_windows.go) - no Xvfb, no TCP. The
  COM-ready-headless launch below is the approach proven by toimages-probe.ps1
  (LabVIEW.ini scripting tokens + "LabVIEW.exe -Headless /Automation").

  The runner writes <blob[:2]>/<blob>.json into -OutByBlob exactly like Linux;
  the calling workflow renames those to <blob>.windows.json on publish so the
  Windows renders coexist with the Linux ones (nothing about Linux changes).

  Invoked via: docker exec <container> powershell -File C:\repo\.github\labview\toimages\windows-render.ps1 -Workspace ... -Worklist ... -OutByBlob ... -Lvctl ... -Runner ...
#>
param(
    [Parameter(Mandatory = $true)] [string] $Workspace,   # repo root inside the container (WORKSPACE)
    [Parameter(Mandatory = $true)] [string] $Worklist,    # TSV of "<blob>\t<relpath>" (WORKLIST)
    [Parameter(Mandatory = $true)] [string] $OutByBlob,   # output dir for <ab>/<blob>.json (OUT_BY_BLOB)
    [Parameter(Mandatory = $true)] [string] $Lvctl,       # path to lvctl.exe (render engine)
    [Parameter(Mandatory = $true)] [string] $Runner,      # path to runner.exe (batch driver)
    [string] $CacheDir      = 'C:\lvctl-cache',           # where lvctl extracts its embedded VIs
    [string] $RenderTimeout = '5m',                       # per-VI lvctl timeout
    [string] $LabVIEWPath   = '',                         # optional explicit LabVIEW.exe
    [int]    $ComReadySeconds = 240                       # how long to wait for COM-ready LabVIEW
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Resolve-LabVIEWPath([string]$Preferred) {
    if ($Preferred -and (Test-Path $Preferred)) { return $Preferred }
    $cands = @(Get-ChildItem 'C:\Program Files\National Instruments' -Directory -Filter 'LabVIEW *' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'LabVIEW.exe' } | Where-Object { Test-Path $_ })
    if ($cands.Count -gt 0) { return $cands[0] }
    throw 'LabVIEW.exe not found under C:\Program Files\National Instruments'
}

# Ensure the install's LabVIEW.ini has the scripting / dialog-suppression tokens a
# headless COM-driven LabVIEW needs. Mirrors toimages-probe.ps1 (proven).
function Enable-Scripting([string]$ExePath) {
    $ini = Join-Path (Split-Path -Parent $ExePath) 'LabVIEW.ini'
    $want = @{
        'SuperSecretPrivateSpecialStuff' = 'True'; 'unattended' = 'True'
        'AllowMultipleInstances' = 'True'; 'NIERAutoSendAndSuppressAllDialogs' = 'True'
        'neverShowLicensingStartupDialog' = 'True'; 'neverShowAddonLicensingStartup' = 'True'
        'SuppressRTConnectionDialogs' = 'True'; 'DWarnDialog' = 'False'; 'AutoSaveEnabled' = 'False'
    }
    $lines = @()
    if (Test-Path $ini) { $lines = @(Get-Content $ini) }
    if (-not ($lines | Where-Object { $_.Trim() -ieq '[LabVIEW]' })) { $lines += '[LabVIEW]' }
    foreach ($k in $want.Keys) {
        if ($lines | Where-Object { $_ -match "^\s*$([regex]::Escape($k))\s*=" }) {
            $lines = $lines | ForEach-Object { if ($_ -match "^\s*$([regex]::Escape($k))\s*=") { "$k=$($want[$k])" } else { $_ } }
        } else {
            $out = @(); $done = $false
            foreach ($ln in $lines) { $out += $ln; if (-not $done -and $ln.Trim() -ieq '[LabVIEW]') { $out += "$k=$($want[$k])"; $done = $true } }
            $lines = $out
        }
    }
    [System.IO.File]::WriteAllLines($ini, [string[]]$lines, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  [ini] scripting tokens ensured in $ini"
}

function Attach-Com {
    try {
        $app = [System.Runtime.InteropServices.Marshal]::GetActiveObject('LabVIEW.Application')
        if ([string]$app.Version -ne '') { return $app }
    } catch { }
    return $null
}

function Kill-LabVIEW {
    Get-Process LabVIEW -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

Write-Host "=== VI Browser 2.0 Windows render ==="
$lvExe = Resolve-LabVIEWPath $LabVIEWPath
Write-Host "  LabVIEW.exe : $lvExe"
Write-Host "  Workspace   : $Workspace"
Write-Host "  Worklist    : $Worklist  (exists: $(Test-Path $Worklist))"
Write-Host "  OutByBlob   : $OutByBlob"
Write-Host "  lvctl.exe   : $Lvctl  (exists: $(Test-Path $Lvctl))"
Write-Host "  runner.exe  : $Runner (exists: $(Test-Path $Runner))"

New-Item -ItemType Directory -Force -Path $OutByBlob | Out-Null
New-Item -ItemType Directory -Force -Path $CacheDir  | Out-Null
Enable-Scripting $lvExe

# Pre-launch ONE headless, automation-enabled LabVIEW and wait until it is
# COM-ready, so every per-VI lvctl invocation ATTACHES (GetActiveObject) to this
# instance instead of cold-launching its own. Mirrors the Linux entrypoint, which
# pre-launches LabVIEW and lets the runner attach.
Write-Host "Launching headless LabVIEW (-Headless /Automation)..."
Kill-LabVIEW
Start-Process -FilePath $lvExe -ArgumentList '-Headless /Automation'
$app = $null
for ($i = 1; $i -le [math]::Ceiling($ComReadySeconds / 4); $i++) {
    if (@(Get-Process LabVIEW -ErrorAction SilentlyContinue).Count -eq 0) {
        Write-Host "  LabVIEW.exe exited unexpectedly at poll $i"; break
    }
    $app = Attach-Com
    if ($app) { Write-Host "  COM-ready after ~$($i*4)s - LabVIEW $([string]$app.Version)"; break }
    Start-Sleep -Seconds 4
}
if (-not $app) {
    Write-Error "LabVIEW never became COM-ready within ${ComReadySeconds}s; cannot render."
    exit 1
}

# Hand off to the SAME portable batch runner used on Linux. It reads the worklist
# and shells `lvctl toimages <vi>` per VI; lvctl (Windows build) attaches to the
# LabVIEW above over COM, captures images, and prints frames JSON to stdout.
$env:WORKSPACE       = $Workspace
$env:WORKLIST        = $Worklist
$env:OUT_BY_BLOB     = $OutByBlob
$env:LVCTL           = $Lvctl
$env:LVCTL_CACHE_DIR = $CacheDir
$env:RENDER_TIMEOUT  = $RenderTimeout

Write-Host "Starting batch runner..."
& $Runner
$runnerExit = $LASTEXITCODE
Write-Host "Runner exit code: $runnerExit"

# Best-effort: leave LabVIEW closed so the container can stop cleanly.
try { if ($app) { $app.Quit() } } catch { }
Kill-LabVIEW

$produced = @(Get-ChildItem -Path $OutByBlob -Recurse -Filter '*.json' -ErrorAction SilentlyContinue).Count
Write-Host "=== done: $produced frame JSON file(s) under $OutByBlob ==="
# Mirror the runner's contract: exit non-zero only if the runner itself failed.
exit $runnerExit
