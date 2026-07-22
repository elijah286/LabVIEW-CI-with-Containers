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
# A cold first worker-image build (pull the multi-GB NI base + bake the project
# VIPC) reliably runs 80-100 minutes, so the wait must outlast it or every fresh
# install's first dispatched activity times out while the build is still going.
overall_seconds="${5:-6600}"   # 110 min - comfortably longer than a cold build
workflow_path=""

case "$workflow_name" in
  "Build LabVIEW CI Image") workflow_path=".github/workflows/build-labview-image.yml" ;;
  "Build LabVIEW CI Image - Linux") workflow_path=".github/workflows/build-labview-linux-image.yml" ;;
esac

if [ -z "$repo" ] || [ -z "$sha" ]; then
  echo "No repository or target SHA; not waiting for worker image."
  exit 0
fi

# Look up the most-recent "Build LabVIEW CI Image" run in a given API listing and
# stash the result in two globals -- done WITHOUT a command-substitution subshell
# so the success flag survives into the caller: LR_OUT is "<status> <conclusion>"
# (empty when there is no such run) and LR_OK is true only when the API call itself
# succeeded. That lets the caller tell "no build run" apart from "couldn't reach
# the Actions API" (a transient blip, a rate limit, or a missing actions:read
# scope); a permission gap can never wedge CI here.
LR_OUT=""
LR_OK=false
latest_run() {
  if LR_OUT="$(gh api "$1" \
      --jq "([.workflow_runs[]|select($run_match)]|sort_by(.created_at)|last) as \$r
            | if \$r then \"\(\$r.status) \(\$r.conclusion)\" else \"\" end" 2>/dev/null)"; then
    LR_OK=true
  else
    LR_OK=false
    LR_OUT=""
  fi
}

api_sha="repos/${repo}/actions/runs?head_sha=${sha}&per_page=50"
api_repo="repos/${repo}/actions/runs?per_page=50"
if [ -n "$workflow_path" ]; then
  run_match=".name==\"$workflow_name\" or .path==\"$workflow_path\""
else
  run_match=".name==\"$workflow_name\""
fi

# (1) Did this push change anything the worker image bakes in?
changed=false
if [ -n "${before:-}" ] && git cat-file -e "${before}^{commit}" 2>/dev/null; then
  if git diff --name-only "$before" "$sha" \
      | grep -Eq '(\.vipc$|^\.github/docker/labview-ci(-base)?\.Dockerfile$|^\.github/docker/labview-ci-linux\.Dockerfile$|^\.github/labview/build-worker-manifest\.py$|^\.github/labview/wait-for-worker-image\.sh$|^\.github/labview/vipm/|^\.github/workflows/build-labview-image\.yml$|^\.github/workflows/build-labview-linux-image\.yml$)'; then
    changed=true
  fi
fi

# (2) Is a worker-image build currently in progress or queued (repo-wide)?
# Retry on a FAILED API call (api_ok=false) so a transient Actions-API hiccup
# can't make a job skip the wait and start on a stale or half-built image. A
# genuine permission gap keeps api_ok=false through all attempts and then falls
# through (building=false), so CI is never wedged here.
building=false
for _ in 1 2 3; do
  latest_run "$api_repo"
  [ "$LR_OK" = "true" ] && break
  sleep 2
done
repo_status="${LR_OUT%% *}"
case "$repo_status" in
  in_progress|queued|requested|waiting|pending) building=true ;;
esac

if [ "$changed" != "true" ] && [ "$building" != "true" ]; then
  echo "Worker image build not pending (no worker-input change, none in progress); proceeding."
  exit 0
fi

# Prefer the repo-wide listing whenever a build is actually in progress or queued.
# A fresh install (or a "Configure Workers" rebuild) dispatches the build via
# workflow_dispatch on the branch tip, which is almost always a DIFFERENT commit
# than the one this CI job runs on -- and tooling changes under .github/** never
# trigger a per-commit push build at all (build-labview-image.yml's push filter is
# `**.vipc` with `!.github/**`). Keying the wait to this job's exact SHA in those
# cases would never find the build and would time out after appear_seconds. Only
# fall back to the per-commit listing when nothing is building yet but this push
# changed a worker input -- a project *.vipc triggers a push build on THIS commit.
if [ "$building" = "true" ]; then
  echo "A '$workflow_name' build is in progress - waiting so CI runs on the freshly built worker image."
  api="$api_repo"
else
  echo "Worker inputs changed in this push - waiting for '$workflow_name' for $sha."
  api="$api_sha"
fi

appear_deadline=$(( $(date +%s) + appear_seconds ))
overall_deadline=$(( $(date +%s) + overall_seconds ))
seen=false

while :; do
  now=$(date +%s)
  latest_run "$api"
  run="$LR_OUT"
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
