#!/usr/bin/env python3
"""Copy a directory's contents into one isolated GitLab Pages artifact root."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path


def copy_contents(source: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    if not source.is_dir():
        return
    for child in source.iterdir():
        target = destination / child.name
        if child.is_dir():
            shutil.copytree(child, target, dirs_exist_ok=True)
        else:
            shutil.copy2(child, target)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--destination", required=True)
    args = parser.parse_args()
    destination = Path(args.destination)
    if destination.is_absolute() or ".." in destination.parts:
        parser.error("--destination must be a relative path within the job workspace")
    copy_contents(Path(args.source), destination)


if __name__ == "__main__":
    main()