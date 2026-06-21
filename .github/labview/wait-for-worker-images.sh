#!/usr/bin/env bash
set -euo pipefail

sha=""
before=""
repo="${GITHUB_REPOSITORY:-}"
workflows=("Build LabVIEW CI Image" "Build LabVIEW CI Image - Linux")
appear_timeout=300
overall_timeout=2400

# The worker image build (build-labview-image.yml / build-labview-linux-image.yml)
# triggers ONLY when a PROJECT .vipc changes - that is, a *.vipc that is NOT under
# .github/ (the tooling's own ci-tooling.vipc and other .github/ files are excluded
# from the build trigger). The gate must therefore wait under exactly those same
# conditions; otherwise it would block on a worker build that was never triggered
# (a VI-only change, a tooling-only change under .github/, or a bake-built image).
# Reads a newline-separated file list on stdin; exits 0 if a project .vipc changed.
is_worker_change() {
  grep -E '\.vipc$' | grep -qv '^\.github/'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sha) sha="${2:-}"; shift 2 ;;
    --before) before="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --workflow) workflows+=("${2:-}"); shift 2 ;;
    --appear-timeout) appear_timeout="${2:-}"; shift 2 ;;
    --overall-timeout) overall_timeout="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$sha" ]; then sha="${GITHUB_SHA:-}"; fi
if [ -z "$sha" ]; then echo "No target SHA supplied." >&2; exit 2; fi
if [ -z "$repo" ]; then echo "No GitHub repository supplied." >&2; exit 2; fi
if [ -z "${GH_TOKEN:-}" ]; then echo "GH_TOKEN is required to query workflow runs." >&2; exit 2; fi

changed=false
if [ -n "${before:-}" ] && [ "${before//0/}" != "" ] && git cat-file -e "${before}^{commit}" 2>/dev/null; then
  if git diff --name-only "$before" "$sha" | is_worker_change; then
    changed=true
  fi
else
  # Manual dispatches and unusual events do not always provide a comparable base.
  # In that case, look at the target commit itself and wait only if it touched a
  # project .vipc (the only thing that triggers a worker rebuild).
  if git diff-tree --no-commit-id --name-only -r "$sha" | is_worker_change; then
    changed=true
  fi
fi

if [ "$changed" != "true" ]; then
  echo "No project .vipc change detected; not waiting for image builds."
  exit 0
fi

echo "Worker inputs changed; waiting for worker image builds for $sha."
api="repos/${repo}/actions/runs?head_sha=${sha}&per_page=100"
appear_deadline=$(( $(date +%s) + appear_timeout ))
overall_deadline=$(( $(date +%s) + overall_timeout ))

while :; do
  now=$(date +%s)
  all_done=true
  any_missing=false

  for wf in "${workflows[@]}"; do
    data=$(gh api "$api" --jq "[.workflow_runs[]|select(.name==\"$wf\")]|sort_by(.created_at)|last // {}" 2>/dev/null || echo '{}')
    id=$(printf '%s' "$data" | jq -r '.id // empty')
    status=$(printf '%s' "$data" | jq -r '.status // empty')
    conclusion=$(printf '%s' "$data" | jq -r '.conclusion // empty')
    url=$(printf '%s' "$data" | jq -r '.html_url // empty')

    if [ -z "$id" ]; then
      any_missing=true
      all_done=false
      echo "  $wf: not visible yet"
      continue
    fi

    echo "  $wf: status=${status:-unknown} conclusion=${conclusion:-none} ${url}"
    if [ "$status" != "completed" ]; then
      all_done=false
    elif [ "$conclusion" != "success" ] && [ "$conclusion" != "skipped" ]; then
      echo "Worker image build failed: $wf concluded '$conclusion'." >&2
      exit 1
    fi
  done

  if [ "$all_done" = "true" ]; then
    echo "Worker image builds completed successfully."
    exit 0
  fi
  if [ "$any_missing" = "true" ] && [ "$now" -ge "$appear_deadline" ]; then
    echo "One or more worker image builds did not appear within ${appear_timeout}s." >&2
    exit 1
  fi
  if [ "$now" -ge "$overall_deadline" ]; then
    echo "Timed out after ${overall_timeout}s waiting for worker image builds." >&2
    exit 1
  fi

  sleep 20
done
