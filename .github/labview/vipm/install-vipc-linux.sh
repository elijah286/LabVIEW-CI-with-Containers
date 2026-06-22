#!/usr/bin/env bash
set -euo pipefail

VIPC_DIR="${VIPC_DIR:-/opt/lvci/vipm}"
LABVIEW_VERSION="${LABVIEW_VERSION:-2026}"
export VIPM_NONINTERACTIVE="${VIPM_NONINTERACTIVE:-1}"
export VIPM_ASSUME_YES="${VIPM_ASSUME_YES:-1}"
export NO_COLOR="${NO_COLOR:-1}"

setup_display() {
  export DISPLAY="${DISPLAY:-:99}"
  if command -v Xvfb >/dev/null 2>&1 && ! pgrep -x Xvfb >/dev/null 2>&1; then
    Xvfb "$DISPLAY" -screen 0 1280x720x24 -ac +extension GLX +render -noreset >/tmp/xvfb.log 2>&1 &
  fi
  mkdir -p /tmp/natinst
  echo "1" > /tmp/natinst/LVContainer.txt
}

find_labview() {
  local candidate="/usr/local/natinst/LabVIEW-${LABVIEW_VERSION}-64/labview"
  if [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  find /usr/local/natinst /usr /opt -type f -name labview -perm -111 2>/dev/null | head -n 1
}

start_labview() {
  local labview_bin
  labview_bin="$(find_labview || true)"
  if [ -z "$labview_bin" ]; then
    echo "LabVIEW executable was not found; VIPM may fail to apply packages." >&2
    return 0
  fi
  if ! pgrep -f "$labview_bin" >/dev/null 2>&1; then
    echo "Starting LabVIEW headless: $labview_bin"
    "$labview_bin" --headless >/tmp/labview-headless.log 2>&1 &
  fi
}

find_vipm() {
  if command -v vipm >/dev/null 2>&1; then
    command -v vipm
    return 0
  fi
  if command -v vipm-cli >/dev/null 2>&1; then
    command -v vipm-cli
    return 0
  fi
  find /usr/local /usr /opt -type f \( -name vipm -o -name vipm-cli \) -perm -111 2>/dev/null | head -n 1
}

VIPM_BIN="$(find_vipm || true)"
if [ -z "$VIPM_BIN" ]; then
  echo "VIPM CLI was not found after installing the native VIPM package." >&2
  exit 1
fi

echo "Using VIPM CLI: $VIPM_BIN"
"$VIPM_BIN" --version || true
setup_display

vipc_files=()
while IFS= read -r vipc_file; do
  vipc_files+=("$vipc_file")
done < <(find "$VIPC_DIR" -maxdepth 1 -type f -iname '*.vipc' | sort)
if [ "${#vipc_files[@]}" -eq 0 ]; then
  echo "No VIPC files found in $VIPC_DIR; nothing to apply."
  exit 0
fi

if [ -n "${VIPM_SERIAL_NUMBER:-}" ]; then
  echo "Activating VIPM Pro license for ${VIPM_FULL_NAME:-VIPM user}..."
  activation_args=(--serial-number "$VIPM_SERIAL_NUMBER")
  if [ -n "${VIPM_FULL_NAME:-}" ]; then activation_args+=(--name "$VIPM_FULL_NAME"); fi
  if [ -n "${VIPM_EMAIL:-}" ]; then activation_args+=(--email "$VIPM_EMAIL"); fi
  "$VIPM_BIN" activate "${activation_args[@]}" || \
  "$VIPM_BIN" activate --serial-number "$VIPM_SERIAL_NUMBER" --full-name "${VIPM_FULL_NAME:-VIPM user}" --email "${VIPM_EMAIL:-}" || \
  "$VIPM_BIN" license activate "${activation_args[@]}" || \
  echo "VIPM activation command was not accepted; continuing with the installed license state."
fi

"$VIPM_BIN" refresh || "$VIPM_BIN" update || true

for vipc_file in "${vipc_files[@]}"; do
  echo "Applying VIPC: $vipc_file"
  start_labview
  if "$VIPM_BIN" install -y "$vipc_file" --labview-version "$LABVIEW_VERSION"; then
    continue
  fi
  if "$VIPM_BIN" install -y "$vipc_file"; then
    continue
  fi
  if "$VIPM_BIN" install "$vipc_file" --labview-version "$LABVIEW_VERSION" --yes; then
    continue
  fi
  if "$VIPM_BIN" apply_vipc "$vipc_file" --labview-version "$LABVIEW_VERSION"; then
    continue
  fi
  if "$VIPM_BIN" apply_vipc "$vipc_file"; then
    continue
  fi
  echo "Failed to apply VIPC: $vipc_file" >&2
  exit 1
done

"$VIPM_BIN" list --installed || true
echo "All VIPC files applied successfully."
