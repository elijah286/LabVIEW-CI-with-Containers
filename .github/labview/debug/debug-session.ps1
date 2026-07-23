# =============================================================================
# LabVIEW CI - Debug Session (Windows container side)
# =============================================================================
# Runs INSIDE the Windows worker container (started by debug-session.yml). Unlike
# Linux there is no Xvfb: a Windows container already has an interactive window
# station (winsta0\default), so a VNC server (TightVNC) run as an application can
# capture it and serve the LabVIEW IDE window. The VNC server listens on 5900,
# which the workflow publishes to the runner host; the host runs noVNC/websockify
# + the Cloudflare tunnel (the Windows container has no Python/cloudflared).
#
# Best-effort throughout: a missing tool logs a warning rather than failing. This
# is an interactive debugging aid, not CI. Pure ASCII.
# =============================================================================
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$ws   = 'C:\workspace'
$acts = $env:ACTIONS
$mins = if ($env:MINUTES) { [int]$env:MINUTES } else { 45 }
$pw   = if ($env:VNC_PW) { $env:VNC_PW } else { 'changeme' }
$openProj = ($env:OPEN_PROJECT -eq 'true') -or ($env:OPEN_PROJECT -eq '1')

function Log([string]$m) { Write-Host "[lvci-debug] $m" }

# --- 1. Install TightVNC server (silent) -------------------------------------
Log 'Downloading TightVNC server...'
$msi = Join-Path $env:TEMP 'tightvnc.msi'
try {
  Invoke-WebRequest -UseBasicParsing -Uri 'https://www.tightvnc.com/download/2.8.81/tightvnc-2.8.81-gpl-setup-64bit.msi' -OutFile $msi
  Log 'Installing TightVNC...'
  $args = @('/i', $msi, '/quiet', '/norestart',
            'ADDLOCAL=Server',
            'SERVER_REGISTER_AS_SERVICE=0',
            'SERVER_ADD_FIREWALL_EXCEPTION=0')
  Start-Process 'msiexec.exe' -Wait -ArgumentList $args
} catch { Log "TightVNC install failed: $_" }

# --- 2. Configure + start the VNC server as an application -------------------
# App mode (tvnserver -run) reads its config from the registry
# (HKCU/HKLM Software\TightVNC\Server), NOT the MSI's service settings. Leaving
# UseVncAuthentication=1 with no app-mode password made the server reject every
# connection ("Server is not configured properly" in noVNC). Setting a real VNC
# password there needs TightVNC's DES-obfuscated blob; since the one-time tunnel
# URL is the real access gate (unguessable, short-lived, and it already carries
# the password), disable VNC auth so the server is configured correctly and
# noVNC connects straight through.
foreach ($root in 'HKCU:\Software\TightVNC\Server','HKLM:\SOFTWARE\TightVNC\Server') {
  New-Item -Path $root -Force | Out-Null
  Set-ItemProperty -Path $root -Name 'UseVncAuthentication'     -Value 0    -Type DWord
  Set-ItemProperty -Path $root -Name 'UseControlAuthentication' -Value 0    -Type DWord
  Set-ItemProperty -Path $root -Name 'AcceptRfbConnections'     -Value 1    -Type DWord
  Set-ItemProperty -Path $root -Name 'RfbPort'                  -Value 5900 -Type DWord
  Set-ItemProperty -Path $root -Name 'AcceptHttpConnections'    -Value 0    -Type DWord
}
$tvn = 'C:\Program Files\TightVNC\tvnserver.exe'
if (Test-Path $tvn) {
  Log 'Starting tvnserver (application mode, VNC auth disabled)...'
  Start-Process $tvn -ArgumentList '-run'
} else {
  Log 'tvnserver.exe not found; the VNC view will be unavailable.'
}
Start-Sleep -Seconds 3

# --- 3. Launch the LabVIEW IDE UI --------------------------------------------
$lv = Get-ChildItem 'C:\Program Files\National Instruments' -Directory -Filter 'LabVIEW *' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'LabVIEW.exe' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
if ($lv) {
  # When OPEN_PROJECT is set (the dashboard's "Open source"), open the LabVIEW
  # project in the checkout so the user can see the source in the IDE.
  $proj = ''
  if ($openProj) {
    $proj = Get-ChildItem $ws -Recurse -Depth 4 -Filter '*.lvproj' -File -ErrorAction SilentlyContinue |
              Sort-Object FullName | Select-Object -First 1 -ExpandProperty FullName
    if ($proj) { Log "Will open project: $proj" } else { Log 'OPEN_PROJECT set but no .lvproj found under the workspace.' }
  }
  if ($proj) {
    Log "Launching LabVIEW: $lv with $proj"
    Start-Process $lv -WorkingDirectory $ws -ArgumentList ('"' + $proj + '"')
  } else {
    Log "Launching LabVIEW: $lv"
    Start-Process $lv -WorkingDirectory $ws
  }
} else {
  Log 'LabVIEW.exe not found; open it from the on-screen terminal.'
}

# --- 4. On-screen "go" prompt window (visible via VNC) -----------------------
# The human presses ENTER here after logging into / activating LabVIEW to run the
# selected activities. Keeps the whole handshake inside the session they drive.
$prompt = Join-Path $env:TEMP 'lvci-prompt.ps1'
$body = @"
Write-Host '=================================================================='
Write-Host ' LabVIEW CI - Debug Session (Windows)'
Write-Host '=================================================================='
Write-Host ''
Write-Host ' 1. Log into / activate LabVIEW in the window that opened.'
Write-Host ' 2. When it is ready, press ENTER here to run the selected actions:'
Write-Host '        $acts'
Write-Host ''
Write-Host ' (End the session from the dashboard, or it ends automatically after $mins minutes.)'
Write-Host ''
[void][System.Console]::ReadLine()
if ('$acts'.Trim().Length -gt 0) {
  & '$ws\.github\labview\debug\run-debug-actions.ps1' -Actions ('$acts'.Split(' '))
} else {
  Write-Host 'No actions were selected - this is a free interactive session.'
}
Write-Host ''
Write-Host 'Done. This window stays open until the session ends. Press ENTER to close it.'
[void][System.Console]::ReadLine()
"@
Set-Content -Encoding ASCII -Path $prompt -Value $body
Start-Process 'powershell.exe' -ArgumentList @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $prompt)

# --- 5. Surface the LabVIEW window + diagnostics ----------------------------
# In a Windows container the apps run in session 0; if LabVIEW's window is
# created but not shown / not foreground, the VNC view stays black. Log what
# top-level windows exist and try to show + foreground the LabVIEW window a few
# times as it finishes loading. All logged to container stdout (docker logs).
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class LvWin {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
}
'@
for ($t = 0; $t -lt 6; $t++) {
  Start-Sleep -Seconds 15
  $lvp = Get-Process LabVIEW -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($lvp) {
    Log ('Diag: LabVIEW pid=' + $lvp.Id + ' mainwnd=' + $lvp.MainWindowHandle + ' title=[' + $lvp.MainWindowTitle + ']')
    if ($lvp.MainWindowHandle -ne [IntPtr]::Zero) {
      [LvWin]::ShowWindow($lvp.MainWindowHandle, 3) | Out-Null   # SW_SHOWMAXIMIZED
      [LvWin]::BringWindowToTop($lvp.MainWindowHandle) | Out-Null
      [LvWin]::SetForegroundWindow($lvp.MainWindowHandle) | Out-Null
    }
  } else {
    Log 'Diag: LabVIEW process is NOT running.'
  }
  $wins = (Get-Process | Where-Object { $_.MainWindowTitle } | ForEach-Object { $_.ProcessName + ':[' + $_.MainWindowTitle + ']' }) -join ' | '
  Log ('Diag: windowed processes: ' + $wins)
}

# --- 6. Hold the session, then exit so the host tears down -------------------
Log "Debug desktop is up. Holding for $mins minutes."
Start-Sleep -Seconds ($mins * 60)
Log 'Session time elapsed; exiting.'
