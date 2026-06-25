#!/usr/bin/env python3
"""Validate that the installer catalog matches the source-owned files."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / ".github" / "labview-ci" / "catalog.json"

REQUIRED_CUSTOM_IMAGE_WINDOWS = [
    ".github/workflows/build-labview-image.yml",
    ".github/workflows/copy-labview-image.yml",
    ".github/docker/labview-ci-base.Dockerfile",
    ".github/docker/labview-ci.Dockerfile",
    ".github/labview/vipm/",
]

OBSOLETE_WINDOWS_WORKER_FILES = {
    ".github/docker/labview-vipm-base.Dockerfile",
    ".github/docker/labview-vipc-layer.Dockerfile",
}


def err(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)


def path_exists(relpath: str) -> bool:
    return (ROOT / relpath).exists()


def main() -> int:
    failures: list[str] = []
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))

    releases = (catalog.get("history") or {}).get("releases") or []
    if not releases:
        failures.append("catalog history.releases is empty")
    elif catalog.get("version") != releases[0].get("version"):
        failures.append(
            "catalog version must equal history.releases[0].version "
            f"({catalog.get('version')!r} != {releases[0].get('version')!r})"
        )

    capabilities = catalog.get("capabilities") or []
    custom_image = next((cap for cap in capabilities if cap.get("id") == "custom-image"), None)
    if custom_image is None:
        failures.append("catalog is missing the custom-image capability")
    else:
        windows_files = custom_image.get("files", {}).get("windows") or []
        if windows_files != REQUIRED_CUSTOM_IMAGE_WINDOWS:
            failures.append(
                "custom-image windows files must exactly match the source-owned "
                f"Windows worker file set: {windows_files!r}"
            )
        obsolete = sorted(set(windows_files) & OBSOLETE_WINDOWS_WORKER_FILES)
        if obsolete:
            failures.append(f"custom-image still vendors obsolete worker files: {obsolete!r}")

    for capability in capabilities:
        capability_id = capability.get("id", "<unknown>")
        files = capability.get("files") or {}
        for os_name, relpaths in files.items():
            for relpath in relpaths or []:
                if not path_exists(relpath):
                    failures.append(
                        f"capability {capability_id!r} lists missing {os_name} file: {relpath}"
                    )

    workflow = ROOT / ".github" / "workflows" / "build-labview-image.yml"
    workflow_text = workflow.read_text(encoding="utf-8")
    docker_final = ROOT / ".github" / "docker" / "labview-ci.Dockerfile"
    docker_final_text = docker_final.read_text(encoding="utf-8")

    for relpath in REQUIRED_CUSTOM_IMAGE_WINDOWS:
        if not path_exists(relpath):
            failures.append(f"required custom-image source file is missing: {relpath}")

    for obsolete in OBSOLETE_WINDOWS_WORKER_FILES:
        if path_exists(obsolete):
            failures.append(f"obsolete Windows worker Dockerfile still exists: {obsolete}")
        if obsolete in workflow_text:
            failures.append(f"build-labview-image.yml still references obsolete file: {obsolete}")

    if ".github/docker/labview-ci-base.Dockerfile" not in workflow_text:
        failures.append("build-labview-image.yml does not reference labview-ci-base.Dockerfile")
    if "LCWC_BASE_IMAGE" not in workflow_text:
        failures.append("build-labview-image.yml does not define/use LCWC_BASE_IMAGE")
    if "FROM ${LCWC_BASE_IMAGE}" not in docker_final_text:
        failures.append("labview-ci.Dockerfile must start from LCWC_BASE_IMAGE")

    if failures:
        for failure in failures:
            err(failure)
        return 1

    print("Catalog/source sync validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())