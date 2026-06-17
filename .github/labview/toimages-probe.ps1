<#
  Probe v4 (minimal, robust) — diagnostic only.
  Goal: find a LabVIEW.exe launch that yields a COM-ready HEADLESS LabVIEW in the
  container, then drive toimages\Convert.vi (set "VI Path in", read "JSON out").
  No Start-Job, no 2>&1 redirects (those broke v3). Invoked via -File.
#>
param(
    [string] $ConvertVI   = 'C:\repo\.github\labview\toimages\Convert.vi',
    [string] $TargetVI    = 'C:\repo\example\main.vi',
    [string] $OutDir      = 'C:\repo\_probe-out',
    [string] $LabVIEWPath = ''
)
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

function Resolve-LabVIEWPath([string]$Preferred) {
    if ($Preferred -and (Test-Path $Preferred)) { return $Preferred }
    $cands = @(Get-ChildItem 'C:\Program Files\National Instruments' -Directory -Filter 'LabVIEW *' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'LabVIEW.exe' } | Where-Object { Test-Path $_ })
    if ($cands.Count -gt 0) { return $cands[0] }
    throw 'LabVIEW.exe not found'
}

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

function Attach-Com {
    try {
        $app = [System.Runtime.InteropServices.Marshal]::GetActiveObject('LabVIEW.Application')
        $v = [string]$app.Version
        if ($v -ne '') { return $app }
    } catch { }
    return $null
}

$lvExe = Resolve-LabVIEWPath $LabVIEWPath
Write-Host "=== probe v4 ==="
Write-Host "  LabVIEW.exe : $lvExe"
Write-Host "  Convert.vi  : $ConvertVI  (exists: $(Test-Path $ConvertVI))"
Write-Host "  target VI   : $TargetVI   (exists: $(Test-Path $TargetVI))"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Enable-Scripting $lvExe

# Candidate launch arg strings (LabVIEW.exe). Start-Process passes the string as
# the command line; LabVIEW parses its own argv. -Headless was never tested pre-v4.
$variants = @('-Headless /Automation', '/Automation -Headless', '-Headless', '/Automation')

$winner = $null; $app = $null
foreach ($vargs in $variants) {
    $label = $vargs
    Write-Host ""
    Write-Host "=== launch: LabVIEW.exe $label ==="
    Kill-LabVIEW
    try { Start-Process -FilePath $lvExe -ArgumentList $vargs } catch { Write-Host "  Start-Process failed: $($_.Exception.Message)"; continue }
    $app = $null
    for ($i = 1; $i -le 30; $i++) {
        $procs = @(Get-Process LabVIEW -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) { Write-Host "  LabVIEW.exe exited (arg rejected?) at poll $i"; break }
        $app = Attach-Com
        if ($app) { Write-Host "  >>> COM-READY after ~$($i*4)s - LabVIEW version $([string]$app.Version)"; break }
        Start-Sleep -Seconds 4
    }
    if ($app) { $winner = $label; break }
    Write-Host "  no COM-ready app for '$label'"
}

if (-not $app) {
    Write-Host ""
    Write-Host "RESULT: no launch variant produced a COM-ready headless LabVIEW."
    exit 1
}

Write-Host ""
Write-Host "=== WINNER launch args: '$winner' — running Convert.vi ==="
try {
    $vi = $app.GetVIReference($ConvertVI, '', $false, 0)
    Write-Host "  opened Convert.vi: $($vi.Name)"
    $vi.SetControlValue('VI Path in', $TargetVI)
    $vi.Run($false)
    $deadline = (Get-Date).AddSeconds(180)
    while ($true) {
        $st = [int]$vi.ExecState
        if ($st -eq 1) { break }
        if ((Get-Date) -gt $deadline) { $vi.Abort(); throw "Convert.vi run timeout (ExecState=$st)" }
        Start-Sleep -Milliseconds 200
    }
    $json = [string]$vi.GetControlValue('JSON out')
    Write-Host "  >>> Convert.vi JSON length: $($json.Length)"
    if ($json.Length -gt 0) {
        [System.IO.File]::WriteAllText((Join-Path $OutDir 'sample.json'), $json, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  >>> head: $($json.Substring(0, [Math]::Min(400, $json.Length)))"
        Write-Host ""
        Write-Host "SUCCESS: launch '$winner' + COM Convert.vi works in the container."
    } else {
        Write-Host "  empty JSON (COM works but Convert.vi returned nothing)"
    }
} catch {
    Write-Host "  Convert.vi via COM failed: $($_.Exception.Message)"
}
try { $app.Quit() } catch { }
Kill-LabVIEW
Write-Host "=== probe v4 done ==="
