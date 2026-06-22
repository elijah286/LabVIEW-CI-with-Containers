#!/usr/bin/env bash
set -euo pipefail

# Make a container CI job wait for the worker image build instead of failing on a
# missing or stale image.
#
# Two cases are handled:
#   (1) Stale inputs - this push changed something the worker image bakes in (a
#       project .vipc, the tooling Dockerfile, or the VIPM assets). The existing
#       image is out of date, so wait for the rebuild triggered for this commit.
#   (2) Image being built - a "Build LabVIEW CI Image" run is in progress or queued
#       (e.g. the configurator dispatches one the moment a fresh install merges, or
#       a dependency push kicked one off). The worker image
#       (ghcr.io/<owner>/<repo>-labview) does not exist until that build finishes,
#       so the very first CI run must wait for it rather than fail on
#       "manifest unknown" / "Failed to start container".
#
# When neither applies (the steady state: image already built, nothing rebuilding)
# the script exits 0 immediately, so normal runs are not slowed down.

repo="${GITHUB_REPOSITORY:-}"
sha="${1:-${GITHUB_SHA:-}}"
before="${2:-${GITHUB_EVENT_BEFORE:-}}"
workflow_name="${3:-Build LabVIEW CI Image}"
appear_seconds="${4:-300}"     # if a build was expected but none shows up by now, stop with guidance
overall_seconds="${5:-2400}"   # a cold first build (NI base pull + VIPC apply) can run long

if [ -z "$repo" ] || [ -z "$sha" ]; then
  echo "No repository or target SHA; not waiting for worker image."
  exit 0
fi

# Most-recent "Build LabVIEW CI Image" run in a given API listing, as
# "<status> <conclusion>" (empty when there is no such run). Errors (e.g. a missing
# Actions:read scope) degrade to "" so a permission gap can never wedge CI here.
latest_run() {
  gh api "$1" \
    --jq "([.workflow_runs[]|select(.name==\"$workflow_name\")]|sort_by(.created_at)|last) as \$r
          | if \$r then \"\(\$r.status) \(\$r.conclusion)\" else \"\" end" \
    2>/dev/null || echo ""
}

api_sha="repos/${repo}/actions/runs?head_sha=${sha}&per_page=50"
api_repo="repos/${repo}/actions/runs?per_page=50"

# (1) Did this push change anything the worker image bakes in?
changed=false
if [ -n "${before:-}" ] && git cat-file -e "${before}^{commit}" 2>/dev/null; then
  if git diff --name-only "$before" "$sha" \
      | grep -Eq '(\.vipc$|^\.github/docker/labview-ci\.Dockerfile$|^\.github/labview/vipm/)'; then
    changed=true
  fi
fi

# (2) Is a worker-image build currently in progress or queued (repo-wide)?
building=false
repo_latest="$(latest_run "$api_repo")"
repo_status="${repo_latest%% *}"
case "$repo_status" in
  in_progress|queued|requested|waiting|pending) building=true ;;
esac

if [ "$changed" != "true" ] && [ "$building" != "true" ]; then
  echo "Worker image build not pending (no worker-input change, none in progress); proceeding."
  exit 0
fi

if [ "$changed" = "true" ]; then
  echo "Worker inputs changed in this push - waiting for '$workflow_name' for $sha."
  api="$api_sha"
else
  echo "A '$workflow_name' build is in progress - waiting so CI runs on the freshly built worker image."
  api="$api_repo"
fi

appear_deadline=$(( $(date +%s) + appear_seconds ))
overall_deadline=$(( $(date +%s) + overall_seconds ))
seen=false

while :; do
  now=$(date +%s)
  run="$(latest_run "$api")"
  status="${run%% *}"
  conclusion="${run##* }"
  if [ -n "$run" ]; then seen=true; fi

  if [ "$seen" = "true" ] && [ "$status" = "completed" ]; then
    if [ "$conclusion" = "success" ] || [ "$conclusion" = "skipped" ]; then
      echo "Worker image build complete."
      break
    fi
    echo "The worker image build did not succeed. Fix the 'Build LabVIEW CI Image' run (or rebuild the image from the dashboard: Configure Workers), then re-run this job."
    exit 1
  fi

  if [ "$seen" != "true" ] && [ "$now" -ge "$appear_deadline" ]; then
    echo "No '$workflow_name' run found. Build the worker image once - run 'Build LabVIEW CI Image' (Actions) or use Configure Workers on the dashboard - then re-run this job."
    exit 1
  fi

  if [ "$now" -ge "$overall_deadline" ]; then
    echo "Timed out waiting for the worker image build. It may still be building; re-run this job once 'Build LabVIEW CI Image' completes."
    exit 1
  fi

  echo "  ... still waiting for the worker image (status=${status:-none})"
  sleep 20
done
