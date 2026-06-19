#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import Path


def binary_name(base_name: str) -> str:
    goos = os.environ.get("GOOS", "")
    is_windows = os.name == "nt" or goos == "windows"
    return f"{base_name}.exe" if is_windows else base_name


def main() -> int:
    parser = argparse.ArgumentParser(description="Refresh lvctl generated assets")
    parser.add_argument("--git-root", required=True)
    parser.add_argument("--binary-name", default="lvctl")
    parser.add_argument("--git-commit", required=True)
    args = parser.parse_args()

    root = Path.cwd()
    vis_dir = root / "vis"
    zip_path = vis_dir / "toimages.zip"

    # Re-create the zip from the toimages directory BEFORE building so the
    # //go:embed directive can find it during compilation.
    if zip_path.exists():
        zip_path.unlink()

    # Use -r (recurse) without -y so symlinks are resolved to regular files.
    # The test suite requires no symlinks in the embedded zip.
    zip_cmd = ["zip", "-r", str(zip_path.name), "toimages", "-x", "*.DS_Store"]
    subprocess.run(
        zip_cmd,
        cwd=vis_dir,
        check=True,
    )

    subprocess.run(
        [
            "uv",
            "run",
            "--no-project",
            "python",
            "scripts/build.py",
            "--binary-name",
            args.binary_name,
            "--git-commit",
            args.git_commit,
        ],
        check=True,
    )

    binary_path = root / "bin" / binary_name(args.binary_name)
    subprocess.run(
        [
            "uv",
            "run",
            "--no-project",
            "python",
            str(Path(args.git_root) / "tools" / "vi-svg" / "convert_vi_to_svg.py"),
            "generate",
            "--dir",
            "vis",
            "--lvctl",
            str(binary_path),
        ],
        check=True,
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
