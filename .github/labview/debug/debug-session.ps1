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
            'SERVER_ADD_FIREWALL_EXCEPTION=0',
            'SET_ACCEPTHTTPCONNECTIONS=1', 'VALUE_OF_ACCEPTHTTPCONNECTIONS=0',
            'SET_USEVNCAUTHENTICATION=1', 'VALUE_OF_USEVNCAUTHENTICATION=1',
            'SET_PASSWORD=1', ('VALUE_OF_PASSWORD=' + $pw))
  Start-Process 'msiexec.exe' -Wait -ArgumentList $args
} catch { Log "TightVNC install failed: $_" }

# --- 2. Start the VNC server as an application (hooks winsta0\default) --------
$tvn = 'C:\Program Files\TightVNC\tvnserver.exe'
if (Test-Path $tvn) {
  Log 'Starting tvnserver (application mode)...'
  # Set the password in the app config too (belt and braces), then run.
  try { & $tvn -controlservice -setvncpassword $pw 2>$null } catch {}
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
  Log "Launching LabVIEW: $lv"
  Start-Process $lv -WorkingDirectory $ws
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

# --- 5. Hold the session, then exit so the host tears down -------------------
Log "Debug desktop is up. Holding for $mins minutes."
Start-Sleep -Seconds ($mins * 60)
Log 'Session time elapsed; exiting.'
