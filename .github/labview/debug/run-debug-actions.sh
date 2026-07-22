#!/usr/bin/env bash
# =============================================================================
# LabVIEW CI - Debug Session action runner (container side)
# =============================================================================
# Invoked from the on-screen prompt (debug-session.sh) when the user presses
# ENTER after logging into / activating LabVIEW. Runs the selected CI activities
# with the SAME entrypoints the Linux CI workflows use, streaming output to the
# on-screen terminal so you can watch each step execute in the live UI.
#
# Best-effort by design: this is an interactive aid. An activity without a wired
# headless runner just tells you to run it from the LabVIEW UI. Pure ASCII.
#
# Usage: run-debug-actions.sh <activity-id> [<activity-id> ...]
# =============================================================================
set -u

WS=/workspace
OUT="$WS/ci-out/debug"
mkdir -p "$OUT"

run_one() {
  local a="$1"
  case "$a" in
    masscompile)
      # Same entrypoint the Linux Mass Compile workflow uses.
      bash "$WS/.github/labview/masscompile.sh" "$WS" "$OUT/masscompile"
      ;;
    builds)
      # Best-effort: the build-binaries runner. Check its output in the UI.
      bash "$WS/.github/labview/build-binaries.sh" "$WS" "$OUT/builds" \
        || echo "build-binaries returned non-zero; run it from the LabVIEW UI to inspect."
      ;;
    vidiff|snapshots|snapshots2|vi-analyzer|unit-tests|antidoc)
      echo "No headless debug runner is wired for '$a' yet."
      echo "Open the project in LabVIEW and run this activity from the UI to reproduce it."
      ;;
    *)
      echo "Unknown activity '$a' - skipping."
      ;;
  esac
}

if [ "$#" -eq 0 ]; then
  echo "No activities were passed."
  exit 0
fi

for a in "$@"; do
  echo
  echo "================================================================"
  echo " Running: $a"
  echo "================================================================"
  run_one "$a"
  echo "---------------- done: $a ----------------"
done
