<#
.SYNOPSIS
  LabVIEW CI - Debug Session action runner (Windows container side).

.DESCRIPTION
  Invoked from the on-screen prompt (debug-session.ps1) when the user presses
  ENTER after logging into / activating LabVIEW. Runs the selected CI activities
  with the same entrypoints the Windows CI workflows use, streaming output to the
  on-screen terminal so you can watch each step run in the live UI.

  Best-effort by design: this is an interactive aid. An activity without a wired
  headless runner just tells you to run it from the LabVIEW UI. Pure ASCII.
#>
param([string[]]$Actions)

$ErrorActionPreference = 'Continue'
$ws  = 'C:\workspace'
$out = "$ws\ci-out\debug"
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Invoke-One([string]$a) {
  switch ($a) {
    'masscompile' {
      & powershell -NoProfile -ExecutionPolicy Bypass -File "$ws\.github\labview\masscompile.ps1" `
        -WorkspaceRoot $ws -ReportDir "$out\masscompile"
    }
    default {
      Write-Host "No headless debug runner is wired for '$a' yet."
      Write-Host "Open the project in LabVIEW and run this activity from the UI to reproduce it."
    }
  }
}

if (-not $Actions -or $Actions.Count -eq 0) { Write-Host 'No activities were passed.'; return }

foreach ($a in $Actions) {
  if (-not $a) { continue }
  Write-Host ''
  Write-Host '================================================================'
  Write-Host " Running: $a"
  Write-Host '================================================================'
  Invoke-One $a
  Write-Host "---------------- done: $a ----------------"
}
