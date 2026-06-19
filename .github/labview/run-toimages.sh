#!/usr/bin/env bash
#
# run-toimages.sh - orchestrate position-aware <blob>.json rendering for the
# in-place VI Browser (2.0) across one or more commits.
#
# PUBLIC scaffolding: contains NO LabVIEW/NI code. The actual rendering is done by
# a separate PRIVATE image (see .github/workflows/vi-snapshots-json.yml). This
# script only decides WHICH VI blobs need a JSON and drives the image once per
# commit, mirroring the content-addressed backfill the 1.0 Windows pipeline
# (build-snapshots.ps1) already does.
#
# WHY PER-COMMIT WORKTREES: a VI must be on disk together with its dependencies
# (subVIs) at the right content to open and render. HEAD's checkout only has
# HEAD's content, so a VI that changed since HEAD (e.g. main.vi) would never be
# rendered from HEAD alone. For each commit we therefore create a detached git
# worktree and render that commit's not-yet-rendered .vi blobs from it. Output is
# content-addressed (by-blob/<ab>/<blob>.json), so each unique VI is rendered once
# ever and is reused across every commit and revision that contains it.
#
# INCREMENTAL PUBLISH: after each commit that produced JSON, the new files (plus a
# flat json-blobs.json index) are pushed to gh-pages best-effort, so the VI
# Browser's 2.0 glyphs light up progressively during a long backfill instead of
# only at the very end. The workflow's final deploy step remains authoritative, so
# a failed incremental push never loses data.
#
# Usage (all via env):
#   WS               repo worktree root (full history; checkout fetch-depth 0)
#   MODE             head | backfill                      (default: head)
#   TARGET_SHA       head mode: commit to render          (default: HEAD)
#   IMAGE            the private toimages image (required)
#   OUT              staging dir, e.g. .../ci-out/vi-snapshots   (required)
#   GHP              gh-pages checkout dir with push creds (optional; no live
#                    publish if empty/not a git repo)
#   WORKLIST_SH      path to build-json-worklist.sh        (default: alongside this)
#   MAX_COMMITS      backfill: cap to the most recent N VI-touching commits (0=all)
#   TIME_BUDGET_MIN  backfill: stop launching new renders after N minutes
#                    (default 110, under the workflow's 120-min timeout; resumable)
set -euo pipefail

WS=${WS:?WS (repo worktree root)}
MODE=${MODE:-head}
IMAGE=${IMAGE:?IMAGE (private toimages image)}
OUT=${OUT:?OUT (staging dir)}
GHP=${GHP:-}
TARGET_SHA=${TARGET_SHA:-}
MAX_COMMITS=${MAX_COMMITS:-0}
TIME_BUDGET_MIN=${TIME_BUDGET_MIN:-110}
WORKLIST_SH=${WORKLIST_SH:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-json-worklist.sh"}

BYBLOB="$OUT/by-blob"
mkdir -p "$BYBLOB"
WT_ROOT="${RUNNER_TEMP:-/tmp}/lvci-toimages-wt"
mkdir -p "$WT_ROOT"

# ── Seed staging with already-rendered JSON (only .json - the .html belong to the
#    1.0 pipeline) so done blobs are skipped instantly and dedup works across the
#    commits within this run. ──
if [ -n "$GHP" ] && [ -d "$GHP/vi-snapshots/by-blob" ]; then
  while IFS= read -r -d '' f; do
    rel=${f#"$GHP/vi-snapshots/by-blob/"}
    mkdir -p "$BYBLOB/$(dirname "$rel")"
    cp -n "$f" "$BYBLOB/$rel" 2>/dev/null || true
  done < <(find "$GHP/vi-snapshots/by-blob" -type f -name '*.json' -print0)
fi
seeded=$(find "$BYBLOB" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
echo "Seeded $seeded already-rendered blob(s)."

# ── Write a flat, sorted index of every rendered .json blob (mirrors 1.0 blobs.json). ──
write_index() {
  python3 - "$BYBLOB" "$1" <<'PY'
import os, sys
byblob, out = sys.argv[1], sys.argv[2]
blobs = sorted({fn[:-5] for _r, _d, fs in os.walk(byblob) for fn in fs if fn.endswith('.json')})
with open(out, 'w', encoding='utf-8') as fh:
    fh.write('[' + ','.join('"%s"' % b for b in blobs) + ']')
PY
}

# ── Best-effort incremental publish of new JSON + the index to gh-pages. ──
publish() {
  [ -n "$GHP" ] && [ -d "$GHP/.git" ] || return 0
  mkdir -p "$GHP/vi-snapshots/by-blob"
  cp -rn "$BYBLOB/." "$GHP/vi-snapshots/by-blob/" 2>/dev/null || true
  write_index "$GHP/vi-snapshots/json-blobs.json"
  git -C "$GHP" add vi-snapshots/by-blob vi-snapshots/json-blobs.json >/dev/null 2>&1 || true
  git -C "$GHP" diff --cached --quiet && return 0
  git -C "$GHP" -c user.email=actions@github.com -c user.name='lvci-toimages' \
      commit -q -m "vi-snapshots(2.0): incremental JSON render" || return 0
  local i
  for i in 1 2 3 4 5; do
    if git -C "$GHP" push -q origin HEAD:gh-pages 2>/dev/null; then return 0; fi
    git -C "$GHP" fetch -q origin gh-pages 2>/dev/null \
      && git -C "$GHP" rebase -q FETCH_HEAD 2>/dev/null \
      || git -C "$GHP" rebase --abort >/dev/null 2>&1 || true
  done
  echo "::warning::incremental gh-pages publish failed (the final deploy step will still publish everything)"
}

# ── Determine the commit list. ──
if [ "$MODE" = "backfill" ]; then
  COMMITS=()
  while IFS= read -r c; do [ -n "$c" ] && COMMITS+=("$c"); done \
    < <(git -C "$WS" -c core.quotePath=false log --reverse --format='%H' -- '*.vi')
  head_sha=$(git -C "$WS" rev-parse HEAD)
  in_list=0; for c in "${COMMITS[@]:-}"; do [ "$c" = "$head_sha" ] && in_list=1; done
  [ "$in_list" = "0" ] && COMMITS+=("$head_sha")
  if [ "$MAX_COMMITS" -gt 0 ] && [ "${#COMMITS[@]}" -gt "$MAX_COMMITS" ]; then
    COMMITS=( "${COMMITS[@]: -$MAX_COMMITS}" )
  fi
else
  [ -n "$TARGET_SHA" ] || TARGET_SHA=$(git -C "$WS" rev-parse HEAD)
  COMMITS=("$TARGET_SHA")
fi
echo "Mode=$MODE - processing ${#COMMITS[@]} commit(s)."

deadline=$(( $(date +%s) + TIME_BUDGET_MIN * 60 ))

for sha in "${COMMITS[@]}"; do
  short=${sha:0:7}
  wl="$OUT/worklist.tsv"
  # Enumerate this commit's not-yet-rendered .vi blobs (reuses the worklist builder;
  # it skips any blob that already has a .json under $BYBLOB).
  bash "$WORKLIST_SH" "$WS" "$sha" "$BYBLOB" "$wl"
  n=$(wc -l < "$wl" 2>/dev/null | tr -d ' '); n=${n:-0}
  if [ "$n" -eq 0 ]; then echo "[$short] nothing new to render."; continue; fi
  if [ "$(date +%s)" -gt "$deadline" ]; then
    echo "Time budget reached - stopping before $short. Re-run backfill to resume."
    break
  fi
  echo "[$short] rendering $n VI(s)..."

  # Detached worktree of this commit: the VI files + their dependencies on disk.
  wt="$WT_ROOT/$sha"
  git -C "$WS" worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -rf "$wt"
  if ! git -C "$WS" worktree add --detach "$wt" "$sha" >/dev/null 2>&1; then
    echo "::warning::worktree add failed for $short - skipping."
    continue
  fi

  docker run --rm \
    -v "$wt:/work:ro" \
    -v "$OUT:/out" \
    -e WORKSPACE=/work \
    -e WORKLIST=/out/worklist.tsv \
    -e OUT_BY_BLOB=/out/by-blob \
    "$IMAGE" || echo "::warning::toimages reported a non-zero exit for $short (any VIs it did render are kept)."

  git -C "$WS" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"

  rendered=$(find "$BYBLOB" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  echo "[$short] total rendered blobs now: $rendered."
  publish
done

# Final index for the authoritative deploy step, plus a last best-effort publish.
write_index "$OUT/json-blobs.json"
publish
total=$(find "$BYBLOB" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
echo "toimages orchestration done. Rendered blobs total: $total."
