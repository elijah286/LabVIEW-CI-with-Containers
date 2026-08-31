#!/usr/bin/env python3
"""Copy one capability's report into the artifact tree collected by GitLab Pages."""

from __future__ import annotations

import argparse
import html
import shutil
from pathlib import Path


def copy_tree(source: Path, destination: Path) -> None:
    if source.is_dir():
        shutil.copytree(source, destination, dirs_exist_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--reports", default="ci-out/gitlab-pages")
    parser.add_argument("--destination", required=True)
    parser.add_argument("--fallback", default="The job did not produce a report. See the GitLab job log.")
    args = parser.parse_args()

    source = Path(args.source)
    destination = Path(args.reports) / args.destination.strip("/")
    destination.mkdir(parents=True, exist_ok=True)
    copy_tree(source, destination)
    index = destination / "index.html"
    if not index.is_file():
        index.write_text(
            "<!doctype html><meta charset=\"utf-8\"><title>LabVIEW CI report</title>"
            f"<pre>{html.escape(args.fallback)}</pre>\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()