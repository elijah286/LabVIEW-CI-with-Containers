<#
  windows-render.ps1 - in-container entrypoint for VI Browser 2.0 rendering on
  Windows. This is the Windows counterpart of docker-entrypoint.sh (Linux): it
    prepares the stock NI LabVIEW Windows container, then runs the SAME portable
    batch runner (runner.exe, built from .github/labview/toimages/main.go) which
    shells out to lvctl.exe per VI.

  Linux drives LabVIEW over VI Server TCP under Xvfb; Windows drives the very same
  lvctl engine over COM/ActiveX (viserver_windows.go) - no Xvfb, no TCP. The
    Windows uses the Go lvctl transport to attach to or launch LabVIEW; this script
    does not gate rendering on a separate PowerShell COM probe.

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
    [int]    $BatchTimeoutSeconds = 0,                    # total runner timeout; 0 derives from worklist and RenderTimeout
    [int]    $ComReadySeconds = 600                       # how long to wait for COM-ready LabVIEW
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

function Kill-LabVIEW {
    Get-Process LabVIEW -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

function Convert-DurationToSeconds([string]$Value) {
    if ($Value -match '^\s*(\d+)\s*ms\s*$') { return [Math]::Max(1, [int][Math]::Ceiling([double]$matches[1] / 1000.0)) }
    if ($Value -match '^\s*(\d+)\s*s\s*$')  { return [int]$matches[1] }
    if ($Value -match '^\s*(\d+)\s*m\s*$')  { return [int]$matches[1] * 60 }
    if ($Value -match '^\s*(\d+)\s*h\s*$')  { return [int]$matches[1] * 3600 }
    try { return [int][Math]::Ceiling(([TimeSpan]::Parse($Value)).TotalSeconds) }
    catch { return 300 }
}

function Write-LogFile([string]$Label, [string]$Path) {
    if (Test-Path $Path) {
        Write-Host "--- $Label ---"
        Get-Content $Path -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        Write-Host "--- end $Label ---"
    }
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

# Match the Linux ownership boundary: the Go runner shells out to lvctl, and
# lvctl owns LabVIEW attach/launch/readiness using its Windows transport. A
# separate PowerShell COM readiness probe can block a valid Go fallback path.
Write-Host "Starting Go toimages batch runner..."
Kill-LabVIEW
$env:WORKSPACE       = $Workspace
$env:WORKLIST        = $Worklist
$env:OUT_BY_BLOB     = $OutByBlob
$env:LVCTL           = $Lvctl
$env:LVCTL_CACHE_DIR = $CacheDir
$env:RENDER_TIMEOUT  = $RenderTimeout

$worklistCount = @(Get-Content $Worklist -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne '' }).Count
$perRenderSeconds = Convert-DurationToSeconds $RenderTimeout
if ($BatchTimeoutSeconds -le 0) {
    $BatchTimeoutSeconds = [Math]::Max(300, ($worklistCount * $perRenderSeconds) + 180)
}
Write-Host "Runner timeout: $BatchTimeoutSeconds second(s) for $worklistCount worklist item(s)"

$runnerOut = Join-Path $env:TEMP 'lvci-toimages-runner.stdout.log'
$runnerErr = Join-Path $env:TEMP 'lvci-toimages-runner.stderr.log'
Remove-Item $runnerOut, $runnerErr -Force -ErrorAction SilentlyContinue
$runnerProcess = Start-Process -FilePath $Runner -NoNewWindow -PassThru -RedirectStandardOutput $runnerOut -RedirectStandardError $runnerErr
if (-not $runnerProcess.WaitForExit($BatchTimeoutSeconds * 1000)) {
    Write-Error "Go toimages batch runner timed out after $BatchTimeoutSeconds second(s)"
    Stop-Process -Id $runnerProcess.Id -Force -ErrorAction SilentlyContinue
    Kill-LabVIEW
    Write-LogFile 'runner stdout' $runnerOut
    Write-LogFile 'runner stderr' $runnerErr
    exit 124
}
$runnerExit = $runnerProcess.ExitCode
Write-LogFile 'runner stdout' $runnerOut
Write-LogFile 'runner stderr' $runnerErr
Write-Host "Runner exit code: $runnerExit"

# Best-effort: leave LabVIEW closed so the container can stop cleanly.
Kill-LabVIEW

$produced = @(Get-ChildItem -Path $OutByBlob -Recurse -Filter '*.json' -ErrorAction SilentlyContinue).Count
Write-Host "=== done: $produced frame JSON file(s) under $OutByBlob ==="
# Mirror the runner's contract: exit non-zero only if the runner itself failed.
exit $runnerExit
