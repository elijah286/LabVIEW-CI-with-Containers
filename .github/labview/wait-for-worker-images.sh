#!/usr/bin/env bash
set -euo pipefail

sha=""
before=""
repo="${GITHUB_REPOSITORY:-}"
# Workflows to wait for. Left empty here and defaulted AFTER arg parsing so that an
# explicit --workflow REPLACES the default rather than appending to it. The default
# is the WINDOWS worker build only: every activity that uses this gate is a
# Windows-container activity, so it must not block on the Linux worker build (which
# may not run for a given revision). A Linux activity should pass
# --workflow "Build LabVIEW CI Image - Linux".
workflows=()
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

# One more case must not fall through the no-change fast path: a repo whose worker
# image has NEVER been built. That is every fork of a configured repo (GitHub
# copies the workflows but never the GHCR packages, and no configurator install
# runs to dispatch the first build). Before exiting 0, probe GHCR for the worker
# package (ghcr.io/<owner>/<repo>-labview - Windows and Linux builds share it,
# split by tag family) and, when it has never been published, dispatch the build
# and wait for it instead of letting the container step die on "manifest unknown".
# The probe uses plain HTTP with GH_TOKEN (docker is not logged in - or even
# present - where this gate runs); any auth/network hiccup keeps the old behavior
# so this can never wedge a healthy repo's CI.
worker_package_missing() {
  local path="$1" token body_file http_code missing=1
  command -v curl >/dev/null 2>&1 || return 1
  token=$(curl -fsS --max-time 20 -u "x:${GH_TOKEN}" \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:${path}:pull" 2>/dev/null \
    | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') || token=""
  [ -n "$token" ] || return 1
  body_file=$(mktemp)
  http_code=$(curl -sS --max-time 20 -o "$body_file" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    "https://ghcr.io/v2/${path}/tags/list?n=1000" 2>/dev/null) || http_code=""
  rm -f "$body_file"
  [ "$http_code" = "404" ] && missing=0
  return "$missing"
}

workflow_file_for() {
  case "$1" in
    "Build LabVIEW CI Image") echo "build-labview-image.yml" ;;
    "Build LabVIEW CI Image - Linux") echo "build-labview-linux-image.yml" ;;
    *) echo "" ;;
  esac
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
if [ "${#workflows[@]}" -eq 0 ]; then workflows=("Build LabVIEW CI Image"); fi
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

latest_status() {  # $1 = workflow name -> prints its newest run's status, or nothing
  gh api "repos/${repo}/actions/runs?per_page=100" \
    --jq "[.workflow_runs[]|select(.name==\"$1\")]|sort_by(.created_at)|last // {} | .status // empty" \
    2>/dev/null || true
}

first_run=false
if [ "$changed" != "true" ]; then
  # No worker-input change - the fast path - unless the worker image has never
  # been built at all (fork / first install). Only the gate's default call shape
  # (a single known build workflow) can auto-dispatch; custom --workflow lists
  # keep the old behavior.
  owner_lc=$(printf '%s' "${repo%%/*}" | tr '[:upper:]' '[:lower:]')
  pkg_path="${owner_lc}/$(printf '%s' "${repo##*/}" | tr '[:upper:]' '[:lower:]')-labview"
  wf_file=""
  if [ "${#workflows[@]}" -eq 1 ]; then
    wf_file=$(workflow_file_for "${workflows[0]}")
  fi
  if [ -n "$wf_file" ] && worker_package_missing "$pkg_path"; then
    echo "The worker image ghcr.io/${pkg_path} has never been built for ${repo} (a fresh fork, or an install whose first build never ran)."
    first_run=true
  else
    echo "No project .vipc change detected; not waiting for image builds."
    exit 0
  fi
fi

if [ "$first_run" = "true" ]; then
  wf="${workflows[0]}"
  default_branch=$(gh api "repos/${repo}" --jq .default_branch 2>/dev/null) || default_branch=""
  [ -n "$default_branch" ] || default_branch="main"
  dispatched=false
  dispatch_err=""
  for _ in 1 2 3; do
    # Concurrent gates race to this point; join a build a sibling already started
    # instead of dispatching a duplicate (the build workflow's concurrency group
    # collapses any that slip through).
    case "$(latest_status "$wf")" in
      in_progress|queued|requested|waiting|pending) dispatched=true; break ;;
    esac
    if dispatch_err=$(gh api -X POST \
        "repos/${repo}/actions/workflows/${wf_file}/dispatches" \
        -f "ref=${default_branch}" 2>&1); then
      echo "::notice::Started '$wf' on ${default_branch} automatically. A first worker image build takes 80-100 minutes; this gate waits for it and then continues."
      dispatched=true
      break
    fi
    sleep 5
  done
  if [ "$dispatched" != "true" ]; then
    echo "::error::The worker image has never been built, and starting '$wf' automatically failed (${dispatch_err:-workflow dispatch failed}; the calling workflow may lack 'actions: write'). Build it once - run '$wf' (Actions) or use Configure Workers on the dashboard - then re-run this workflow."
    exit 1
  fi
  # A previously FAILED or cancelled build may still be the newest completed run;
  # give the just-dispatched run a moment to appear so the wait below tracks it
  # rather than reading the stale conclusion.
  guard_deadline=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$guard_deadline" ]; do
    case "$(latest_status "$wf")" in
      in_progress|queued|requested|waiting|pending) break ;;
    esac
    sleep 5
  done
  # The dispatched run is on the default-branch tip, not this job's SHA, and a
  # cold first build outlasts the default overall timeout.
  api="repos/${repo}/actions/runs?per_page=100"
  if [ "$overall_timeout" -lt 6600 ]; then overall_timeout=6600; fi
else
  echo "Worker inputs changed; waiting for worker image builds for $sha."
  api="repos/${repo}/actions/runs?head_sha=${sha}&per_page=100"
fi

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
    elif [ "$conclusion" = "success" ] || [ "$conclusion" = "skipped" ]; then
      : # build is current for this revision - good to proceed
    elif [ "$conclusion" = "cancelled" ]; then
      # A cancelled build was superseded or manually stopped - it does NOT mean the
      # published image is bad (a later build/bake may have produced it). Don't hard
      # fail an activity (e.g. a re-run on an older commit) over a cancelled build;
      # warn and proceed. Re-run the worker build if you suspect the image is stale.
      echo "::warning::Worker image build for '$wf' at $sha was cancelled; proceeding without blocking. Re-run the worker build if the image may be stale."
    else
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
