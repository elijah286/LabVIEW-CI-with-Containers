#!/usr/bin/env python3
"""Build a static, GitLab-native LabVIEW CI Pages dashboard."""

from __future__ import annotations

import argparse
import html
import json
import os
import shutil
from pathlib import Path


ROOT = Path.cwd()
CATALOG = ROOT / ".github" / "labview-ci" / "catalog.json"
MANIFEST = ROOT / ".github" / "labview-ci.yml"


def copy_tree(source: Path, target: Path) -> None:
    if not source.is_dir():
        return
    for child in source.iterdir():
        destination = target / child.name
        if child.is_dir():
            shutil.copytree(child, destination, dirs_exist_ok=True)
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(child, destination)


def read_json(path: Path, fallback: dict | list) -> dict | list:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return fallback


def selected_activities() -> list[str]:
    if not MANIFEST.is_file():
        return []
    result: list[str] = []
    collecting = False
    for raw in MANIFEST.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if stripped == "activities:":
            collecting = True
            continue
        if collecting and stripped.startswith("- "):
            result.append(stripped[2:].strip())
        elif collecting and stripped and not raw.startswith((" ", "\t")):
            break
    return result


def report_rows(report_root: Path) -> list[tuple[str, str, str, str]]:
    rows: list[tuple[str, str, str, str]] = []
    if not report_root.is_dir():
        return rows
    for index in sorted(report_root.rglob("index.html"), key=lambda path: path.as_posix(), reverse=True):
        relative = index.relative_to(report_root).as_posix()
        parts = relative.split("/")
        if len(parts) < 2 or parts[0] in {"vi-snapshots", "workers"}:
            continue
        capability = parts[0].replace("-", " ").title()
        revision = parts[1][:12]
        platform = parts[2] if len(parts) > 3 else "windows"
        rows.append((capability, revision, platform, relative))
    return rows


def write_index(out: Path, report_root: Path) -> None:
    catalog = read_json(CATALOG, {})
    version = html.escape(str(catalog.get("version", "unknown"))) if isinstance(catalog, dict) else "unknown"
    project = html.escape(os.environ.get("CI_PROJECT_PATH", "namespace/project"))
    pages_url = html.escape(os.environ.get("CI_PAGES_URL", ""))
    pipeline_url = html.escape(os.environ.get("CI_PIPELINE_URL", ""))
    commit = html.escape(os.environ.get("CI_COMMIT_SHORT_SHA", ""))
    activities = selected_activities()
    reports = report_rows(report_root)
    activity_items = "".join(f"<li>{html.escape(activity)}</li>" for activity in activities) or "<li>dashboard</li>"
    report_items = "".join(
        f'<tr><td>{html.escape(capability)}</td><td><code>{html.escape(revision)}</code></td>'
        f'<td>{html.escape(platform)}</td><td><a href="{html.escape(url)}">Open report</a></td></tr>'
        for capability, revision, platform, url in reports
    ) or '<tr><td colspan="4" class="empty">No published reports yet.</td></tr>'
    pipeline_link = f'<a href="{pipeline_url}">Open pipeline</a>' if pipeline_url else ""
    (out / "index.html").write_text(
        f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>LabVIEW CI - {project}</title>
<style>
:root {{ color-scheme: light dark; --ink:#17212b; --muted:#536371; --line:#b9c5cc; --paper:#f3f7f8; --panel:#fff; --accent:#087e8b; }}
@media (prefers-color-scheme: dark) {{ :root {{ --ink:#e8f0f2; --muted:#a4b1b6; --line:#435158; --paper:#122027; --panel:#192b33; --accent:#54c6cf; }} }}
* {{ box-sizing:border-box }} body {{ margin:0;background:var(--paper);color:var(--ink);font:16px Georgia,serif }}
header {{ background:#073b4c;color:#fff;border-bottom:5px solid #f4a261 }} main {{ max-width:1100px;margin:auto;padding:32px 20px 64px }}
h1 {{ margin:0;font-size:28px;letter-spacing:0 }} header div {{ max-width:1100px;margin:auto;padding:24px 20px }}
.meta {{ margin:8px 0 0;color:#dbe9ed;font:13px ui-monospace,SFMono-Regular,Menlo,monospace }} .grid {{ display:grid;grid-template-columns:minmax(220px,1fr) minmax(0,3fr);gap:20px }}
section {{ background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:20px }} h2 {{ margin:0 0 14px;font-size:18px }} ul {{ margin:0;padding-left:20px }} li {{ margin:6px 0 }}
table {{ width:100%;border-collapse:collapse;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px }} th,td {{ padding:10px 8px;border-top:1px solid var(--line);text-align:left }} th {{ color:var(--muted);font-weight:600 }} .empty {{ color:var(--muted);font-family:Georgia,serif }} a {{ color:var(--accent);font-weight:700 }}
footer {{ color:var(--muted);font-size:13px;margin-top:18px }} @media(max-width:680px) {{ .grid {{ grid-template-columns:1fr }} }}
</style></head><body><header><div><h1>LabVIEW CI</h1><p class="meta">{project} {commit} {pipeline_link}</p></div></header>
<main><div class="grid"><section><h2>Installed activities</h2><ul>{activity_items}</ul></section><section><h2>Published reports</h2><table><thead><tr><th>Activity</th><th>Revision</th><th>Platform</th><th></th></tr></thead><tbody>{report_items}</tbody></table></section></div>
<footer>Tooling v{version}. {pages_url}</footer></main></body></html>\n""",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--previous", default="")
    parser.add_argument("--reports", default="ci-out/gitlab-pages")
    args = parser.parse_args()
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    if args.previous:
        copy_tree(Path(args.previous) / "public", out)
    report_source = Path(args.reports)
    if report_source.is_dir():
        copy_tree(report_source, out)
    if CATALOG.is_file():
        shutil.copy2(CATALOG, out / "catalog.json")
    write_index(out, out)


if __name__ == "__main__":
    main()