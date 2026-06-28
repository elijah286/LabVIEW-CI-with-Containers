#!/usr/bin/env python3
"""
build-tooling-vipc.py - Generate a real, VIPM-openable `ci-tooling.vipc` from
`ci-tooling.packages.json`.

The CI worker image bakes in a default set of third-party LabVIEW tooling
(Caraya, VI Tester, LUnit, the UTF JUnit reporter, ...). Authoring a VI Package
Configuration normally requires the VIPM GUI (Windows-only), which is awkward for
a cross-platform, version-controlled, portable setup. This script produces an
honest `.vipc` that VIPM can open and edit, directly from a plain JSON manifest -
no VIPM and no Windows required.

How it stays a genuine VIPC without VIPM:
  A `.vipc` is a ZIP of `config.xml` plus, PER PACKAGE, a `<name>-<version>.spec`
  (INI metadata) and a `<name>-<version>.bmp` (icon). VIPM enumerates packages
  from those `.spec` files - a config.xml-only zip is rejected as "not a valid VI
  package configuration". The authoritative spec + icon for every published
  package are downloadable straight from the public VIPM indexes (each index
  entry exposes `Spec.URL` and `Icon.URL`); a spec/icon fetched that way is
  BYTE-IDENTICAL to what VIPM stores in a hand-authored VIPC. So we resolve each
  manifest package (and its dependency closure) against the same public indexes
  install-vipc.ps1 uses, download the real spec+icon for each, and assemble them
  into config.xml. `Included=false` keeps the package BINARIES out (download at
  apply time), so the file stays small (~tens of KB) while remaining a real VIPC.

The archive is written deterministically (sorted entry order, fixed ZIP
timestamp, content-derived ID); spec/icon bytes are fixed per published version,
so a given resolved set yields byte-identical output. Pin versions in the
manifest for fully reproducible images (null = latest at generation time).

Usage:
  python3 build-tooling-vipc.py [--manifest PATH] [--out PATH] [--labview-version YEAR]

Stdlib only, but REQUIRES network access to the public VIPM indexes
(download.ni.com, www.jkisoft.com) to fetch package specs/icons.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

HERE = Path(__file__).resolve().parent
DEFAULT_MANIFEST = HERE / "ci-tooling.packages.json"
DEFAULT_DEFAULTS = HERE / "ci-tooling.defaults.json"
DEFAULT_OUT = HERE / "ci-tooling.vipc"

_USER_AGENT = "LabVIEW-CI-with-Containers VIPC generator"

# Public VIPM repository indexes (the same ones install-vipc.ps1 resolves from).
# Each is an INI-style feed of `[Package <name>-<version>]` sections exposing
# Spec.URL / Icon.URL / Package.URL / Dependencies.Requires.
_PUBLIC_REPOS = [
    {
        "name": "NI LabVIEW Tools Network",
        "url": "http://download.ni.com/evaluation/labview/lvtn/vipm/index.vipr",
        "base": "http://download.ni.com/evaluation/labview/lvtn/vipm/",
        "file": "ni-lvtn.vipr",
    },
    {
        "name": "VIPM Community",
        "url": "http://www.jkisoft.com/packages/jkisoft.ogpd",
        "base": "http://www.jkisoft.com/packages/",
        "file": "vipm-community.ogpd",
    },
]

# Legacy/short package names a manifest may use, mapped to the ID the public
# indexes publish them under (mirrors install-vipc.ps1's alias table).
_NAME_ALIASES = {
    "jki_vi_tester": "jki_labs_tool_vi_tester",
}

# Fixed ZIP member timestamp (the DOS epoch) keeps the archive byte-stable across
# regenerations regardless of when/where it runs.
_FIXED_ZIP_DATETIME = (1980, 1, 1, 0, 0, 0)
# Fixed config timestamps for the same reason; these fields are informational
# (apply is driven by `-labview_version` on the CLI), so a constant is fine.
_FIXED_CONFIG_DATE = "2026-01-01 00:00:00"


def labview_target_version(year: str) -> str:
    """
    Map a LabVIEW year to the .vipc Target <Version> string, e.g. 2026 ->
    '26.1 (64-bit)'. The CI base image is 64-bit LabVIEW; the minor '.1' matches
    the 26.1 NI feed the image installs from. Falls back to '<yy>.1 (64-bit)'.
    """
    try:
        major = int(year) - 2000
    except (TypeError, ValueError):
        return "26.1 (64-bit)"
    return f"{major}.1 (64-bit)"


def selected_packages(manifest: dict) -> list[dict]:
    """Return the manifest packages flagged for inclusion, in manifest order."""
    pkgs = (manifest.get("vipmPackages") or {}).get("packages") or []
    out: list[dict] = []
    for p in pkgs:
        if not isinstance(p, dict):
            continue
        if p.get("include") is False:
            continue
        name = (p.get("name") or "").strip()
        if name:
            out.append(p)
    return out


def _norm_version(pkg: dict) -> str:
    """Pinned version string, normalised ('' for null/latest)."""
    v = pkg.get("version")
    return str(v).strip() if v not in (None, "") else ""


def merge_packages(defaults_pkgs: list[dict], consumer_pkgs: list[dict]) -> list[dict]:
    """Merge tooling-pushed defaults (base) with the consumer's packages (over).

    The consumer WINS on a name collision: a repo never loses a pin it set in its
    own ci-tooling.packages.json. A package present only in the defaults is ADDED
    (this is how the tooling ships new baked-in packages additively); a package
    only in the consumer file is kept. A differing pinned version is surfaced as a
    notice (not an error) so the consumer can choose to align. Deterministic order:
    defaults first, then consumer-only additions.
    """
    by_name: dict[str, dict] = {}
    order: list[str] = []
    for p in defaults_pkgs:
        n = (p.get("name") or "").strip().lower()
        if not n:
            continue
        if n not in by_name:
            order.append(n)
        by_name[n] = p
    for p in consumer_pkgs:
        n = (p.get("name") or "").strip().lower()
        if not n:
            continue
        if n in by_name:
            dv, cv = _norm_version(by_name[n]), _norm_version(p)
            if dv and cv and dv != cv:
                print(f"  note: '{p.get('name')}' - tooling default pins {dv}, this repo "
                      f"pins {cv}; using the repo's {cv}.", file=sys.stderr)
        else:
            order.append(n)
        by_name[n] = p  # consumer wins
    return [by_name[n] for n in order]


# --- Public VIPM index access ------------------------------------------------

def _http_get(url: str, timeout: int = 180) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": _USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 (public indexes)
        return resp.read()


def version_key(version: str) -> tuple:
    """Comparable key from a version string (mirrors Get-NumericVersionKey)."""
    nums = [int(n) for n in re.findall(r"\d+", str(version))]
    nums = (nums + [0] * 6)[:6]
    return tuple(nums)


def parse_index(text: str, base_url: str, repo: str) -> list[dict]:
    """Parse a .vipr/.ogpd index into package records."""
    records: list[dict] = []
    cur: dict | None = None
    for raw in text.splitlines():
        line = raw.rstrip("\r")
        head = re.match(r"^\[Package\s+(?P<id>.+)\]\s*$", line)
        if head:
            if cur:
                records.append(cur)
            pid = head.group("id").strip()
            name, version = pid, ""
            vm = re.match(r"^(?P<name>.+)-(?P<version>\d+(?:\.\d+)+[A-Za-z0-9_.\-]*)$", pid)
            if vm:
                name, version = vm.group("name"), vm.group("version")
            cur = {
                "id": pid, "name": name, "version": version,
                "key": version_key(version), "repo": repo, "base": base_url,
                "spec_url": "", "icon_url": "", "pkg_url": "", "requires": "",
            }
            continue
        if cur is None:
            continue
        kv = re.match(r"^(?P<k>[^=]+)=(?P<v>.*)$", line)
        if not kv:
            continue
        key, val = kv.group("k").strip(), kv.group("v").strip()
        if key == "Spec.URL":
            cur["spec_url"] = val
        elif key == "Icon.URL":
            cur["icon_url"] = val
        elif key == "Package.URL":
            cur["pkg_url"] = val
        elif key == "Dependencies.Requires":
            cur["requires"] = val
    if cur:
        records.append(cur)
    return records


def load_public_index(cache_dir: Path) -> dict[str, list[dict]]:
    """Download + parse both public VIPM indexes; return {name: [records]}."""
    by_name: dict[str, list[dict]] = {}
    cache_dir.mkdir(parents=True, exist_ok=True)
    for repo in _PUBLIC_REPOS:
        idx_path = cache_dir / repo["file"]
        if not idx_path.exists():
            print(f"  downloading index: {repo['url']}", file=sys.stderr)
            idx_path.write_bytes(_http_get(repo["url"]))
        text = idx_path.read_text(encoding="utf-8", errors="replace")
        for rec in parse_index(text, repo["base"], repo["name"]):
            by_name.setdefault(rec["name"], []).append(rec)
    return by_name


def select_record(by_name: dict, name: str, version: str, minimum: bool):
    """Pick the best index record for a request (latest, exact, or >= minimum)."""
    cands = by_name.get(name)
    if not cands:
        return None
    if version:
        if minimum:
            mk = version_key(version)
            cands = [c for c in cands if c["key"] >= mk]
        else:
            cands = [c for c in cands if c["version"] == version]
    if not cands:
        return None
    return max(cands, key=lambda c: c["key"])


def parse_requires(text: str) -> list[dict]:
    """Parse a Dependencies.Requires CSV ('name>=ver,other=ver') into requests."""
    out: list[dict] = []
    if not text or not text.strip():
        return out
    for part in text.split(","):
        m = re.match(r"^(?P<name>[A-Za-z0-9_.\-]+)\s*(?P<op>>=|==|=)?\s*(?P<version>[A-Za-z0-9_.\-]+)?", part.strip())
        if m:
            op = m.group("op") or ""
            out.append({
                "name": m.group("name").strip(),
                "version": (m.group("version") or "").strip(),
                "minimum": (op == ">=" or not op),
            })
    return out


def resolve_closure(roots: list[dict], by_name: dict) -> list[dict]:
    """Resolve roots + their full dependency closure to concrete index records.

    Mirrors install-vipc.ps1 Get-LocalVipFilesForSpecs/Resolve-One: a missing ROOT
    is fatal; a missing transitive DEPENDENCY is skipped with a warning (some
    packages declare a dependency whose content is bundled inside the parent .vip
    and is never published standalone, e.g. astemes_lib_lunit_cli_system).
    """
    exact_by_name = {r["name"]: r for r in roots if r.get("version") and not r.get("minimum")}
    resolved: dict[str, dict] = {}
    visiting: set = set()

    def resolve_one(req: dict, is_dep: bool) -> None:
        if req.get("minimum") and req["name"] in exact_by_name:
            req = exact_by_name[req["name"]]
        key = f"{req['name']}@{req.get('version', '')}:{req.get('minimum')}"
        if key in visiting:
            return
        visiting.add(key)
        rec = select_record(by_name, req["name"], req.get("version", ""), req.get("minimum", False))
        if rec is None:
            vtext = f" version '{req['version']}'" if req.get("version") else ""
            if is_dep:
                print(f"  note: skipping dependency '{req['name']}'{vtext}: not in the public "
                      f"VIPM indexes (assumed bundled in its parent package).", file=sys.stderr)
                return
            raise SystemExit(f"ERROR: package '{req['name']}'{vtext} was not found in the public VIPM indexes.")
        if rec["name"] in resolved:
            return
        for dep in parse_requires(rec["requires"]):
            resolve_one(dep, True)
        resolved[rec["name"]] = rec

    for root in roots:
        resolve_one(root, False)
    return sorted(resolved.values(), key=lambda r: r["id"])


def asset_url(base: str, url: str) -> str:
    if re.match(r"^https?://", url):
        return url
    return base.rstrip("/") + "/" + url.lstrip("/")


def harvest_assets(records: list[dict], cache_dir: Path) -> dict[str, bytes]:
    """Download each record's real .spec + .bmp (from the index) -> {member: bytes}."""
    cache_dir.mkdir(parents=True, exist_ok=True)
    members: dict[str, bytes] = {}
    for rec in records:
        for url_key, ext in (("spec_url", "spec"), ("icon_url", "bmp")):
            rel = rec.get(url_key)
            if not rel:
                raise SystemExit(f"ERROR: package '{rec['id']}' has no {ext} URL in the index; "
                                 f"cannot build a VIPM-valid VIPC.")
            member = f"{rec['id']}.{ext}"
            cached = cache_dir / member
            if not cached.exists():
                cached.write_bytes(_http_get(asset_url(rec["base"], rel)))
            members[member] = cached.read_bytes()
    return members


# --- VIPC assembly -----------------------------------------------------------

def config_id_for(records: list[dict]) -> str:
    """Deterministic 32-hex config ID derived from the resolved package IDs."""
    basis = "\n".join(r["id"] for r in records)
    return hashlib.md5(basis.encode("utf-8")).hexdigest()


def build_config_xml(target: dict, records: list[dict], labview_version: str) -> str:
    target_name = escape(str(target.get("name") or "LabVIEW"))
    target_version = escape(labview_target_version(labview_version))

    lines = [
        f'<VI_Package_Configuration File_Type="xml" Version="0.6" '
        f'Created_Date="{_FIXED_CONFIG_DATE}" Modified_Date="{_FIXED_CONFIG_DATE}" '
        f'Creator="cotc-ci" Comments="Generated by build-tooling-vipc.py from '
        f'ci-tooling.packages.json" ID="{config_id_for(records)}">',
        "  <Target>",
        f"    <Name>{target_name}</Name>",
        f"    <Version>{target_version}</Version>",
    ]
    for rec in records:
        lines += [
            "    <Package>",
            f"      <Name>{escape(rec['id'])}</Name>",
            "      <Included>false</Included>",
            "      <Dependency>false</Dependency>",
            "      <Pinned>false</Pinned>",
            "    </Package>",
        ]
    lines += ["  </Target>", "</VI_Package_Configuration>", ""]
    return "\n".join(lines)


def write_vipc(out_path: Path, config_xml: str, assets: dict[str, bytes]) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    entries: list[tuple[str, bytes]] = [("config.xml", config_xml.encode("utf-8"))]
    for member in sorted(assets):
        entries.append((member, assets[member]))
    with zipfile.ZipFile(out_path, "w") as z:
        for member, data in entries:
            info = zipfile.ZipInfo(member, date_time=_FIXED_ZIP_DATETIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o600 << 16
            z.writestr(info, data)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Generate ci-tooling.vipc from the package manifest.")
    ap.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    ap.add_argument("--defaults", type=Path, default=DEFAULT_DEFAULTS,
                    help="Tooling-pushed base packages merged UNDER --manifest (consumer wins). "
                         "Skipped if the file is absent.")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--labview-version", default=None,
                    help="Override the LabVIEW year (default: manifest target.labviewVersion).")
    ap.add_argument("--cache-dir", type=Path, default=None,
                    help="Directory to cache downloaded indexes + specs/icons "
                         "(default: a temp dir). Reused across runs.")
    args = ap.parse_args(argv)

    if not args.manifest.exists():
        print(f"ERROR: manifest not found: {args.manifest}", file=sys.stderr)
        return 1

    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"ERROR: manifest is not valid JSON: {exc}", file=sys.stderr)
        return 1

    defaults: dict = {}
    if args.defaults and args.defaults.exists():
        try:
            defaults = json.loads(args.defaults.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            print(f"ERROR: defaults manifest is not valid JSON: {exc}", file=sys.stderr)
            return 1

    labview_version = args.labview_version or str(
        (manifest.get("target") or {}).get("labviewVersion")
        or (defaults.get("target") or {}).get("labviewVersion")
        or "2026"
    )
    packages = merge_packages(selected_packages(defaults), selected_packages(manifest))
    if not packages:
        print("ERROR: no included packages in manifest; nothing to generate.", file=sys.stderr)
        return 1

    # Manifest packages are the ROOT requests; resolve each (aliasing legacy names
    # to their published IDs) plus its dependency closure against the public
    # indexes, then harvest the real spec+icon for every resolved package.
    roots = [{"name": _NAME_ALIASES.get(p["name"].strip(), p["name"].strip()),
              "version": _norm_version(p),
              "minimum": False} for p in packages]

    cache_dir = args.cache_dir or (Path(tempfile.gettempdir()) / "lvci-vipc-cache")
    try:
        by_name = load_public_index(cache_dir)
    except (urllib.error.URLError, OSError) as exc:
        print(f"ERROR: could not download the public VIPM indexes: {exc}", file=sys.stderr)
        return 2

    records = resolve_closure(roots, by_name)
    try:
        assets = harvest_assets(records, cache_dir)
    except (urllib.error.URLError, OSError) as exc:
        print(f"ERROR: could not download package spec/icon assets: {exc}", file=sys.stderr)
        return 2

    target = manifest.get("target") or defaults.get("target") or {}
    config_xml = build_config_xml(target, records, labview_version)
    write_vipc(args.out, config_xml, assets)

    print(f"Wrote {args.out} (LabVIEW {labview_version}, {len(records)} package(s), VIPM-openable):")
    for rec in records:
        print(f"  - {rec['id']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
