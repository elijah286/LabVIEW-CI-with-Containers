#!/usr/bin/env bash
# =============================================================================
# masscompile.sh — Runs LabVIEW Mass Compile in a Linux container
# =============================================================================
# Linux counterpart of masscompile.ps1. Compiles every VI under the workspace,
# tees the LabVIEWCLI log, and records the exit code / duration in
# compile-meta.json. The friendly report (index.html + problems.json +
# summary.json) is built afterwards on the runner by build-masscompile-report.py,
# which parses this log — so this script stays minimal and platform-specific.
#
# Usage (inside container, workspace mounted at /workspace):
#   bash /workspace/.github/labview/masscompile.sh /workspace /workspace/ci-out/masscompile
# =============================================================================
set -uo pipefail

WORKSPACE_ROOT="${1:-/workspace}"
REPORT_DIR="${2:-/report}"

mkdir -p "$REPORT_DIR"
LOG_FILE="$REPORT_DIR/masscompile.log"
META_FILE="$REPORT_DIR/compile-meta.json"
HTML_OUT="$REPORT_DIR/index.html"

# LabVIEWCLI is on PATH in the NI Linux container; labviewprofull year varies by tag.
LABVIEWCLI="LabVIEWCLI"
LABVIEW_EXE="$(find /usr/local/natinst -name 'labviewprofull' 2>/dev/null | head -1)"
if [ -z "$LABVIEW_EXE" ]; then
  echo "ERROR: labviewprofull not found in /usr/local/natinst" >&2
  exit 1
fi
# Best-effort LabVIEW year from the install path (e.g. .../LabVIEW-2026-64/...).
LABVIEW_VERSION="$(printf '%s' "$LABVIEW_EXE" | grep -oE '20[0-9]{2}' | head -1)"
LABVIEW_VERSION="${LABVIEW_VERSION:-2026}"

echo "=== Mass Compile (Linux) ==="
echo "  Workspace : $WORKSPACE_ROOT"
echo "  LabVIEW   : $LABVIEW_EXE"
echo ""

START=$(date +%s)

# MassCompile prints its operation output to stderr; merge it into the log and
# judge success by the real exit code (mirrors the Windows script).
"$LABVIEWCLI" \
    -OperationName      MassCompile \
    -DirectoryToCompile "$WORKSPACE_ROOT" \
    -LabVIEWPath        "$LABVIEW_EXE" \
    -Headless \
    > "$LOG_FILE" 2>&1 || EXIT_CODE=$?

EXIT_CODE="${EXIT_CODE:-0}"
END=$(date +%s)
DURATION=$(( END - START ))

if [ ! -s "$LOG_FILE" ]; then echo "(no output captured)" > "$LOG_FILE"; fi

# exit 3 = finished with some bad VIs (partial, not a failure); any other non-zero
# is a real failure.
if [ "$EXIT_CODE" -ne 0 ] && [ "$EXIT_CODE" -ne 3 ]; then STATUS="failed"; else STATUS="ok"; fi

cat > "$META_FILE" <<JSON
{"platform":"linux","exit":$EXIT_CODE,"duration":$DURATION,"labview_version":"$LABVIEW_VERSION","status":"$STATUS"}
JSON

# Minimal fallback report so the dashboard never 404s if the friendly builder is
# skipped; the runner's build-masscompile-report.py overwrites this with the
# rich, navigable report.
LOG_HTML="$(sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$LOG_FILE")"
# Shared site header (lvci-header.js, deployed once at the Pages root) so even this
# safety-net report (emitted only when the friendly Python builder is skipped/fails)
# renders inside the dashboard chrome. Linux reports live at masscompile/<sha>/linux/,
# so the shared asset is three levels up. Mirrors the friendly report's window.LVCI.
HDR_REPO="${GITHUB_REPOSITORY:-}"
HDR_SHA="${GITHUB_SHA:-}"
HDR_SHORT="${HDR_SHA:0:7}"
cat > "$HTML_OUT" <<HTML
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mass Compile (Linux) — LabVIEW-CI-with-Containers</title>
<script>window.LVCI={context:'masscompile-report',repo:'$HDR_REPO',pagesUrl:'../../..',sha:'$HDR_SHA',short:'$HDR_SHORT',platform:'linux',rawUrl:'masscompile.log'};</script>
<script src="../../../lvci-header.js" defer></script>
<style>body{margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0d1117;color:#e6edf3}
.wrap{max-width:1180px;margin:0 auto;padding:20px}
pre{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:14px;font-size:.75em;white-space:pre-wrap;word-break:break-all}</style>
</head><body><div class="wrap"><h1>Mass Compile (Linux)</h1><pre>$LOG_HTML</pre></div></body></html>
HTML

echo ""
echo "=== Mass Compile (Linux) finished (exit=$EXIT_CODE duration=${DURATION}s) ==="

if [ "$STATUS" = "failed" ]; then exit 1; else exit 0; fi
