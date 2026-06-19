#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path


def binary_name(base_name: str) -> str:
    goos = os.environ.get("GOOS", "")
    is_windows = os.name == "nt" or goos == "windows"
    return f"{base_name}.exe" if is_windows else base_name


def main() -> int:
    parser = argparse.ArgumentParser(description="Build the lvctl binary")
    parser.add_argument("--binary-name", default="lvctl")
    parser.add_argument("--git-commit", required=True)
    args = parser.parse_args()

    root = Path.cwd()
    output_path = root / "bin" / binary_name(args.binary_name)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    command = [
        "go",
        "build",
        f"-ldflags=-w -s -X main.version=dev -X main.commit={args.git_commit}",
        "-o",
        str(output_path),
        ".",
    ]
    result = subprocess.run(command)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
