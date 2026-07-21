#!/usr/bin/env python3
"""
promote-build-artifacts.py - Package the staged build outputs into versioned,
release-ready archives with checksums, following common cross-language release
conventions (name-<version>-<os>-<arch>.zip + a .sha256 sidecar).

Reads the dist/ tree the build runner produced (dist/<project>/<spec>/<files>)
and writes one zip per build specification into an output directory, plus a
SHA-256 sidecar for each. The workflow then attaches these to the GitHub Release
for the tag.

Usage:
    python3 promote-build-artifacts.py \
        --dist ci-out/builds/dist \
        --out  ci-out/builds/release \
        --os   windows|linux \
        --tag  v1.2.0 \
        [--arch x64]
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
import zipfile
from pathlib import Path


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def clean_tag(tag: str) -> str:
    """A release version like 'v1.2.0' -> '1.2.0' for the asset name."""
    return re.sub(r"^v", "", (tag or "").strip())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dist", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--os", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--arch", default="x64")
    args = ap.parse_args()

    dist = Path(args.dist)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    version = clean_tag(args.tag)

    if not dist.is_dir():
        print("No dist directory at %s; nothing to promote." % dist)
        return 0

    made = 0
    # dist/<project>/<spec>/...  -> one archive per <spec> directory.
    for proj_dir in sorted(p for p in dist.iterdir() if p.is_dir()):
        for spec_dir in sorted(p for p in proj_dir.iterdir() if p.is_dir()):
            files = [f for f in spec_dir.rglob("*") if f.is_file()]
            if not files:
                continue
            asset = "%s-%s-%s-%s.zip" % (spec_dir.name, version, args.os, args.arch)
            asset_path = out / asset
            with zipfile.ZipFile(asset_path, "w", zipfile.ZIP_DEFLATED) as zf:
                for f in files:
                    zf.write(f, f.relative_to(spec_dir).as_posix())
            digest = sha256(asset_path)
            (out / (asset + ".sha256")).write_text(
                "%s  %s\n" % (digest, asset), encoding="utf-8"
            )
            print("Packaged %s (%s)" % (asset, digest[:12]))
            made += 1

    if made == 0:
        print("No build outputs found to promote.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
