#!/usr/bin/env python3
"""
build-worker-manifest.py — Generate the CI worker manifest (HTML + JSON) for a
built LabVIEW CI container image.

A "worker version" is a short content hash of the inputs that produced the image
(Dockerfile + VIPM installer script + any applied *.vipc). The manifest records
exactly what that worker contains so a dashboard revision can link straight to
"what was installed in the worker that ran my CI":

    * platform (windows / linux / linux-beta) and the resolved LabVIEW version
  * the NI base image reference and its resolved digest
  * the full nipkg package list captured from the built image
    * every applied VIPC and the VI Package names it pins (parsed from the .vipc,
        which is a ZIP whose config.xml lists the packages)
  * build provenance (timestamp, source commit, Actions run URL)

Outputs (under --out-dir):
  manifest.json   — machine-readable record
  manifest.html   — human-readable page the dashboard links to

Usage:
  python3 build-worker-manifest.py \
      --platform        windows \
      --version         win-abc123def456 \
      --base-image      nationalinstruments/labview:latest-windows \
      --base-digest     sha256:... \
      --labview-version 2026 \
      --build-date      2026-06-15T12:00:00Z \
      --git-sha         <40-char build commit> \
      --run-url         https://github.com/<repo>/actions/runs/<id> \
      --nipkg-list      path/to/nipkg-list.txt \
      --vipc            "COTC Dependencies.vipc" \
      --out-dir         ci-out/workers/windows/win-abc123def456
"""

import argparse
import html
import json
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET


def parse_vipc_packages(vipc_path: Path) -> list[str]:
    """
    Return the sorted list of VI Package names pinned by a .vipc file.

    A .vipc is a ZIP archive containing a config.xml whose <Package><Name>
    elements name each package (e.g. "oglib_file-4.0.0.20"). Returns an empty
    list if the file cannot be read or parsed, so a malformed/renamed VIPC never
    aborts the manifest build.
    """
    names: list[str] = []
    try:
        with zipfile.ZipFile(vipc_path) as z:
            with z.open("config.xml") as f:
                root = ET.parse(f).getroot()
        for pkg in root.iter("Package"):
            name_el = pkg.find("Name")
            if name_el is not None and (name_el.text or "").strip():
                names.append(name_el.text.strip())
    except (OSError, KeyError, zipfile.BadZipFile, ET.ParseError) as exc:
        print(f"  WARN: could not parse VIPC '{vipc_path}': {exc}", file=sys.stderr)
    return sorted(set(names))


def parse_nipkg_list(raw: str) -> list[dict]:
    """
    Best-effort parse of `nipkg list` output into {name, version} records.

    The exact columns of `nipkg list` vary by NIPM version, so this is lenient:
    it skips header/separator/blank lines and treats the first two whitespace
    tokens as package name and version. Later columns can include architecture
    and a wrapping description, so the final token is not a reliable version.
    Lines that do not fit are ignored here but remain visible in the raw text
    preserved on the manifest.
    """
    packages: list[dict] = []
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        low = stripped.lower()
        if low.startswith(("name", "----", "====")) or set(stripped) <= set("-= "):
            continue
        tokens = stripped.split()
        if len(tokens) < 2:
            continue
        version = tokens[1]
        if any(ch.isdigit() for ch in version):
            packages.append({"name": tokens[0], "version": version})
    return sorted(packages, key=lambda p: p["name"].lower())


def build_manifest(args: argparse.Namespace) -> dict:
    nipkg_raw = ""
    if args.nipkg_list:
        p = Path(args.nipkg_list)
        if p.exists():
            nipkg_raw = p.read_text(encoding="utf-8", errors="replace")
        else:
            print(f"  WARN: nipkg list file not found: {p}", file=sys.stderr)

    vipcs = []
    for vipc in args.vipc or []:
        vp = Path(vipc)
        vipcs.append(
            {
                "file": vp.name,
                "packages": parse_vipc_packages(vp) if vp.exists() else [],
                "present": vp.exists(),
            }
        )

    return {
        "schema": 1,
        "platform": args.platform,
        "version": args.version,
        "labview_version": args.labview_version,
        "base_image": args.base_image,
        "base_digest": args.base_digest or "",
        "image_ref": args.image_ref or "",
        "build_date": args.build_date,
        "git_sha": args.git_sha,
        "run_url": args.run_url,
        "vipc": vipcs,
        "nipkg_raw": nipkg_raw,
        "nipkg_packages": parse_nipkg_list(nipkg_raw),
    }


_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CI Worker {version} — {platform}</title>
<script>window.LVCI={lvci_cfg};</script>
<script src="{lvci_src}" defer></script>
<style>
  :root{{--bg:#0d1117;--surface:#161b22;--border:#30363d;--fg:#e6edf3;--fg-muted:#8b949e;--row-border:#21262d;--link:#58a6ff;--accent:#2ea043}}
  @media(prefers-color-scheme:light){{:root{{--bg:#fff;--surface:#f6f8fa;--border:#d0d7de;--fg:#1f2328;--fg-muted:#57606a;--row-border:#eaeef2;--link:#0969da;--accent:#1a7f37}}}}
  *{{box-sizing:border-box}}
  body{{margin:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--fg);line-height:1.5}}
  .wrap{{max-width:980px;margin:0 auto;padding:24px}}
  h1{{font-size:1.4em;margin:0 0 4px}}
  h2{{font-size:1.05em;margin:28px 0 8px;border-bottom:1px solid var(--border);padding-bottom:6px}}
  .sub{{color:var(--fg-muted);font-size:.85em;margin-bottom:18px}}
  .ver{{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--accent);color:#fff;padding:2px 8px;border-radius:5px;font-size:.85em}}
  .nav{{margin:14px 0;font-size:.9em}} .nav a{{margin-right:16px;color:var(--link);text-decoration:none}} .nav a:hover{{text-decoration:underline}}
  table{{border-collapse:collapse;width:100%;background:var(--surface);border:1px solid var(--border);border-radius:8px;overflow:hidden;margin-top:4px}}
  th{{text-align:left;padding:8px 10px;border-bottom:1px solid var(--border);color:var(--fg-muted);font-size:.78em}}
  td{{padding:7px 10px;border-bottom:1px solid var(--row-border);font-size:.86em;vertical-align:top}}
  tr:last-child td{{border-bottom:none}}
  td.k{{color:var(--fg-muted);white-space:nowrap;width:1%}}
  code,pre{{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}}
  pre{{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:12px;overflow:auto;font-size:.8em;max-height:460px}}
  .pill{{display:inline-block;background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:1px 9px;margin:2px 3px 2px 0;font-size:.8em;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}}
  .muted{{color:var(--fg-muted)}}
</style>
</head>
<body>
<div class="wrap">
  <h1>CI Worker Manifest</h1>
  <div class="sub">Version <span class="ver">{version}</span> &nbsp;|&nbsp; {platform} &nbsp;|&nbsp; LabVIEW {labview_version}</div>
  <div class="nav">{nav}</div>

  <h2>Provenance</h2>
  <table>
    <tr><td class="k">Platform</td><td>{platform}</td></tr>
    <tr><td class="k">LabVIEW</td><td>{labview_version}</td></tr>
    <tr><td class="k">Image</td><td><code>{image_ref}</code></td></tr>
    <tr><td class="k">Base image</td><td><code>{base_image}</code></td></tr>
    <tr><td class="k">Base digest</td><td><code>{base_digest}</code></td></tr>
    <tr><td class="k">Built</td><td>{build_date}</td></tr>
    <tr><td class="k">Source commit</td><td><code>{git_sha}</code></td></tr>
    <tr><td class="k">Build run</td><td>{run_link}</td></tr>
  </table>

  <h2>Applied VI Package Configurations (.vipc)</h2>
  {vipc_section}

  <h2>Installed packages (nipkg)</h2>
  {nipkg_section}
</div>
</body>
</html>
"""


def render_html(m: dict, pages_url: str) -> str:
    def esc(v: str) -> str:
        return html.escape(str(v or ""))

    nav = (
        f'<a href="{esc(pages_url)}/">&larr; CI Dashboard</a>'
        f'<a href="{esc(pages_url)}/workers/{esc(m["platform"])}/latest.json">latest.json</a>'
        f'<a href="manifest.json">manifest.json</a>'
    )

    run_link = (
        f'<a href="{esc(m["run_url"])}" style="color:var(--link)">{esc(m["run_url"])}</a>'
        if m["run_url"]
        else '<span class="muted">—</span>'
    )

    # VIPC section
    if m["vipc"]:
        blocks = []
        for v in m["vipc"]:
            if v["packages"]:
                pills = "".join(f'<span class="pill">{esc(p)}</span>' for p in v["packages"])
            elif not v["present"]:
                pills = '<span class="muted">file not present at build time</span>'
            else:
                pills = '<span class="muted">no packages parsed</span>'
            blocks.append(f"<p><code>{esc(v['file'])}</code></p><div>{pills}</div>")
        vipc_section = "\n".join(blocks)
    else:
        vipc_section = '<p class="muted">None. This worker applies no VI Package Configuration.</p>'

    # nipkg section
    if m["nipkg_raw"].strip():
        rows = "".join(
            f"<tr><td><code>{esc(p['name'])}</code></td><td><code>{esc(p['version'])}</code></td></tr>"
            for p in m["nipkg_packages"]
        )
        table = (
            f'<table><tr><th>Package</th><th>Version</th></tr>{rows}</table>'
            if rows
            else ""
        )
        nipkg_section = (
            f"{table}<details><summary class=\"muted\">Raw <code>nipkg list</code> output</summary>"
            f"<pre>{esc(m['nipkg_raw'])}</pre></details>"
        )
    else:
        nipkg_section = '<p class="muted">No nipkg listing was captured for this worker.</p>'

    return _PAGE.format(
        version=esc(m["version"]),
        platform=esc(m["platform"]),
        labview_version=esc(m["labview_version"]),
        image_ref=esc(m["image_ref"]) or "—",
        base_image=esc(m["base_image"]),
        base_digest=esc(m["base_digest"]) or "—",
        build_date=esc(m["build_date"]),
        git_sha=esc(m["git_sha"]) or "—",
        run_link=run_link,
        nav=nav,
        vipc_section=vipc_section,
        nipkg_section=nipkg_section,
        # Shared site header (lvci-header.js, deployed once at the Pages root).
        # Worker manifests live at workers/<platform>/<version>/manifest.html
        # (three deep). It's a per-worker page, not a per-revision report, so it
        # gets the header + nav but no revision picker / regenerate action. The
        # src is RELATIVE so it always loads same-origin (the header derives its
        # base from its own resolved src — works in prod and local preview).
        lvci_cfg=json.dumps({"context": "worker-manifest", "pagesUrl": (pages_url or "").rstrip("/")}),
        lvci_src="../../../lvci-header.js",
    )


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Generate CI worker manifest (HTML + JSON).")
    ap.add_argument("--platform", required=True, choices=["windows", "linux", "linux-beta"])
    ap.add_argument("--version", required=True, help="Worker version, e.g. win-abc123def456")
    ap.add_argument("--labview-version", default="")
    ap.add_argument("--base-image", default="")
    ap.add_argument("--base-digest", default="")
    ap.add_argument("--image-ref", default="", help="Published image reference (tag)")
    ap.add_argument("--build-date", default=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    ap.add_argument("--git-sha", default="")
    ap.add_argument("--run-url", default="")
    ap.add_argument("--nipkg-list", default="", help="Path to captured `nipkg list` output")
    ap.add_argument("--vipc", action="append", default=[], help="Path to an applied .vipc (repeatable)")
    ap.add_argument("--pages-url", default="", help="Base Pages URL for nav links")
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args(argv)

    manifest = build_manifest(args)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    (out_dir / "manifest.html").write_text(
        render_html(manifest, args.pages_url), encoding="utf-8"
    )
    print(f"Worker manifest written to {out_dir} (version {manifest['version']}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
