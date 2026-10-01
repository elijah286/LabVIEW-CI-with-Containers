#!/usr/bin/env bash
# =============================================================================
# run-unit-tests.sh - Runs the configured LabVIEW unit-test frameworks in a
# Linux container
# =============================================================================
# Linux counterpart of run-unit-tests.ps1. The two scripts share no code (the
# repo keeps per-OS runners, like run-vi-analyzer.ps1/.sh), but they share a
# CONTRACT, so one config works on both platforms and build-unittest-report.py
# treats both the same way:
#
#   * Config: config.unitTests.tools.<tool> with `enabled`, an optional `command`
#     override and `locations` (see read_unit_test_tools below).
#   * Locations: a directory is taken as-is; a glob / file extension is expanded
#     and each match contributes its parent directory; empty = whole workspace.
#   * Command tokens: {cli}=LabVIEWCLI, {lv}=LabVIEW executable, {dir}=a resolved
#     test-root directory, {out}=JUnit output path, {ver}=LabVIEW year.
#   * Output: <results-dir>/<tool>-<n>.xml (JUnit) per test root, plus
#     <results-dir>/_tooling.json = {"missing":[{tool,name,kind,detail}]} when a
#     configured tool could not run. kind is `missing-tooling` (the container
#     lacks the tool; the report shows the "set up the container" banner),
#     `error`, or `unsupported-on-linux` (no Linux handler yet).
#   * Always exits 0: pass/fail comes from the JUnit content.
#
# Only LUnit runs on Linux today. To add a framework, write a run_<id>() handler
# with the same contract as run_lunit() and add its id to LINUX_TOOLS.
#
# LabVIEWCLI on Linux: -Headless must be the LAST argument (anything after it is
# swallowed), and the exit code is not a result (a failed operation exits 255),
# so only the JUnit file counts.
#
# Usage (inside container, workspace mounted at /workspace):
#   bash /workspace/.github/labview/run-unit-tests.sh \
#       /workspace \
#       /workspace/ci-out/unit-tests/results \
#       [/workspace/.github/labview-ci.yml]
# =============================================================================
set -uo pipefail
shopt -s globstar nullglob dotglob

WORKSPACE_ROOT="${1:-/workspace}"
RESULTS_DIR="${2:-/workspace/ci-out/unit-tests/results}"
CONFIG_PATH="${3:-}"
[ -n "$CONFIG_PATH" ] || CONFIG_PATH="$WORKSPACE_ROOT/.github/labview-ci.yml"
WORKSPACE_ROOT="${WORKSPACE_ROOT%/}"

mkdir -p "$RESULTS_DIR"

# Tools that can run in the Linux worker. To add a framework, write a
# run_<id>() handler with the same contract and add its id here.
LINUX_TOOLS=(lunit)

# LabVIEWCLI is on PATH in the NI Linux container; labviewprofull year varies by tag.
LABVIEWCLI="${LABVIEWCLI:-$(command -v LabVIEWCLI 2>/dev/null || true)}"
LABVIEW_EXE="${LABVIEW_EXE:-$(find /usr/local/natinst -name 'labviewprofull' 2>/dev/null | head -1)}"
LABVIEW_VERSION="${LABVIEW_VERSION:-}"
if [ -z "$LABVIEW_VERSION" ] && [[ "$LABVIEW_EXE" =~ LabVIEW-([0-9]{4}) ]]; then
  LABVIEW_VERSION="${BASH_REMATCH[1]}"
fi
LABVIEW_VERSION="${LABVIEW_VERSION:-2026}"

echo "=== Unit Tests (Linux) ==="
echo "  Workspace : $WORKSPACE_ROOT"
echo "  Results   : $RESULTS_DIR"
echo "  LabVIEW   : ${LABVIEW_EXE:-<not found>}  (v$LABVIEW_VERSION)"
echo "  LabVIEWCLI: ${LABVIEWCLI:-<not found>}"
echo "  Config    : $CONFIG_PATH"
echo ""

# --- _tooling.json findings --------------------------------------------------
TOOLING_ISSUES=()
has_tooling_issue() {
  local entry
  for entry in "${TOOLING_ISSUES[@]+"${TOOLING_ISSUES[@]}"}"; do
    [[ "$entry" == "{\"tool\": \"$1\","* ]] && return 0
  done
  return 1
}
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}
add_tooling_issue() {
  # $1 tool id, $2 display name, $3 kind, $4 detail
  TOOLING_ISSUES+=("{\"tool\": \"$(json_escape "$1")\", \"name\": \"$(json_escape "$2")\", \"kind\": \"$(json_escape "$3")\", \"detail\": \"$(json_escape "$4")\"}")
}

tool_display_name() {
  case "$1" in
    lunit)     echo "LUnit" ;;
    caraya)    echo "Caraya" ;;
    vi-tester) echo "JKI VI Tester" ;;
    utf)       echo "NI Unit Test Framework" ;;
    *)         echo "$1" ;;
  esac
}

# --- Minimal reader for config.unitTests.tools --------------------------------
# Same fixed, shallow shape as Read-UnitTestTools in run-unit-tests.ps1:
#   config:
#     unitTests:
#       tools:
#         lunit:
#           enabled: true
#           command: "<optional override with {cli} {lv} {dir} {out} {ver} tokens>"
#           locations:
#             - "tests/"
#             - "**/*.lvclass"
# Prints one line per ENABLED tool: <id> US <command> US <location>... (US=\x1f).
read_unit_test_tools() {
  [ -f "$1" ] || return 0
  awk '
    function flush() {
      if (cur != "" && enabled) print cur "\037" cmd locs
      cur = ""; enabled = 0; cmd = ""; locs = ""; inloc = 0
    }
    function unquote(s) {
      sub(/[[:space:]]+$/, "", s)
      if (s ~ /^".*"$/) {
        # YAML double-quoted scalar: drop the quotes and undo \" and \\ escapes.
        s = substr(s, 2, length(s) - 2)
        gsub(/\\\\/, "\001", s); gsub(/\\"/, "\"", s); gsub(/\001/, "\\", s)
      }
      return s
    }
    { gsub(/\r$/, ""); gsub(/\t/, "    ") }
    /^[[:space:]]*unitTests:[[:space:]]*$/ { flush(); inut = 1; intools = 0; next }
    !inut { next }
    /^  tools:[[:space:]]*$/ { intools = 1; next }
    intools && /^    [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      flush()
      cur = $0; sub(/^    /, "", cur); sub(/:[[:space:]]*$/, "", cur); cur = tolower(cur)
      next
    }
    cur != "" && /^      enabled:[[:space:]]*(true|false)[[:space:]]*$/ { enabled = ($0 ~ /true/); inloc = 0; next }
    cur != "" && /^      command:[[:space:]]*[^[:space:]]/ {
      c = $0; sub(/^      command:[[:space:]]*/, "", c); cmd = unquote(c); inloc = 0; next
    }
    cur != "" && /^      locations:[[:space:]]*\[[[:space:]]*\][[:space:]]*$/ { locs = ""; inloc = 0; next }
    cur != "" && /^      locations:[[:space:]]*$/ { inloc = 1; next }
    cur != "" && inloc && /^        -[[:space:]]*/ {
      l = $0; sub(/^        -[[:space:]]*/, "", l); l = unquote(l)
      if (l != "") locs = locs "\037" l
      next
    }
    /^[^[:space:]]/ { flush(); inut = 0; intools = 0 }
    END { flush() }
  ' "$1"
}

# --- Resolve locations (dir OR glob/extension) to test-root directories -------
# Mirrors Resolve-TestRoots: a directory is taken as-is; a glob / extension is
# expanded (recursively when it has no path separator) and each match contributes
# its parent directory. Prints absolute, de-duplicated paths.
resolve_test_roots() {
  local loc full match
  {
    for loc in "$@"; do
      [ -n "$loc" ] || continue
      loc="${loc//\\//}"
      loc="${loc#./}"
      full="$WORKSPACE_ROOT/${loc%/}"
      if [ -d "$full" ]; then
        (cd "$full" && pwd)
        continue
      fi
      local pattern="$full"
      [[ "$loc" == */* ]] || pattern="$WORKSPACE_ROOT/**/$loc"
      for match in $pattern; do
        if [ -f "$match" ]; then
          (cd "$(dirname "$match")" && pwd)
        fi
      done
    done
  } | sort -u
}

# --- Run a LabVIEWCLI command and echo the session log on failure -------------
# $1 tool id, $2 command. Sets CLI_OUTPUT to the console output + session log.
CLI_OUTPUT=""
run_cli_command() {
  local id="$1" cmd="$2" out_file rc
  out_file="$(mktemp)"
  echo "  [$id] $cmd"
  # Redirect to a file, never pipe: LabVIEWCLI starts LabVIEW as a child that
  # inherits these descriptors and keeps running after LabVIEWCLI returns, so a
  # pipe reader (e.g. tee) would never see EOF and the step would hang.
  bash -c "$cmd" > "$out_file" 2>&1
  rc=$?
  CLI_OUTPUT="$(cat "$out_file")"
  printf '%s\n' "$CLI_OUTPUT"
  echo "  [$id] exit=$rc (not a result; the JUnit file is)"
  rm -f "$out_file"
}

print_session_log() {
  # $1 tool id. The console error is generic; the real detail lives in the CLI's
  # own session log. Appends the log to CLI_OUTPUT so it can be classified too.
  local id="$1" log_path=""
  local re=$'[Ss]tarted logging in file:[ \t]*([^\n]*\\.log)'
  [[ "$CLI_OUTPUT" =~ $re ]] && log_path="${BASH_REMATCH[1]}"
  if [ -z "$log_path" ]; then
    echo "  [$id] (no CLI session-log path found in output)"
    return 0
  fi
  echo "  [$id] --- LabVIEW CLI session log ($log_path) ---"
  if [ -f "$log_path" ]; then
    sed "s/^/  [$id-log] /" "$log_path"
    CLI_OUTPUT="$CLI_OUTPUT"$'\n'"$(cat "$log_path")"
  else
    echo "  [$id] (session log not found on disk)"
  fi
  echo "  [$id] --- end LabVIEW CLI session log ---"
}

expand_tokens() {
  # $1 template, $2 {dir}, $3 {out}
  local s="$1"
  s="${s//\{cli\}/$LABVIEWCLI}"
  s="${s//\{lv\}/$LABVIEW_EXE}"
  s="${s//\{dir\}/$2}"
  s="${s//\{out\}/$3}"
  s="${s//\{ver\}/$LABVIEW_VERSION}"
  printf '%s' "$s"
}

# --- LUnit (Astemes) ----------------------------------------------------------
# The LUnit CLI package (astemes_lib_lunit_cli) registers the
# "LUnit" LabVIEWCLI operation, which discovers Test Case classes under -Path and
# writes a JUnit report when -ReportPath ends in .xml. The default command is
# token-for-token the Windows one, so a `command:` override works on both.
LUNIT_DEFAULT_CMD='"{cli}" -LogToConsole TRUE -OperationName LUnit -Path "{dir}" -ReportPath "{out}" -LabVIEWPath "{lv}" -Headless'

# Contract: run_<id> <tool-id> <index> <command-override> <root>...
run_lunit() {
  local id="$1" index="$2" override="$3"
  shift 3
  local tmpl="${override:-$LUNIT_DEFAULT_CMD}"
  if [ -n "$override" ] && [[ ! "$override" =~ -Headless[[:space:]]*$ ]]; then
    echo "  WARNING: [$id] the command: override does not end with -Headless. On Linux, LabVIEWCLI swallows any argument after -Headless; keep it last." >&2
  fi
  if [ -z "$LABVIEWCLI" ] || [ -z "$LABVIEW_EXE" ]; then
    echo "  WARNING: [$id] LabVIEWCLI or labviewprofull not found; cannot run LUnit." >&2
    has_tooling_issue "$id" || add_tooling_issue "$id" "LUnit" "missing-tooling" \
      "LabVIEWCLI or the LabVIEW executable was not found in this container."
    return 0
  fi
  local i=0 dir out cmd
  for dir in "$@"; do
    out="$RESULTS_DIR/$id-$(( index * 100 + i )).xml"
    echo "  [$id] path: $dir"
    cmd="$(expand_tokens "$tmpl" "$dir" "$out")"
    run_cli_command "$id" "$cmd"
    if [ -f "$out" ]; then
      echo "  [$id] wrote $out"
    else
      echo "  WARNING: [$id] produced no JUnit at $out (check the LUnit output above; override with the tool's command: key)." >&2
      print_session_log "$id"
      if ! has_tooling_issue "$id"; then
        if printf '%s' "$CLI_OUTPUT" | grep -qiE '350053|missing or bad files|required modules or toolkits'; then
          add_tooling_issue "$id" "LUnit" "missing-tooling" \
            "The LUnit CLI toolkit (astemes_lib_lunit_cli) is not installed in this container, so the LabVIEW CLI LUnit operation could not load (error -350053)."
        elif printf '%s' "$CLI_OUTPUT" | grep -q '350006'; then
          add_tooling_issue "$id" "LUnit" "missing-tooling" \
            "The LabVIEW CLI LUnit operation was not found (error -350006). The LUnit CLI toolkit (astemes_lib_lunit_cli) is not installed in this container."
        else
          add_tooling_issue "$id" "LUnit" "error" "The LUnit operation produced no JUnit output."
        fi
      fi
    fi
    i=$(( i + 1 ))
  done
}

# --- Main ---------------------------------------------------------------------
is_linux_tool() {
  local t
  for t in "${LINUX_TOOLS[@]}"; do [ "$t" = "$1" ] && return 0; done
  return 1
}

TOOL_LINES=()
while IFS= read -r line; do
  [ -n "$line" ] && TOOL_LINES+=("$line")
done < <(read_unit_test_tools "$CONFIG_PATH")

if [ "${#TOOL_LINES[@]}" -eq 0 ]; then
  echo "WARNING: No config.unitTests.tools configured in $CONFIG_PATH - nothing to run." >&2
  echo "Wrote 0 JUnit file(s) to $RESULTS_DIR."
  exit 0
fi

tool_ids=()
for line in "${TOOL_LINES[@]}"; do tool_ids+=("${line%%$'\x1f'*}"); done
echo "Configured tools: ${tool_ids[*]}"
echo ""

idx=0
for line in "${TOOL_LINES[@]}"; do
  IFS=$'\x1f' read -r -a fields <<< "$line"
  tool="${fields[0]}"
  command_override="${fields[1]:-}"
  locations=("${fields[@]:2}")
  name="$(tool_display_name "$tool")"
  echo "--- tool: $tool ($name) ---"

  if ! is_linux_tool "$tool"; then
    echo "  $name ($tool) is not supported on Linux yet - skipping. It runs in the Windows unit-test workflow."
    add_tooling_issue "$tool" "$name" "unsupported-on-linux" \
      "$name does not run in the Linux container yet; its results come from the Windows unit-test run."
    idx=$(( idx + 1 )); echo ""
    continue
  fi

  roots=()
  if [ "${#locations[@]}" -gt 0 ]; then
    while IFS= read -r r; do [ -n "$r" ] && roots+=("$r"); done < <(resolve_test_roots "${locations[@]}")
  else
    # Empty locations means "the whole project".
    roots=("$WORKSPACE_ROOT")
  fi
  if [ "${#roots[@]}" -eq 0 ]; then
    echo "  WARNING: no test locations resolved for '$tool' (locations: ${locations[*]}) - skipping." >&2
    idx=$(( idx + 1 )); echo ""
    continue
  fi

  "run_${tool//-/_}" "$tool" "$idx" "$command_override" "${roots[@]}"
  idx=$(( idx + 1 )); echo ""
done

xml_count=0
for f in "$RESULTS_DIR"/*.xml; do [ -f "$f" ] && xml_count=$(( xml_count + 1 )); done
echo "=== Unit Tests finished: wrote $xml_count JUnit file(s) to $RESULTS_DIR ==="

# Persist findings for the report builder (same shape as the Windows runner).
if [ "${#TOOLING_ISSUES[@]}" -gt 0 ]; then
  {
    printf '{"missing": [\n'
    for n in "${!TOOLING_ISSUES[@]}"; do
      sep=","; [ "$n" -eq $(( ${#TOOLING_ISSUES[@]} - 1 )) ] && sep=""
      printf '  %s%s\n' "${TOOLING_ISSUES[$n]}" "$sep"
    done
    printf ']}\n'
  } > "$RESULTS_DIR/_tooling.json"
  echo "Recorded ${#TOOLING_ISSUES[@]} tooling finding(s) -> $RESULTS_DIR/_tooling.json"
fi

# Always exit 0: pass/fail is derived from the JUnit content by
# build-unittest-report.py, exactly like the Windows runner.
exit 0
