#!/usr/bin/env python3
"""
build-binaries-report.py - Turn the build runner's summary.json into a friendly,
navigable Builds report: one card per build specification with its type, target,
status, and per-artifact download links + SHA-256 checksums, a Windows/Linux
toggle, and back-nav to the CI dashboard.

The runner (build-binaries.ps1 / build-binaries.sh) writes summary.json + a dist/
tree next to it. Those artifacts are deployed to gh-pages alongside this report,
so each output file links to dist/<project>/<spec>/<file> relative to the report.

Run on the RUNNER (not in the container), after the build.

Usage:
    python3 build-binaries-report.py \
        --summary   ci-out/builds/summary.json \
        --out       ci-out/builds \
        --platform  windows|linux \
        [--sha SHA] [--repo owner/name] [--pages-url https://owner.github.io/repo] \
        [--commit-msg "..."] [--author "..."] [--date 2026-...Z] \
        [--labview-version 2026] [--run-url https://github.com/.../runs/123]
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


STATUS_META = {
    "built":   {"label": "Built",   "color": "#2ea043"},
    "skipped": {"label": "Skipped", "color": "#8b949e"},
    "failed":  {"label": "Failed",  "color": "#da3633"},
}
RUN_STATUS_COLOR = {"passed": "#2ea043", "partial": "#bb8009", "failed": "#da3633"}


def slug(s: str) -> str:
    """Filesystem-safe slug - MUST match the runners' Get-Slug / slug()."""
    s = re.sub(r"[^A-Za-z0-9._-]+", "-", s or "").strip("-")
    return s or "unnamed"


def human_size(n: int) -> str:
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "?"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return ("%d %s" % (int(n), unit)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024.0
    return "%.1f TB" % n


def esc(s) -> str:
    return html.escape("" if s is None else str(s))


def build_report(summary: dict, args) -> str:
    platform = args.platform
    specs = summary.get("specs", []) or []
    status = summary.get("status", "passed")
    built = summary.get("built", 0)
    skipped = summary.get("skipped", 0)
    failed = summary.get("failed", 0)
    total = summary.get("total", len(specs))
    duration = summary.get("duration", 0)
    status_color = RUN_STATUS_COLOR.get(status, "#bb8009")

    # gh-pages layout: Windows report at builds/<sha>/, Linux at builds/<sha>/linux/.
    pages_up = "../.." if platform == "windows" else "../../.."

    sha = args.sha or ""
    short = sha[:7]
    hdr_cfg = (
        "window.LVCI={context:'builds-report',repo:%s,pagesUrl:%s,sha:%s,short:%s,"
        "platform:%s,rawUrl:'builds.log'};"
        % (
            json.dumps(args.repo or ""),
            json.dumps(pages_up),
            json.dumps(sha),
            json.dumps(short),
            json.dumps(platform),
        )
    )

    # Windows/Linux toggle links (absolute via pages-url + sha when available).
    base = (args.pages_url or "").rstrip("/")
    win_url = "%s/builds/%s/index.html" % (base, sha) if base and sha else "../index.html"
    lin_url = "%s/builds/%s/linux/index.html" % (base, sha) if base and sha else "linux/index.html"

    cards = []
    if not specs:
        cards.append(
            '<div class="card empty">No build specifications were found in this '
            "revision's projects.</div>"
        )
    for s in specs:
        st = s.get("status", "built")
        meta = STATUS_META.get(st, STATUS_META["built"])
        outputs = s.get("outputs", []) or []
        proj_slug = slug(s.get("project", ""))
        spec_slug = slug(s.get("name", ""))

        out_rows = []
        for o in outputs:
            fname = o.get("file", "")
            href = "dist/%s/%s/%s" % (proj_slug, spec_slug, fname)
            sha256 = o.get("sha256", "") or ""
            short_hash = (sha256[:12] + "\u2026") if sha256 else ""
            out_rows.append(
                '<div class="artifact">'
                '<a class="dl" href="%s" download><span class="dlico">&#8595;</span>%s</a>'
                '<span class="sz">%s</span>'
                '<span class="hash" title="SHA-256: %s">%s</span>'
                "</div>"
                % (esc(href), esc(fname), esc(human_size(o.get("size", 0))),
                   esc(sha256), esc(short_hash))
            )
        if st == "built" and not out_rows:
            out_rows.append('<div class="artifact none">No output files were located.</div>')
        if st == "skipped":
            out_rows.append('<div class="artifact none">%s</div>' % esc(s.get("message", "Skipped.")))
        if st == "failed":
            out_rows.append('<div class="artifact err">%s</div>' % esc(s.get("message", "Build failed.")))

        cards.append(
            '<div class="card spec">'
            '<div class="spec-head">'
            '<span class="spec-name">%s</span>'
            '<span class="type-badge">%s</span>'
            '<span class="target">target: %s</span>'
            '<span class="status-pill" style="background:%s">%s</span>'
            "</div>"
            '<div class="spec-sub">%s &middot; %ss</div>'
            '<div class="artifacts">%s</div>'
            "</div>"
            % (
                esc(s.get("name", "")),
                esc(s.get("type", "") or "Build"),
                esc(s.get("target", "")),
                meta["color"],
                esc(meta["label"]),
                esc(s.get("project", "")),
                esc(s.get("duration", 0)),
                "".join(out_rows),
            )
        )

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    commit_line = ""
    if args.commit_msg or args.author:
        commit_line = (
            '<div class="commit"><code>%s</code> %s%s</div>'
            % (
                esc(short),
                esc(args.commit_msg or ""),
                (" &middot; " + esc(args.author)) if args.author else "",
            )
        )

    return """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Builds - LabVIEW-CI-with-Containers</title>
  <script>%(hdr_cfg)s</script>
  <script src="%(pages_up)s/lvci-header.js" defer></script>
  <style>
    :root{
      --bg:#0d1117;--surface:#161b22;--border:#30363d;--fg:#e6edf3;--fg-muted:#8b949e;
      --link:#58a6ff;--chip:#21262d;--code:#010409;--bad:#da3633;
    }
    @media(prefers-color-scheme:light){:root{
      --bg:#fff;--surface:#f6f8fa;--border:#d0d7de;--fg:#1f2328;--fg-muted:#57606a;
      --link:#0969da;--chip:#eaeef2;--code:#f6f8fa;
    }}
    *{box-sizing:border-box}
    body{margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--fg)}
    .wrap{max-width:1100px;margin:0 auto;padding:20px}
    .card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:16px 18px;margin-bottom:14px}
    .summary-card{display:flex;align-items:center;flex-wrap:wrap;gap:14px}
    h1{margin:0;font-size:1.3em}
    .run-pill{display:inline-block;padding:3px 12px;border-radius:20px;font-weight:700;font-size:.8em;color:#fff;background:%(status_color)s;text-transform:capitalize}
    .counts{font-size:.85em;color:var(--fg-muted);display:flex;gap:14px;flex-wrap:wrap}
    .toggle{margin-left:auto;display:flex;gap:6px}
    .toggle a{font-size:.8em;padding:4px 12px;border:1px solid var(--border);border-radius:6px;color:var(--fg-muted);text-decoration:none}
    .toggle a.active{background:var(--link);border-color:var(--link);color:#fff}
    .commit{font-size:.8em;color:var(--fg-muted);margin-top:8px}
    .commit code{background:var(--code);border:1px solid var(--border);border-radius:4px;padding:1px 6px}
    .spec-head{display:flex;align-items:center;flex-wrap:wrap;gap:10px}
    .spec-name{font-weight:700;font-size:1.05em}
    .type-badge{font-size:.72em;padding:2px 8px;border-radius:12px;background:var(--chip);border:1px solid var(--border);color:var(--fg-muted)}
    .target{font-size:.78em;color:var(--fg-muted)}
    .status-pill{margin-left:auto;font-size:.72em;font-weight:700;color:#fff;padding:2px 10px;border-radius:12px}
    .spec-sub{font-size:.76em;color:var(--fg-muted);margin:6px 0 10px}
    .artifacts{display:flex;flex-direction:column;gap:6px}
    .artifact{display:flex;align-items:center;gap:12px;background:var(--code);border:1px solid var(--border);border-radius:6px;padding:8px 12px;font-size:.85em}
    .artifact .dl{color:var(--link);text-decoration:none;font-weight:600;display:flex;align-items:center;gap:6px}
    .artifact .dl:hover{text-decoration:underline}
    .artifact .dlico{font-weight:700}
    .artifact .sz{color:var(--fg-muted);font-size:.9em}
    .artifact .hash{margin-left:auto;color:var(--fg-muted);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.85em;cursor:help}
    .artifact.none{color:var(--fg-muted)}
    .artifact.err{color:var(--bad)}
    .empty{color:var(--fg-muted)}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card summary-card">
      <h1>Builds</h1>
      <span class="run-pill">%(status)s</span>
      <div class="counts">
        <span>%(built)s built</span>
        <span>%(skipped)s skipped</span>
        <span>%(failed)s failed</span>
        <span>%(total)s total</span>
        <span>%(duration)ss</span>
      </div>
      <div class="toggle">
        <a href="%(win_url)s" class="%(win_active)s">Windows</a>
        <a href="%(lin_url)s" class="%(lin_active)s">Linux</a>
      </div>
    </div>
    %(commit_line)s
    %(cards)s
    <div class="commit">Generated %(ts)s%(run_link)s</div>
  </div>
</body>
</html>
""" % {
        "hdr_cfg": hdr_cfg,
        "pages_up": pages_up,
        "status_color": status_color,
        "status": esc(status),
        "built": esc(built),
        "skipped": esc(skipped),
        "failed": esc(failed),
        "total": esc(total),
        "duration": esc(duration),
        "win_url": esc(win_url),
        "lin_url": esc(lin_url),
        "win_active": "active" if platform == "windows" else "",
        "lin_active": "active" if platform == "linux" else "",
        "commit_line": commit_line,
        "cards": "\n    ".join(cards),
        "ts": esc(ts),
        "run_link": (' &middot; <a style="color:var(--link)" href="%s">workflow run</a>' % esc(args.run_url)) if args.run_url else "",
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--platform", required=True, choices=["windows", "linux"])
    ap.add_argument("--sha", default="")
    ap.add_argument("--repo", default="")
    ap.add_argument("--pages-url", default="")
    ap.add_argument("--commit-msg", default="")
    ap.add_argument("--author", default="")
    ap.add_argument("--date", default="")
    ap.add_argument("--labview-version", default="")
    ap.add_argument("--run-url", default="")
    args = ap.parse_args()

    summary_path = Path(args.summary)
    try:
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print("Could not read summary.json: %s" % exc, file=sys.stderr)
        summary = {"platform": args.platform, "status": "passed", "specs": []}

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "index.html").write_text(build_report(summary, args), encoding="utf-8")
    print("Wrote %s" % (out_dir / "index.html"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
