#!/bin/bash
# Start the virtual display, pre-launch a headless LabVIEW with VI Server enabled,
# wait until its VI Server TCP port is up, then run the one-shot toimages runner
# (which attaches to that LabVIEW via lvctl). First-party glue only.
set -e

export DISPLAY=:99
# The toimages renderer captures LabVIEW block-diagram images via VI scripting,
# and that capture is bounded by the virtual screen. A cramped framebuffer makes
# large diagrams come back clipped/empty (and can fail the render outright), so
# default to a generous screen; override XVFB_RESOLUTION (WxHxDepth) to tune it.
XVFB_RESOLUTION="${XVFB_RESOLUTION:-5120x4096x24}"
echo "Starting Xvfb (virtual display ${XVFB_RESOLUTION}) for headless LabVIEW..."
# -nolisten unix avoids needing a root-owned /tmp/.X11-unix directory.
Xvfb "$DISPLAY" -screen 0 "$XVFB_RESOLUTION" -ac +extension GLX +render -noreset -nolisten unix &
XVFB_PID=$!

sleep 1
if kill -0 "$XVFB_PID" 2>/dev/null; then
  echo "Xvfb started (pid $XVFB_PID)."
else
  echo "ERROR: Xvfb failed to start." >&2
  exit 1
fi

# Pre-launch ONE LabVIEW with VI Server enabled (-pref), with its output sent to
# a log file so it never holds the runner's stdout/stderr. The render engine
# (lvctl) then ATTACHES to this instance over VI Server TCP instead of launching
# its own — which avoids both a second instance fighting for the port and the
# exec-capture deadlock where a lvctl-launched, long-lived LabVIEW inherits and
# holds the runner's captured pipes (hanging the whole batch on the first VI).
LABVIEW_BIN="${LABVIEW_PATH:-/usr/local/natinst/LabVIEW-2026-64}/labview"
LABVIEW_LOG="${LABVIEW_LOG:-/tmp/labview.log}"
PORT="${LABVIEW_VISERVER_PORT:-3363}"
echo "Launching LabVIEW with VI Server: $LABVIEW_BIN -pref $LABVIEW_CONF (log -> $LABVIEW_LOG)"
"$LABVIEW_BIN" -pref "$LABVIEW_CONF" >"$LABVIEW_LOG" 2>&1 &

# Wait for the native VI Server TCP port (enabled by the server.tcp.* keys in
# labview.conf) to come up, so every lvctl call attaches instead of launching.
# Fail fast with a clear message if it never opens — that means this LabVIEW did
# not honor the server.tcp keys, which beats silently grinding for an hour.
probe() { (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; }
wait_secs="${VISERVER_WAIT_SECONDS:-240}"
deadline=$(( SECONDS + wait_secs ))
echo "Waiting up to ${wait_secs}s for LabVIEW VI Server on 127.0.0.1:${PORT}..."
until probe; do
  if (( SECONDS >= deadline )); then
    echo "ERROR: VI Server never opened on port ${PORT} within ${wait_secs}s." >&2
    echo "       The server.tcp.* keys in ${LABVIEW_CONF} were likely not honored by this LabVIEW." >&2
    echo "------ tail of ${LABVIEW_LOG} ------" >&2
    tail -n 60 "$LABVIEW_LOG" >&2 2>/dev/null || true
    exit 1
  fi
  sleep 2
done
echo "VI Server is up on port ${PORT}; warming up..."
sleep 10

echo "Starting toimages batch runner (attaches to the LabVIEW launched above)..."
exec /app/runner
