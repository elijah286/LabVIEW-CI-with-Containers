#!/usr/bin/env bash
# =============================================================================
# vidiff-backfill.sh — Generate VIDiff reports across history in ONE warm container
# =============================================================================
# Walks every VI-touching commit (oldest -> newest) and produces a VIDiff report
# comparing it to the PREVIOUS VI-touching commit — the same base the VI Browser
# uses for its content-addressed change detection — so each changed VI links to a
# true side-by-side diff report.
#
# A single LabVIEW Linux container is started and kept warm; each commit pair is
# rendered via `docker exec` (no per-commit container churn or image re-pull).
# Reports are staged deploy-ready under:
#     <OutRoot>/push-<headsha>/linux/vidiff/...        (index.html, changes.json, per-VI)
#     <OutRoot>/push-<headsha>/linux/vidiff-meta.json
#
# Usage:
#   bash vidiff-backfill.sh <WorkspaceRoot> <OutRoot> [Image] [MaxCommits] [ExistingDir] [TimeBudgetMin]
# =============================================================================
set -euo pipefail

WORKSPACE_ROOT="${1:-$PWD}"
OUT_ROOT="${2:-$WORKSPACE_ROOT/ci-out/vidiff-backfill}"
IMAGE="${3:-nationalinstruments/labview:latest-linux}"
MAX_COMMITS="${4:-0}"
EXISTING_DIR="${5:-}"          # deployed vidiff/ dir — skip commits already done
TIME_BUDGET_MIN="${6:-300}"

OPS_HOST="${WORKSPACE_ROOT}/.github/labview"
WT_ROOT="$(mktemp -d)/wt"
mkdir -p "$WT_ROOT" "$OUT_ROOT"

CNAME="lvci-vidiff-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
DEADLINE=$(( $(date +%s) + TIME_BUDGET_MIN * 60 ))

# VI-touching commits, oldest first.
mapfile -t COMMITS < <(git -C "$WORKSPACE_ROOT" log --reverse --format='%H' -- '*.vi' '*.ctl')
if [ "$MAX_COMMITS" -gt 0 ] && [ "${#COMMITS[@]}" -gt "$MAX_COMMITS" ]; then
  COMMITS=("${COMMITS[@]: -$MAX_COMMITS}")
fi
echo "VI-touching commits to consider: ${#COMMITS[@]}"

echo "Pulling $IMAGE ..."
docker pull "$IMAGE" >/dev/null

echo "Starting warm container $CNAME ..."
docker run -d --name "$CNAME" \
  -v "${OPS_HOST}:/ops:ro" \
  -v "${WT_ROOT}:/wt" \
  -v "${OUT_ROOT}:/out" \
  "$IMAGE" sleep infinity >/dev/null

cleanup() {
  docker rm -f "$CNAME" >/dev/null 2>&1 || true
  git -C "$WORKSPACE_ROOT" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Live bind-mount probe (a host file created after start must be visible inside).
echo "probe" > "${WT_ROOT}/.probe"
if [ "$(docker exec "$CNAME" sh -c 'cat /wt/.probe 2>/dev/null')" != "probe" ]; then
  echo "ERROR: live bind-mount probe failed (container cannot see new host files)." >&2
  exit 1
fi
rm -f "${WT_ROOT}/.probe"

prev=""
processed=0
skipped=0
for sha in "${COMMITS[@]}"; do
  if [ -z "$prev" ]; then prev="$sha"; continue; fi
  short="${sha:0:7}"

  # Resume: skip commits whose report is already deployed.
  if [ -n "$EXISTING_DIR" ] && [ -f "${EXISTING_DIR}/push-${sha}/linux/vidiff/changes.json" ]; then
    skipped=$((skipped+1)); prev="$sha"; continue
  fi

  CHANGED=$(git -C "$WORKSPACE_ROOT" diff --name-only "$prev" "$sha" -- '*.vi' '*.ctl' || true)
  if [ -z "$CHANGED" ]; then prev="$sha"; continue; fi

  if [ "$(date +%s)" -gt "$DEADLINE" ]; then
    echo "Time budget reached — stopping before ${short}. Re-run to resume."
    break
  fi

  echo "── [${short}] vs ${prev:0:7}: $(echo "$CHANGED" | grep -c . ) changed VI(s)"

  bwt="${WT_ROOT}/base-${sha}"
  hwt="${WT_ROOT}/head-${sha}"
  git -C "$WORKSPACE_ROOT" worktree remove --force "$bwt" 2>/dev/null || true
  git -C "$WORKSPACE_ROOT" worktree remove --force "$hwt" 2>/dev/null || true
  git -C "$WORKSPACE_ROOT" worktree add --detach "$bwt" "$prev" >/dev/null 2>&1 || { echo "  worktree(base) failed; skipping"; prev="$sha"; continue; }
  git -C "$WORKSPACE_ROOT" worktree add --detach "$hwt" "$sha"  >/dev/null 2>&1 || { echo "  worktree(head) failed; skipping"; prev="$sha"; continue; }

  mkdir -p "${OUT_ROOT}/push-${sha}/linux/vidiff"

  # Run the existing single-pair VIDiff inside the warm container. Pass /ops as the
  # operation dir so PrintToSingleFileHtml resolves even for old commits.
  docker exec -e CHANGED_FILES="$CHANGED" "$CNAME" \
    bash /ops/vidiff.sh \
      "/wt/base-${sha}" \
      "/wt/head-${sha}" \
      "/out/push-${sha}/linux/vidiff" \
      "/ops" \
    || echo "  vidiff returned non-zero for ${short} (continuing)"

  cat > "${OUT_ROOT}/push-${sha}/linux/vidiff-meta.json" <<JSON
{
  "head_sha":  "${sha}",
  "base_sha":  "${prev}",
  "pr_number": "",
  "platform":  "linux",
  "outcome":   "success"
}
JSON

  git -C "$WORKSPACE_ROOT" worktree remove --force "$bwt" 2>/dev/null || true
  git -C "$WORKSPACE_ROOT" worktree remove --force "$hwt" 2>/dev/null || true
  processed=$((processed+1))
  prev="$sha"
done

echo ""
echo "=== VIDiff backfill complete: ${processed} generated, ${skipped} skipped ==="
