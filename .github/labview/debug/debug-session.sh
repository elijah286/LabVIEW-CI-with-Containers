#!/usr/bin/env bash
# =============================================================================
# LabVIEW CI - Debug Session (container side)
# =============================================================================
# Runs INSIDE the Linux worker container (started by debug-session.yml). Brings
# up a graphical desktop in a virtual framebuffer, launches the LabVIEW IDE UI,
# and serves it over noVNC on port 6080 (the host tunnels that out via Cloudflare).
# An on-screen terminal prompt lets the user press ENTER, once LabVIEW is logged
# in / activated, to run the selected CI activities live (run-debug-actions.sh).
#
# Everything is best-effort: this is an interactive debugging aid, not CI, so a
# missing tool logs a warning rather than failing hard. Pure ASCII.
# =============================================================================
set -u

WS=/workspace
export DISPLAY=:99
export HOME="${HOME:-/root}"
ACTIONS="${ACTIONS:-}"
MINUTES="${MINUTES:-45}"
VNC_PW="${VNC_PW:-changeme}"

log() { echo "[lvci-debug] $*"; }

# --- 1. Install the desktop + VNC tooling (best-effort) ----------------------
# The worker image ships Xvfb (for headless 2.0 renders) but not a window manager
# or VNC bridge, so add them on demand. Only debug sessions pay this cost.
if ! command -v x11vnc >/dev/null 2>&1 || ! command -v websockify >/dev/null 2>&1; then
  log "Installing desktop + VNC tools (fluxbox, x11vnc, novnc, websockify, xterm)..."
  export DEBIAN_FRONTEND=noninteractive
  SUDO=""; [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"
  $SUDO apt-get update -y >/tmp/apt.log 2>&1 || log "apt-get update failed (see /tmp/apt.log)"
  $SUDO apt-get install -y --no-install-recommends \
    xvfb fluxbox x11vnc novnc websockify xterm openssl xauth x11-utils x11-xserver-utils \
    fonts-dejavu-core fonts-liberation fonts-noto-core xfonts-base xfonts-75dpi xfonts-100dpi fontconfig \
    >>/tmp/apt.log 2>&1 || log "apt-get install had errors (see /tmp/apt.log)"
  $SUDO fc-cache -f >>/tmp/apt.log 2>&1 || true
fi

# --- 2. Virtual display + window manager -------------------------------------
if ! xdpyinfo -display :99 >/dev/null 2>&1; then
  log "Starting Xvfb on :99"
  Xvfb :99 -screen 0 1680x1010x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
  sleep 2
fi
# Make the freshly installed X core fonts visible even if Xvfb was already up, so
# LabVIEW's UI fonts (its Helvetica/Courier/Times aliases) resolve and buttons and
# text render instead of appearing blank.
xset +fp /usr/share/fonts/X11/misc,/usr/share/fonts/X11/75dpi,/usr/share/fonts/X11/100dpi 2>/dev/null || true
xset fp rehash 2>/dev/null || true
# Focus-follows-mouse + focus new windows so the on-screen terminal actually
# receives the ENTER keystroke (fluxbox defaults to click-to-focus, which made
# pressing ENTER over VNC seem to do nothing).
mkdir -p "$HOME/.fluxbox"
cat > "$HOME/.fluxbox/init" <<'FBINIT'
session.screen0.focusModel: MouseFocus
session.screen0.focusNewWindows: true
session.screen0.autoRaise: true
session.screen0.workspaces: 1
FBINIT
fluxbox >/tmp/fluxbox.log 2>&1 &
sleep 1

# --- 3. VNC server + noVNC web bridge ----------------------------------------
NOVNC_WEB=""
for d in /usr/share/novnc /usr/share/webapps/novnc /usr/lib/novnc; do
  [ -f "$d/vnc.html" ] && NOVNC_WEB="$d" && break
done
[ -z "$NOVNC_WEB" ] && log "noVNC web root not found; the browser client may 404." && NOVNC_WEB=/usr/share/novnc

x11vnc -storepasswd "$VNC_PW" /tmp/.vncpw >/dev/null 2>&1
log "Starting x11vnc on :99 (port 5900)"
x11vnc -display :99 -rfbauth /tmp/.vncpw -forever -shared -noxdamage -rfbport 5900 -bg -o /tmp/x11vnc.log

log "Starting websockify/noVNC on 6080 (web root: $NOVNC_WEB)"
websockify --web="$NOVNC_WEB" 6080 localhost:5900 >/tmp/websockify.log 2>&1 &
sleep 1

# --- 4. Launch the LabVIEW IDE UI --------------------------------------------
LV="$(command -v labview 2>/dev/null || true)"
[ -z "$LV" ] && LV="$(ls -1 /usr/local/natinst/LabVIEW-*/labview 2>/dev/null | sort -V | tail -1 || true)"
if [ -n "$LV" ]; then
  log "Launching LabVIEW: $LV"
  ( cd "$WS" && "$LV" >/tmp/labview.log 2>&1 & )
else
  log "Could not find the labview binary; open it from the on-screen terminal."
fi

# --- 5. On-screen "go" prompt -------------------------------------------------
# The human presses ENTER here after logging into / activating LabVIEW to run the
# selected activities. This keeps the whole handshake inside the session the user
# is already driving (no extra network channel needed).
cat > /tmp/lvci-prompt.sh <<PROMPT
#!/usr/bin/env bash
echo "=================================================================="
echo " LabVIEW CI - Debug Session"
echo "=================================================================="
echo
echo " 1. Log into / activate LabVIEW in the window that just opened."
echo " 2. When it is ready, press ENTER here to run the selected actions:"
echo "        ${ACTIONS:-<none - just an interactive session>}"
echo
echo " (Close this session from the dashboard's 'End session' button, or it"
echo "  ends automatically after ${MINUTES} minutes.)"
echo
read -r _
if [ -n "${ACTIONS}" ]; then
  bash "${WS}/.github/labview/debug/run-debug-actions.sh" ${ACTIONS}
else
  echo "No actions were selected - this is a free interactive session."
fi
echo
echo "Done. This window stays open until the session ends. Press ENTER to close it."
read -r _
PROMPT
chmod +x /tmp/lvci-prompt.sh
xterm -geometry 104x30+40+40 -T "LabVIEW CI Debug - press ENTER to run" -e bash /tmp/lvci-prompt.sh &

log "Debug desktop is up. Holding for ${MINUTES} minutes."
# --- 6. Hold the session, then exit so the host tears down -------------------
trap 'log "Received stop signal; exiting."; exit 0' TERM INT
sleep "$(( MINUTES * 60 ))" &
wait $!
log "Session time elapsed; exiting."
