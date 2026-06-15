#!/usr/bin/env bash
# =============================================================================
# run-vi-analyzer.sh — Runs LabVIEW VI Analyzer in a Linux container
# =============================================================================
# Usage (inside container, workspace mounted at /workspace):
#   bash /workspace/.github/labview/run-vi-analyzer.sh \
#       /workspace                          # WorkspaceRoot
#       /report                             # ReportDir
# =============================================================================
set -euo pipefail

WORKSPACE_ROOT="${1:-/workspace}"
REPORT_DIR="${2:-/report}"
CONFIG_TEMPLATE="${WORKSPACE_ROOT}/.github/labview/via-configs/via-config-default.viancfg"

# LabVIEWCLI is on PATH in the NI Linux container
LABVIEWCLI="LabVIEWCLI"
# Discover labviewprofull dynamically (year varies by image tag)
LABVIEW_EXE=$(find /usr/local/natinst -name "labviewprofull" 2>/dev/null | head -1)
if [ -z "$LABVIEW_EXE" ]; then echo "ERROR: labviewprofull not found in /usr/local/natinst" >&2; exit 1; fi
echo "Using LabVIEW: $LABVIEW_EXE"

mkdir -p "$REPORT_DIR"

CONFIG_FILE="$REPORT_DIR/via-config.viancfg"
RESULTS_XML="$REPORT_DIR/via-results.xml"
HTML_OUT="$REPORT_DIR/index.html"

echo "=== VI Analyzer (Linux) ==="
echo "  Workspace  : $WORKSPACE_ROOT"
echo "  Config src : $CONFIG_TEMPLATE"

# Patch __WORKSPACE_PATH__ placeholder
sed "s|__WORKSPACE_PATH__|${WORKSPACE_ROOT}|g" "$CONFIG_TEMPLATE" > "$CONFIG_FILE"

# Build TestConfigData from installed VI Analyzer test LLBs so Linux runs the full suite.
LABVIEW_ROOT="$(dirname "$LABVIEW_EXE")"
TEST_ROOT="$LABVIEW_ROOT/resource/dialog/VI Analyzer/tests"
TEST_ENTRIES_FILE="$REPORT_DIR/via-tests.xml"
TEST_COUNT=0

if [ -d "$TEST_ROOT" ]; then
  : > "$TEST_ENTRIES_FILE"
  while IFS= read -r llb; do
    rel_path="${llb#${LABVIEW_ROOT}/}"
    test_name="$(basename "$llb" .llb)"
    cat >> "$TEST_ENTRIES_FILE" <<EOF
		<Test>
			<Name>"$test_name"</Name>
			<Ranking>1</Ranking>
			<MaxFailures>5</MaxFailures>
			<BasePath>"$LABVIEW_ROOT"</BasePath>
			<RelativePath>"$rel_path"</RelativePath>
			<Selected>TRUE</Selected>
			<Controls>
			</Controls>
		</Test>
EOF
    TEST_COUNT=$((TEST_COUNT+1))
  done < <(find "$TEST_ROOT" -type f -name '*.llb' | sort)

  if [ "$TEST_COUNT" -gt 0 ]; then
    awk -v tests_file="$TEST_ENTRIES_FILE" '
      /<TestConfigData>/ {
        print
        while ((getline line < tests_file) > 0) print line
        close(tests_file)
        next
      }
      { print }
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  fi
fi

echo "  Config out : $CONFIG_FILE"
echo "  VIA tests  : $TEST_COUNT discovered at $TEST_ROOT"

START=$(date +%s)

"$LABVIEWCLI" \
    -OperationName RunVIAnalyzer \
    -LabVIEWPath "$LABVIEW_EXE" \
    -ConfigPath "$CONFIG_FILE" \
    -ReportPath "$RESULTS_XML" \
    -Headless || EXIT_CODE=$?

EXIT_CODE="${EXIT_CODE:-0}"
END=$(date +%s)
DURATION=$(( END - START ))

echo ""
echo "=== VI Analyzer finished (exit=$EXIT_CODE duration=${DURATION}s) ==="

# Generate minimal HTML wrapper around the XML results
XML_CONTENT="$(cat "$RESULTS_XML" 2>/dev/null || echo '(no results file)')"
# Escape for HTML
XML_HTML="$(echo "$XML_CONTENT" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
REPORT_TS="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

if [ "$EXIT_CODE" -eq 0 ]; then
    STATUS="PASSED"; BADGE_COLOR="#2ea043"
else
    STATUS="FAILED"; BADGE_COLOR="#da3633"
fi

cat > "$HTML_OUT" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>VI Analyzer — LabVIEW-CI-with-Containers</title>
  <style>
    *{box-sizing:border-box}
    body{margin:0;padding:20px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0d1117;color:#e6edf3}
    .card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:20px;margin-bottom:16px}
    h1{margin:0 0 12px;font-size:1.3em}
    .badge{display:inline-block;padding:3px 10px;border-radius:4px;font-weight:700;font-size:.85em;color:#fff;background:${BADGE_COLOR}}
    .meta{margin-top:10px;font-size:.82em;color:#8b949e}
    pre{background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:14px;font-size:.75em;white-space:pre-wrap;overflow-y:auto;max-height:65vh;margin:0}
  </style>
</head>
<body>
  <div class="card">
    <h1>VI Analyzer — LabVIEW-CI-with-Containers</h1>
    <span class="badge">${STATUS}</span>
    <div class="meta">Date: ${REPORT_TS} &nbsp;|&nbsp; Duration: ${DURATION}s</div>
  </div>
  <pre>${XML_HTML}</pre>
</body>
</html>
HTML

echo "HTML report → $HTML_OUT"
exit "$EXIT_CODE"
