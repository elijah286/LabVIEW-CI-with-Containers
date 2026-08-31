#!/usr/bin/env python3
"""Restore the last successful GitLab Pages artifact, when the job token permits it."""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from io import BytesIO
from pathlib import Path


def log(message: str) -> None:
    print(f"[lvci] {message}", flush=True)


def safe_extract(archive: zipfile.ZipFile, destination: Path) -> None:
    root = destination.resolve()
    for member in archive.infolist():
        candidate = (destination / member.filename).resolve()
        if candidate != root and root not in candidate.parents:
            raise ValueError(f"artifact contains unsafe path: {member.filename}")
    archive.extractall(destination)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    api = os.environ.get("CI_API_V4_URL", "").rstrip("/")
    project = os.environ.get("CI_PROJECT_ID", "")
    branch = os.environ.get("CI_DEFAULT_BRANCH", "")
    token = os.environ.get("CI_JOB_TOKEN", "")
    destination = Path(args.out)

    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True, exist_ok=True)
    if not all((api, project, branch, token)):
        log("no prior Pages artifact lookup context; starting a fresh site")
        return 0

    ref = urllib.parse.quote(branch, safe="")
    url = f"{api}/projects/{urllib.parse.quote(project, safe='')}/jobs/artifacts/{ref}/download?job=pages"
    request = urllib.request.Request(url, headers={"JOB-TOKEN": token})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read()
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403, 404):
            log("no readable prior Pages artifact; starting a fresh site")
            return 0
        log(f"could not restore prior Pages artifact (HTTP {exc.code}); starting fresh")
        return 0
    except OSError as exc:
        log(f"could not restore prior Pages artifact ({exc}); starting fresh")
        return 0

    try:
        with zipfile.ZipFile(BytesIO(payload)) as archive:
            safe_extract(archive, destination)
    except (ValueError, zipfile.BadZipFile) as exc:
        log(f"prior Pages artifact was unusable ({exc}); starting fresh")
        shutil.rmtree(destination)
        destination.mkdir(parents=True, exist_ok=True)
        return 0

    log("restored the prior GitLab Pages artifact")
    return 0


if __name__ == "__main__":
    sys.exit(main())