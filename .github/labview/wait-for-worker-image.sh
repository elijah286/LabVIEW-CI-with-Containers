#!/usr/bin/env bash
set -euo pipefail

# Make a container CI job wait for the worker image build instead of failing on a
# missing or stale image.
#
# Three cases are handled:
#   (1) Stale inputs - this push changed something the worker image bakes in (a
#       project .vipc, the tooling Dockerfile, or the VIPM assets). The existing
#       image is out of date, so wait for the rebuild triggered for this commit.
#   (2) Image being built - a "Build LabVIEW CI Image" run is in progress or queued
#       (e.g. the configurator dispatches one the moment a fresh install merges, or
#       a dependency push kicked one off). The worker image
#       (ghcr.io/<owner>/<repo>-labview) does not exist until that build finishes,
#       so the very first CI run must wait for it rather than fail on
#       "manifest unknown" / "Failed to start container".
#   (3) Image never built - the worker package does not exist in GHCR at all and
#       no build is pending. This is every FORK of a configured repo (GitHub
#       copies the workflows but never the GHCR packages, and no configurator
#       install runs to dispatch the first build), and any install whose first
#       build never ran. The script starts the build itself via workflow_dispatch
#       (needs `actions: write` on the calling workflow) and waits for it; when it
#       cannot dispatch, it fails with instructions instead of letting the pull
#       die on an opaque "manifest unknown".
#
# When none apply (the steady state: image already built, nothing rebuilding) the
# script exits 0 after one cheap GHCR existence probe, so normal runs are not
# slowed down.

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

# Probe GHCR for the worker package WITHOUT docker: several callers run this gate
# before docker login (all the Linux workflows), so the registry is queried over
# plain HTTP with GH_TOKEN via the standard token exchange. One tags/list call
# answers both questions: 404 means the package has never been published (case 3);
# 200 lists the published tags so a pinned-but-unpublished tag is caught too.
# Sets PROBE_RESULT to exists | tag-missing | package-missing | inconclusive.
# Any auth/network/registry hiccup is "inconclusive" and the caller falls back to
# the old behavior - this probe must never be able to wedge a healthy repo's CI.
PROBE_RESULT="inconclusive"
probe_worker_package() {
  PROBE_RESULT="inconclusive"
  local image="$1" path tag token body_file http_code
  path="${image#ghcr.io/}"
  tag="latest"
  case "$path" in *:*) tag="${path##*:}"; path="${path%%:*}" ;; esac
  command -v curl >/dev/null 2>&1 || return 0
  token=$(curl -fsS --max-time 20 -u "x:${GH_TOKEN}" \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:${path}:pull" 2>/dev/null \
    | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') || token=""
  [ -n "$token" ] || return 0
  body_file=$(mktemp)
  http_code=$(curl -sS --max-time 20 -o "$body_file" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    "https://ghcr.io/v2/${path}/tags/list?n=1000" 2>/dev/null) || http_code=""
  if [ "$http_code" = "404" ]; then
    PROBE_RESULT="package-missing"
  elif [ "$http_code" = "200" ]; then
    # Tags arrive as a JSON array of quoted names; a quote-delimited match is
    # exact ("2026" cannot match "2026q3"). The only other quoted string is the
    # package path, which always contains a slash and so cannot equal a tag.
    if grep -q "\"${tag}\"" "$body_file"; then
      PROBE_RESULT="exists"
    else
      PROBE_RESULT="tag-missing"
    fi
  fi
  rm -f "$body_file"
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

# (3) Steady state - but only when the worker image actually EXISTS. Probe GHCR
# before proceeding so a fresh fork's first run starts the build instead of dying
# later on "docker pull: manifest unknown".
first_run=false
if [ "$changed" != "true" ] && [ "$building" != "true" ]; then
  owner_lc=$(printf '%s' "${repo%%/*}" | tr '[:upper:]' '[:lower:]')
  probe_image="${LABVIEW_CONTAINER_IMAGE:-}"
  case "$probe_image" in
    "ghcr.io/${owner_lc}/"*)
      : ;;  # this repo's own worker image - the build workflow can produce it
    "")
      # An older workflow revision that resolves the image after this gate; assume
      # the default worker image name so a fresh fork is still caught.
      probe_image="ghcr.io/${owner_lc}/$(printf '%s' "${repo##*/}" | tr '[:upper:]' '[:lower:]')-labview:latest"
      ;;
    *)
      probe_image=""  # the NI base image or a foreign registry: not ours to build
      ;;
  esac
  PROBE_RESULT="inconclusive"
  if [ -n "$probe_image" ] && [ -n "${GH_TOKEN:-}" ]; then
    probe_worker_package "$probe_image"
  fi
  case "$PROBE_RESULT" in
    package-missing)
      echo "The worker image ${probe_image%:*} has never been built for ${repo} (a fresh fork, or an install whose first build never ran)."
      first_run=true
      ;;
    tag-missing)
      probe_tag="${probe_image##*:}"
      case "$probe_tag" in
        latest|linux-latest)
          # The default tag family this activity needs was simply never built -
          # e.g. a fork whose first build ran only for the other OS (Windows and
          # Linux share one package, split by tag family). Treat it like a first
          # run: dispatch the right build and wait.
          echo "The worker image ${probe_image%:*} exists but has no '${probe_tag}' tag for ${repo}; the '$workflow_name' build has never run."
          first_run=true
          ;;
        *)
          echo "::error::The configured worker image tag '${probe_tag}' is not published for ${probe_image%:*} (the package exists, but not this tag). Pick a published container in Configure Workers (.github/labview-ci.yml) or rebuild the worker image, then re-run this job."
          exit 1
          ;;
      esac
      ;;
    *)
      echo "Worker image build not pending (no worker-input change, none in progress); proceeding."
      exit 0
      ;;
  esac
fi

# First run: start the worker image build ourselves so the fork's first activity
# simply works, then fall through into the normal wait below.
if [ "$first_run" = "true" ]; then
  if [ -z "$workflow_path" ]; then
    echo "::error::The worker image has never been built. Build it once - run '$workflow_name' (Actions) or use Configure Workers on the dashboard - then re-run this job."
    exit 1
  fi
  default_branch=$(gh api "repos/${repo}" --jq .default_branch 2>/dev/null) || default_branch=""
  [ -n "$default_branch" ] || default_branch="main"
  dispatched=false
  dispatch_err=""
  for _ in 1 2 3; do
    # Concurrent first runs (a dashboard backfill dispatches several activities at
    # once) race to this point: if a sibling already started the build, join its
    # wait instead of dispatching a duplicate. build-labview-image.yml's
    # concurrency group (cancel-in-progress: false) collapses any duplicates that
    # slip through this check.
    latest_run "$api_repo"
    case "${LR_OUT%% *}" in
      in_progress|queued|requested|waiting|pending) dispatched=true; break ;;
    esac
    if dispatch_err=$(gh api -X POST \
        "repos/${repo}/actions/workflows/${workflow_path##*/}/dispatches" \
        -f "ref=${default_branch}" 2>&1); then
      echo "::notice::Started '$workflow_name' on ${default_branch} automatically. A first worker image build takes 80-100 minutes; this job waits for it and then continues."
      dispatched=true
      break
    fi
    # A just-created fork can take a while to index workflow_dispatch workflows
    # (the dispatch 404s until then); a short retry covers the transient cases.
    sleep 5
  done
  if [ "$dispatched" != "true" ]; then
    echo "::error::The worker image has never been built, and starting '$workflow_name' automatically failed (${dispatch_err:-workflow dispatch failed}; the calling workflow may lack 'actions: write'). Build it once - run '$workflow_name' (Actions) or use Configure Workers on the dashboard - then re-run this job."
    exit 1
  fi
  building=true
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

if [ "$first_run" = "true" ]; then
  # A previously FAILED or cancelled build may still be the newest completed run
  # in the listing; give the just-dispatched run a moment to appear so the wait
  # below tracks it rather than instantly failing on the stale conclusion.
  guard_deadline=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$guard_deadline" ]; do
    latest_run "$api"
    case "${LR_OUT%% *}" in
      in_progress|queued|requested|waiting|pending) break ;;
    esac
    sleep 5
  done
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
    echo "::error::The worker image build did not succeed. Fix the '$workflow_name' run (or rebuild the image from the dashboard: Configure Workers), then re-run this job."
    exit 1
  fi

  if [ "$seen" != "true" ] && [ "$now" -ge "$appear_deadline" ]; then
    echo "::error::No '$workflow_name' run found. Build the worker image once - run '$workflow_name' (Actions) or use Configure Workers on the dashboard - then re-run this job."
    exit 1
  fi

  if [ "$now" -ge "$overall_deadline" ]; then
    echo "::error::Timed out waiting for the worker image build. It may still be building; re-run this job once '$workflow_name' completes."
    exit 1
  fi

  echo "  ... still waiting for the worker image (status=${status:-none})"
  sleep 20
done
