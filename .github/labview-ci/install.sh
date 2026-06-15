#!/usr/bin/env bash
#
# install.sh - bootstrap the LabVIEW CI installer (curl | bash entry point).
#
# Fetches the tooling (unless run from a checkout) and hands off to install.py,
# which does the actual catalog-driven copy. This wrapper only locates Python,
# acquires the source, and forwards your flags.
#
# Usage (from the root of the repo you want to add CI to):
#
#   curl -fsSL https://raw.githubusercontent.com/elijah286/challenge-of-champions/main/.github/labview-ci/install.sh \
#     | bash -s -- --activities masscompile,vi-analyzer,vidiff,dashboard \
#                  --os windows,linux --labview-version 2026
#
# All flags after `--` are passed through to install.py (run with --help to see
# them). Bootstrap-only flags handled here:
#   --source-repo OWNER/NAME   tooling repo to fetch from (default below)
#   --source-ref  REF          branch/tag/sha of the tooling repo (default main)
#   --source      DIR          use a local tooling checkout instead of fetching
#
set -euo pipefail

SOURCE_REPO="elijah286/challenge-of-champions"
SOURCE_REF="main"
SRC_DIR=""
PASS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --source-repo) SOURCE_REPO="$2"; shift 2 ;;
    --source-ref)  SOURCE_REF="$2";  shift 2 ;;
    --source)      SRC_DIR="$2";     shift 2 ;;
    *)             PASS+=("$1");     shift ;;
  esac
done

PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
  echo "ERROR: Python 3 is required but was not found on PATH." >&2
  exit 1
fi

TARGET="$PWD"

if [ -z "$SRC_DIR" ]; then
  if [ -f ".github/labview-ci/install.py" ]; then
    # Running from a checkout that already contains the tooling.
    SRC_DIR="$PWD"
  else
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    # Bare ref form so --source-ref accepts a branch, a release tag (e.g. v1.2.0),
    # or a commit SHA; codeload resolves all three.
    URL="https://codeload.github.com/${SOURCE_REPO}/tar.gz/${SOURCE_REF}"
    echo "Fetching LabVIEW CI tooling from ${SOURCE_REPO}@${SOURCE_REF} ..."
    if ! curl -fsSL "$URL" | tar -xz -C "$TMP"; then
      echo "ERROR: failed to download tooling from $URL" >&2
      exit 1
    fi
    SRC_DIR="$TMP/$(ls "$TMP" | head -1)"
  fi
fi

if [ ! -f "$SRC_DIR/.github/labview-ci/install.py" ]; then
  echo "ERROR: tooling not found under $SRC_DIR (.github/labview-ci/install.py missing)." >&2
  exit 1
fi

exec "$PY" "$SRC_DIR/.github/labview-ci/install.py" \
  --source "$SRC_DIR" --target "$TARGET" "${PASS[@]}"
