#!/usr/bin/env bash
set -euo pipefail

repo="${GITHUB_REPOSITORY:-}"
sha="${1:-${GITHUB_SHA:-}}"
before="${2:-${GITHUB_EVENT_BEFORE:-}}"
workflow_name="${3:-Build LabVIEW CI Image}"
appear_seconds="${4:-300}"
overall_seconds="${5:-1800}"

if [ -z "$repo" ] || [ -z "$sha" ]; then
  echo "No repository or target SHA; not waiting for worker image."
  exit 0
fi

changed=false
if [ -n "${before:-}" ] && git cat-file -e "${before}^{commit}" 2>/dev/null; then
  if git diff --name-only "$before" "$sha" \
      | grep -Eq '(\.vipc$|^\.github/docker/labview-ci\.Dockerfile$|^\.github/labview/vipm/)'; then
    changed=true
  fi
fi

if [ "$changed" != "true" ]; then
  echo "No worker-affecting change in this push; not waiting."
  exit 0
fi

echo "Worker inputs changed - waiting for '$workflow_name' to finish for $sha."
appear_deadline=$(( $(date +%s) + appear_seconds ))
overall_deadline=$(( $(date +%s) + overall_seconds ))
seen=false
api="repos/${repo}/actions/runs?head_sha=${sha}&per_page=50"

while :; do
  total=$(gh api "$api" --jq "[.workflow_runs[]|select(.name==\"$workflow_name\")]|length" 2>/dev/null || echo 0)
  pending=$(gh api "$api" --jq "[.workflow_runs[]|select(.name==\"$workflow_name\")|select(.status!=\"completed\")]|length" 2>/dev/null || echo 0)
  failed=$(gh api "$api" --jq "[.workflow_runs[]|select(.name==\"$workflow_name\")|select(.status==\"completed\")|select(.conclusion!=\"success\" and .conclusion!=\"skipped\")]|length" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ "${total:-0}" -gt 0 ]; then seen=true; fi
  if [ "$seen" = "true" ] && [ "${pending:-0}" -eq 0 ]; then
    if [ "${failed:-0}" -gt 0 ]; then
      echo "Worker image build completed but did not succeed; stopping so CI does not run on stale dependencies."
      exit 1
    fi
    echo "Worker image build complete."
    break
  fi
  if [ "$seen" != "true" ] && [ "$now" -ge "$appear_deadline" ]; then
    echo "Worker image build did not appear in time; stopping so CI does not run on stale dependencies."
    exit 1
  fi
  if [ "$now" -ge "$overall_deadline" ]; then
    echo "Timed out waiting for worker image build; stopping so CI does not run on stale dependencies."
    exit 1
  fi
  echo "  ... still waiting (total=$total pending=$pending)"
  sleep 20
done