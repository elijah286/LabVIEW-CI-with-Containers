#!/usr/bin/env bash
# =============================================================================
# run-vi-analyzer.sh - Runs LabVIEW VI Analyzer in a Linux container
# =============================================================================
# Linux counterpart of run-vi-analyzer.ps1. Produces the SAME native VI Analyzer
# HTML report (index.html) that build-analyzer-report.py parses into the friendly,
# navigable report on the runner. Deployed under vi-analyzer/<sha>/linux/ so the
# dashboard can show the Windows and Linux outcomes side by side - just like the
# Mass Compile and VIDiff reports.
#
# Usage (inside container, workspace mounted at /workspace):
#   bash /workspace/.github/labview/run-vi-analyzer.sh \
#       /workspace \
#       /workspace/ci-out/vi-analyzer
#
# A single-VI re-run (the report's "Re-run analysis" on one VI) is driven by the
# VIA_FILES (pipe-delimited repo paths) and VIA_CONFIG (a committed .viancfg)
# environment variables, mirroring the Windows runner's -FilesFilter / -ConfigOverride.
# =============================================================================
set -uo pipefail

WORKSPACE_ROOT="${1:-/workspace}"
REPORT_DIR="${2:-/report}"
CONFIG_MANIFEST="${3:-}"
[ -n "$CONFIG_MANIFEST" ] || CONFIG_MANIFEST="$WORKSPACE_ROOT/.github/labview-ci.yml"

FILES_FILTER="${VIA_FILES:-}"
CONFIG_OVERRIDE="${VIA_CONFIG:-}"

# LabVIEWCLI is on PATH in the NI Linux container; labviewprofull year varies by tag.
LABVIEWCLI="LabVIEWCLI"
LABVIEW_EXE="$(find /usr/local/natinst -name 'labviewprofull' 2>/dev/null | head -1)"
if [ -z "$LABVIEW_EXE" ]; then
  echo "ERROR: labviewprofull not found in /usr/local/natinst" >&2
  exit 1
fi

mkdir -p "$REPORT_DIR"
HTML_OUT="$REPORT_DIR/index.html"

echo "=== VI Analyzer (Linux) ==="
echo "  Workspace : $WORKSPACE_ROOT"
echo "  LabVIEW   : $LABVIEW_EXE"
echo ""

# --- config.viAnalyzer support ------------------------------------------------
# Read the flat viAnalyzer.default value from .github/labview-ci.yml (the same
# format the Configure dialog / reconfigure workflow write). Absent -> empty.
read_via_default() {
  [ -f "$CONFIG_MANIFEST" ] || return 0
  awk '
    /^  viAnalyzer:[[:space:]]*$/ { inv=1; next }
    inv && /^    default:/ {
      v=$0; sub(/^    default:[[:space:]]*/,"",v); gsub(/"/,"",v);
      sub(/[[:space:]]*#.*$/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v);
      print v; exit
    }
    inv && /^[[:space:]]{0,3}[^[:space:]]/ { exit }
  ' "$CONFIG_MANIFEST"
}

# First committed .viancfg (repo-relative) outside CI tooling dirs -> the
# pipeline's auto-default when a project committed a config but did not pick one.
first_viancfg() {
  find "$WORKSPACE_ROOT" -type f -name '*.viancfg' 2>/dev/null \
    | grep -vE '/(\.github|actions|ci-out|build)/' \
    | sort | head -1
}

# Shallowest .lvproj (fewest path segments) outside CI tooling dirs.
first_lvproj() {
  find "$WORKSPACE_ROOT" -type f -name '*.lvproj' 2>/dev/null \
    | grep -vE '/(\.github|actions|ci-out|build)/' \
    | awk -F/ '{print NF" "$0}' | sort -n | head -1 | cut -d' ' -f2-
}

# Build a runtime .viancfg from a base config, analyzing the whole PROJECT
# (AnalyzeProject=TRUE + ProjectPath) with the config's own test selection kept.
# __WORKSPACE_PATH__ is expanded. If the base has no AnalyzeProject/ProjectPath
# tags the sed no-ops and the caller's 0-tests fallback covers it.
build_project_config() {
  # $1 base cfg, $2 lvproj abs path, $3 out path
  sed -e "s|__WORKSPACE_PATH__|$WORKSPACE_ROOT|g" \
      -e "s|<AnalyzeProject>[^<]*</AnalyzeProject>|<AnalyzeProject>TRUE</AnalyzeProject>|" \
      -e "s|<ProjectPath>[^<]*</ProjectPath>|<ProjectPath>\"$2\"</ProjectPath>|" \
      "$1" > "$3"
}

# Build a runtime .viancfg whose <ItemsToAnalyze> lists exactly the given VIs
# (the single-VI re-run). __WORKSPACE_PATH__ is expanded.
build_scoped_items() {
  # $1 base cfg, $2 out path; VI abs paths in the global VI_ABS[] array.
  local items=""
  local p
  for p in "${VI_ABS[@]}"; do
    items="${items}\t\t<Item>\n\t\t\t<Path>\"$p\"</Path>\n\t\t\t<Removed>FALSE</Removed>\n\t\t</Item>\n"
  done
  sed "s|__WORKSPACE_PATH__|$WORKSPACE_ROOT|g" "$1" > "$2.tmp"
  awk -v items="$items" '
    /<ItemsToAnalyze>/ { print "\t<ItemsToAnalyze>"; printf items; inblk=1; next }
    /<\/ItemsToAnalyze>/ { print "\t</ItemsToAnalyze>"; inblk=0; next }
    inblk { next }
    { print }
  ' "$2.tmp" > "$2"
  rm -f "$2.tmp"
}

# Native "Total Tests Run: N" count from a generated report (for the 0-tests
# fallback). Missing/unparseable -> 0 (safe: forces the full directory suite).
tests_in_report() {
  [ -f "$1" ] || { echo 0; return; }
  local n
  n="$(grep -oE 'Total Tests Run[^0-9]*[0-9]+' "$1" | grep -oE '[0-9]+' | tail -1)"
  echo "${n:-0}"
}

run_via() {
  # $1 ConfigPath (a .viancfg OR a directory for the full built-in suite), $2 ReportPath
  echo "  RunVIAnalyzer -ConfigPath '$1' -ReportPath '$2'"
  "$LABVIEWCLI" \
    -LogToConsole   TRUE \
    -OperationName  RunVIAnalyzer \
    -ConfigPath     "$1" \
    -ReportPath     "$2" \
    -ReportSaveType HTML \
    -LabVIEWPath    "$LABVIEW_EXE" \
    -Headless
  return $?
}

write_placeholder_report() {
  # $1 path, $2 message
  cat > "$1" <<HTML
<html><body><table>
<tr><td>VIs Analyzed</td><td>0</td></tr>
<tr><td>Total Tests Run</td><td>0</td></tr>
<tr><td>Passed Tests</td><td>0</td></tr>
<tr><td>Failed Tests</td><td>0</td></tr></table>
<a name="fail"></a><p>$2</p></body></html>
HTML
}

# --- Build the analysis plan --------------------------------------------------
# A "pass" runs RunVIAnalyzer once. With no configuration this collapses to a
# SINGLE directory-mode pass: passing the workspace DIRECTORY as -ConfigPath makes
# LabVIEWCLI run the FULL DEFAULT VI Analyzer test set over every VI under it (the
# invocation that produces the historical working reports). A committed default
# .viancfg instead analyzes the whole PROJECT (AnalyzeProject) with that config's
# tests; if it runs 0 tests we fall back to directory mode so the report is never
# blank.
CONFIG_ARG=""
PASS_KIND=""
FALLBACK_DIR=""

if [ -n "$FILES_FILTER" ]; then
  if [ -z "$CONFIG_OVERRIDE" ]; then
    echo "ERROR: a single-VI re-run (VIA_FILES) requires VIA_CONFIG (a .viancfg)." >&2
    exit 1
  fi
  VI_ABS=()
  IFS='|' read -r -a _rel <<< "$FILES_FILTER"
  for r in "${_rel[@]}"; do
    r="$(printf '%s' "$r" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$r" ] && VI_ABS+=("$WORKSPACE_ROOT/$r")
  done
  BASE_CFG="$WORKSPACE_ROOT/$CONFIG_OVERRIDE"
  SCOPED="$REPORT_DIR/via-rerun.viancfg"
  build_scoped_items "$BASE_CFG" "$SCOPED"
  CONFIG_ARG="$SCOPED"
  PASS_KIND="rule"
  echo "  Mode      : single-VI re-run (${#VI_ABS[@]} VI) with $CONFIG_OVERRIDE"
else
  DEF="$(read_via_default)"
  if [ -z "$DEF" ]; then
    AUTO="$(first_viancfg)"
    AUTO="${AUTO#"$WORKSPACE_ROOT"/}"
    if [ -n "$AUTO" ]; then
      DEF="$AUTO"
      echo "  Auto-detected default config: $AUTO"
    else
      DEF="builtin"
    fi
  fi
  if [ "$DEF" = "builtin" ] || [ "$DEF" = "none" ]; then
    CONFIG_ARG="$WORKSPACE_ROOT"
    PASS_KIND="directory"
    echo "  Mode      : full built-in suite (analyze workspace directory)"
  else
    BASE_CFG="$WORKSPACE_ROOT/$DEF"
    PROJ="$(first_lvproj)"
    if [ -n "$PROJ" ] && [ -f "$BASE_CFG" ]; then
      SCOPED="$REPORT_DIR/default.viancfg"
      build_project_config "$BASE_CFG" "$PROJ" "$SCOPED"
      CONFIG_ARG="$SCOPED"
      PASS_KIND="project"
      FALLBACK_DIR="$WORKSPACE_ROOT"
      echo "  Mode      : project config $DEF (AnalyzeProject) with directory fallback"
    else
      CONFIG_ARG="$WORKSPACE_ROOT"
      PASS_KIND="directory"
      echo "  Mode      : full built-in suite (no project found; analyze workspace directory)"
    fi
  fi
fi
echo ""

# --- Recompile the workspace to this image's LabVIEW version BEFORE analyzing --
# The VI Analyzer only analyzes VIs already saved in the running LabVIEW's
# version; VIs saved in an OLDER version are silently skipped, producing an empty
# "0 VIs analyzed" report even though the VIs load fine. A headless MassCompile
# upgrades every VI in place. Compile each top-level PROJECT folder individually,
# EXCLUDING the CI's own tooling under .github (and .git/actions/ci-out/build) -
# the vendored VI Browser render VIs there carry deps that only exist in their own
# image and would fail the whole compile before reaching the project VIs.
# Best-effort: a non-zero MassCompile must NOT block analysis (bash has no -e here,
# so a failing LabVIEWCLI just logs its exit code and we continue).
echo "=== Pre-analysis MassCompile (upgrade VIs to image LabVIEW version) ==="
pre_start=$(date +%s)
compiled_any=false
for d in "$WORKSPACE_ROOT"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  case "$name" in
    .git|.github|actions|ci-out|build) continue ;;
  esac
  compiled_any=true
  "$LABVIEWCLI" \
    -LogToConsole       TRUE \
    -OperationName      MassCompile \
    -DirectoryToCompile "$d" \
    -LabVIEWPath        "$LABVIEW_EXE" \
    -Headless 2>&1
  echo "  MassCompile '$name' exit=$?"
done
if [ "$compiled_any" = false ]; then
  "$LABVIEWCLI" \
    -LogToConsole       TRUE \
    -OperationName      MassCompile \
    -DirectoryToCompile "$WORKSPACE_ROOT" \
    -LabVIEWPath        "$LABVIEW_EXE" \
    -Headless 2>&1
  echo "  MassCompile '.' exit=$?"
fi
echo "  Pre-analysis MassCompile duration=$(( $(date +%s) - pre_start ))s"
echo ""

# --- Run the analysis pass ----------------------------------------------------
START=$(date +%s)
echo "=== VI Analyzer pass ($PASS_KIND) ==="
run_via "$CONFIG_ARG" "$HTML_OUT"
EXIT_CODE=$?
echo "  pass exit=$EXIT_CODE"

# A project-config pass that ran 0 tests (e.g. a .viancfg whose ItemsToAnalyze is
# empty) falls back to the full directory-mode suite so the report is never blank.
if [ "$PASS_KIND" = "project" ]; then
  N="$(tests_in_report "$HTML_OUT")"
  if [ "$N" = "0" ]; then
    echo "  Project pass ran 0 tests; falling back to the full directory suite"
    run_via "$FALLBACK_DIR" "$HTML_OUT"
    EXIT_CODE=$?
    echo "  fallback pass exit=$EXIT_CODE"
  fi
fi

DURATION=$(( $(date +%s) - START ))
echo ""
echo "=== VI Analyzer finished (duration=${DURATION}s) ==="

if [ ! -f "$HTML_OUT" ]; then
  write_placeholder_report "$HTML_OUT" "No VI Analyzer report was generated."
  echo "No report produced; wrote a placeholder report."
fi

# Exit code 3 = analysis ran but found rule failures -> success (failures are in
# the report). Any other non-zero from the pass is a real error.
if [ "$EXIT_CODE" -ne 0 ] && [ "$EXIT_CODE" -ne 3 ]; then
  exit "$EXIT_CODE"
fi
exit 0
