#!/usr/bin/env python3
"""Parse JKI Dragon (``.dragon``) dependency files into a normalized model.

A ``.dragon`` file is plain-text TOML (NOT JSON or a binary container), so it can
be read statically on any platform without Dragon, VIPM, NIPM, or LabVIEW. JKI
documents these primary tables::

    [project]
    [nipm.feeds]
    [nipm.dependencies]
    [vipm.dependencies]

Dependency values are either a bare version string::

    oglib_error = "6.0.0.26"

or an inline TOML table::

    oglib_array = { version = "6.0.1.20" }
    ni-daqmx = { version = "23.8.0", feed = "daqmx-feed" }

The parser is intentionally lenient (real files from newer Dragon versions differ
slightly from JKI's documented examples):

* accepts both ``labview-version`` and ``labview_version``
* accepts an integer or string LabVIEW year
* accepts string and inline-table dependency values
* tolerates empty ``[vipm]`` / ``[nipm]`` parent tables
* ignores unknown / future fields instead of rejecting the file

An actual TOML library is used (``tomllib`` on Python 3.11+, falling back to the
third-party ``tomli``); regular expressions are deliberately NOT used. When no
TOML library is available the module still imports, but parsing raises
``DragonParseError`` so callers can degrade gracefully.

The normalized dependency model is::

    {
      "manager": "vipm",                 # "vipm" | "nipm"
      "package_id": "oglib_array",
      "declared_version": "6.0.1.20",
      "feed_name": null,                 # str | None (NIPM named feed)
      "source_file": "example/Example.dragon"
    }
"""

from __future__ import annotations

import argparse
import json
import os
import sys

_TOML_BACKEND = None
try:  # Python 3.11+
    import tomllib as _toml  # type: ignore

    _TOML_BACKEND = "tomllib"
except ModuleNotFoundError:  # pragma: no cover - exercised on older runners
    try:
        import tomli as _toml  # type: ignore

        _TOML_BACKEND = "tomli"
    except ModuleNotFoundError:
        _toml = None  # type: ignore


class DragonParseError(Exception):
    """Raised when a ``.dragon`` file cannot be parsed."""


MANAGERS = ("vipm", "nipm")


def toml_available() -> bool:
    """True when a TOML backend is importable."""
    return _toml is not None


def _loads(text: str) -> dict:
    if _toml is None:
        raise DragonParseError(
            "no TOML library available (need Python 3.11+ tomllib or the 'tomli' package)"
        )
    try:
        return _toml.loads(text)
    except Exception as exc:  # tomllib.TOMLDecodeError and friends
        raise DragonParseError(f"invalid TOML: {exc}") from exc


def _normalize_value(val):
    """A dependency value is a version string or an inline table.

    Returns ``(declared_version, feed_name)``. Unknown shapes are stringified so
    a surprising-but-valid TOML value never aborts the whole file.
    """
    if isinstance(val, str):
        return val.strip(), None
    if isinstance(val, dict):
        ver = val.get("version")
        ver = str(ver).strip() if ver is not None else ""
        feed = val.get("feed")
        feed = str(feed).strip() if feed not in (None, "") else None
        return ver, feed
    if isinstance(val, bool):
        return str(val).lower(), None
    return str(val).strip(), None


def parse_dragon_text(text: str, source_file: str = "") -> dict:
    """Parse ``.dragon`` TOML text into the normalized model.

    Raises :class:`DragonParseError` on malformed TOML or a missing TOML backend.
    """
    data = _loads(text)
    if not isinstance(data, dict):
        raise DragonParseError("top-level TOML is not a table")

    project = data.get("project")
    project = project if isinstance(project, dict) else {}
    lv = project.get("labview-version", project.get("labview_version"))
    if lv is not None:
        lv = str(lv).strip()

    nipm = data.get("nipm")
    nipm = nipm if isinstance(nipm, dict) else {}
    vipm = data.get("vipm")
    vipm = vipm if isinstance(vipm, dict) else {}

    feeds: dict[str, str] = {}
    nipm_feeds = nipm.get("feeds")
    if isinstance(nipm_feeds, dict):
        for name, url in nipm_feeds.items():
            feeds[str(name)] = str(url)

    deps: list[dict] = []
    for manager, block in (("vipm", vipm), ("nipm", nipm)):
        table = block.get("dependencies") if isinstance(block, dict) else None
        if not isinstance(table, dict):
            continue
        for pkg, val in table.items():
            version, feed = _normalize_value(val)
            deps.append(
                {
                    "manager": manager,
                    "package_id": str(pkg),
                    "declared_version": version,
                    "feed_name": feed,
                    "source_file": source_file,
                }
            )
    deps.sort(key=lambda d: (d["manager"], d["package_id"].lower()))

    return {
        "source_file": source_file,
        "labview_version": lv,
        "feeds": feeds,
        "dependencies": deps,
    }


def parse_dragon_file(path: str) -> dict:
    """Parse a ``.dragon`` file from disk into the normalized model."""
    with open(path, "r", encoding="utf-8") as fh:
        return parse_dragon_text(fh.read(), source_file=path.replace("\\", "/"))


def discover_dragon_files(root: str = ".") -> list:
    """Return all ``*.dragon`` files under ``root`` (deterministic lexical order)."""
    skip = {".git", "ci-out", "build", "_lvci", "__pycache__", "node_modules"}
    out = []
    for current, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in skip]
        for name in files:
            if name.lower().endswith(".dragon"):
                path = os.path.join(current, name).replace("\\", "/")
                if path.startswith("./"):
                    path = path[2:]
                out.append(path)
    return sorted(out, key=str.lower)


def preflight(parsed_files: list) -> dict:
    """Build a deduplicated install set and detect cross-file conflicts.

    Returns ``{"install_set": [...], "conflicts": [...]}`` where each install-set
    entry is a normalized dependency augmented with ``source_files`` (every file
    that declares it) and conflicts flag: same package/different version, same
    NIPM feed name/different URL, and differing declared LabVIEW years.
    """
    # (manager, pkg_lower) -> version -> {source files}
    by_key: dict = {}
    canonical: dict = {}  # (manager, pkg_lower) -> a representative dep dict
    feed_urls: dict = {}  # feed name -> url -> {source files}
    lv_years: dict = {}   # year -> {source files}

    for pf in parsed_files:
        year = pf.get("labview_version")
        if year:
            lv_years.setdefault(year, set()).add(pf.get("source_file", ""))
        for name, url in (pf.get("feeds") or {}).items():
            feed_urls.setdefault(name, {}).setdefault(url, set()).add(pf.get("source_file", ""))
        for dep in pf.get("dependencies") or []:
            key = (dep["manager"], dep["package_id"].lower())
            by_key.setdefault(key, {}).setdefault(dep["declared_version"], set()).add(
                dep["source_file"]
            )
            canonical.setdefault(key, dep)

    conflicts = []
    install_set = []
    for key in sorted(by_key, key=lambda k: (k[0], k[1])):
        manager, pkg_lower = key
        versions = by_key[key]
        rep = canonical[key]
        sources = sorted({f for fs in versions.values() for f in fs})
        is_conflict = len(versions) > 1
        if is_conflict:
            conflicts.append(
                {
                    "type": "version",
                    "manager": manager,
                    "package_id": rep["package_id"],
                    "versions": sorted(versions.keys()),
                    "source_files": sources,
                }
            )
        install_set.append(
            {
                "manager": manager,
                "package_id": rep["package_id"],
                "declared_version": sorted(versions.keys())[0],
                "declared_versions": sorted(versions.keys()),
                "feed_name": rep.get("feed_name"),
                "source_files": sources,
                "conflict": is_conflict,
            }
        )

    for name in sorted(feed_urls):
        urls = feed_urls[name]
        if len(urls) > 1:
            conflicts.append(
                {
                    "type": "feed",
                    "feed_name": name,
                    "urls": sorted(urls.keys()),
                    "source_files": sorted({f for fs in urls.values() for f in fs}),
                }
            )

    if len(lv_years) > 1:
        conflicts.append(
            {
                "type": "labview_version",
                "years": sorted(lv_years.keys()),
                "source_files": sorted({f for fs in lv_years.values() for f in fs}),
            }
        )

    return {"install_set": install_set, "conflicts": conflicts}


def build_inventory(root: str = ".") -> dict:
    """Discover, parse, and preflight every ``.dragon`` file under ``root``.

    A file that fails to parse is recorded with an ``error`` instead of aborting
    the whole inventory.
    """
    files = []
    for path in discover_dragon_files(root):
        try:
            files.append(parse_dragon_file(path))
        except DragonParseError as exc:
            files.append(
                {
                    "source_file": path.replace("\\", "/"),
                    "labview_version": None,
                    "feeds": {},
                    "dependencies": [],
                    "error": str(exc),
                }
            )
    pre = preflight([f for f in files if not f.get("error")])
    return {
        "files": files,
        "install_set": pre["install_set"],
        "conflicts": pre["conflicts"],
        "toml_backend": _TOML_BACKEND,
    }


def _main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Parse repository .dragon files.")
    parser.add_argument(
        "--root", default=".", help="Repository root to scan for *.dragon files."
    )
    parser.add_argument(
        "--out", default="", help="Write the inventory JSON here (default: stdout)."
    )
    args = parser.parse_args(argv)

    if not toml_available():
        sys.stderr.write(
            "dragon_deps: no TOML backend (need Python 3.11+ or 'pip install tomli')\n"
        )
        return 2

    inventory = build_inventory(args.root)
    text = json.dumps(inventory, indent=2, ensure_ascii=True)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
