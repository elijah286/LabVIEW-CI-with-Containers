#!/usr/bin/env python3
"""
build-antidoc-report.py - Turn the raw Antidoc output into a friendly, navigable
report that renders inside the CI dashboard chrome.

Antidoc (Wovalab) generates an AsciiDoc document (plus Kroki-rendered diagram
assets) for a LabVIEW project. The runner (run-antidoc.ps1) drops that output
under <out>/doc and records what it produced in <out>/antidoc-meta.json. This
script wraps it into:

    <out>/index.html    - friendly report (the deployed page); embeds the
                          generated HTML when present, otherwise renders the
                          generated AsciiDoc client-side (with a raw fallback)
    <out>/summary.json  - machine-readable status the dashboard / workflow read

It runs on the RUNNER (not in the container), after the doc-gen step, mirroring
build-analyzer-report.py / build-masscompile-report.py.

Usage:
    python3 build-antidoc-report.py \
        --in        ci-out/antidoc \
        --out       ci-out/antidoc \
        --platform  windows \
        [--sha SHA] [--repo owner/name] [--pages-url https://owner.github.io/repo] \
        [--commit-msg "..."] [--author "..."] [--date 2026-...Z] [--title "..."]
"""

from __future__ import annotations

import argparse
import html
import json
import os
from datetime import datetime, timezone
from pathlib import Path


# ── Helpers ──────────────────────────────────────────────────────────────────
def read_meta(report_dir: Path) -> dict:
    """Load antidoc-meta.json (written by run-antidoc.ps1). Missing/!valid -> {}."""
    for name in ("antidoc-meta.json", "summary.json"):
        p = report_dir / name
        if p.is_file():
            try:
                return json.loads(p.read_text(encoding="utf-8"))
            except (ValueError, OSError):
                continue
    return {}


def scan_doc(report_dir: Path) -> tuple[str, str, list[str]]:
    """Inventory <out>/doc. Returns (primary_kind, primary_path, rel_files).
    primary_path is relative to <out> (e.g. 'doc/Project.adoc')."""
    doc = report_dir / "doc"
    if not doc.is_dir():
        return "none", "", []
    files = sorted(p for p in doc.rglob("*") if p.is_file())
    rel = [p.relative_to(report_dir).as_posix() for p in files]
    htmls = sorted((p for p in files if p.suffix.lower() in (".html", ".htm")),
                   key=lambda p: p.stat().st_size, reverse=True)
    adocs = sorted((p for p in files if p.suffix.lower() == ".adoc"),
                   key=lambda p: p.stat().st_size, reverse=True)
    if htmls:
        return "html", htmls[0].relative_to(report_dir).as_posix(), rel
    if adocs:
        return "adoc", adocs[0].relative_to(report_dir).as_posix(), rel
    return "none", "", rel


def read_log(report_dir: Path) -> str:
    p = report_dir / "antidoc.log"
    if not p.is_file():
        return "(no log captured)"
    raw = p.read_bytes()
    if raw[:2] == b"\xff\xfe":
        return raw.decode("utf-16-le", "replace")
    if raw[:3] == b"\xef\xbb\xbf":
        return raw.decode("utf-8-sig", "replace")
    return raw.decode("utf-8", "replace")


# ── Report template (placeholder replacement, NOT f-strings, so the embedded
#    CSS/JS braces need no escaping) ───────────────────────────────────────────
PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Antidoc - __TITLE__</title>
  <script>__HDRCFG__</script>
  <script src="../../lvci-header.js" defer></script>
  <style>
    :root{--bg:#0d1117;--surface:#161b22;--border:#30363d;--fg:#e6edf3;--fg-muted:#8b949e;--link:#58a6ff}
    @media(prefers-color-scheme:light){:root{--bg:#fff;--surface:#f6f8fa;--border:#d0d7de;--fg:#1f2328;--fg-muted:#57606a;--link:#0969da}}
    *{box-sizing:border-box}
    body{margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--fg)}
    .wrap{max-width:1180px;margin:0 auto;padding:20px}
    .card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:20px;margin-bottom:16px}
    h1{margin:0 0 12px;font-size:1.3em}
    a{color:var(--link);text-decoration:none}
    a:hover{text-decoration:underline}
    .badge{display:inline-block;padding:3px 10px;border-radius:4px;font-weight:700;font-size:.85em;color:#fff;background:__STATUSCOLOR__}
    .meta{margin-top:10px;font-size:.82em;color:var(--fg-muted);display:flex;flex-wrap:wrap;gap:16px}
    .toolbar{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin:0 0 12px}
    .btn{display:inline-block;padding:5px 12px;border:1px solid var(--border);border-radius:6px;font-size:.85em;background:var(--bg);color:var(--fg);cursor:pointer}
    .btn:hover{border-color:var(--link);text-decoration:none}
    .doc{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:24px;overflow:auto}
    .doc img{max-width:100%;height:auto}
    .doc h1,.doc h2,.doc h3{border-bottom:1px solid var(--border);padding-bottom:.2em}
    .doc table{border-collapse:collapse}
    .doc td,.doc th{border:1px solid var(--border);padding:4px 8px}
    iframe.docframe{width:100%;height:78vh;border:1px solid var(--border);border-radius:8px;background:#fff}
    pre{background:var(--bg);border:1px solid var(--border);border-radius:6px;padding:14px;font-size:.78em;white-space:pre-wrap;word-break:break-word;overflow:auto;max-height:60vh;margin:0}
    ul.files{margin:0;padding-left:18px;font-size:.85em;columns:2}
    details{margin-top:14px}
    summary{cursor:pointer;color:var(--fg-muted);font-size:.85em}
    .hide{display:none}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>Antidoc - __TITLE__</h1>
      <span class="badge">__STATUSLABEL__</span>
      <div class="meta">
        <span>Date: __DATE__</span>
        <span>Duration: __DURATION__s</span>
        <span>Project: __PROJECT__</span>
        <span>LabVIEW: __LVVERSION__</span>
        <span>Files: __FILECOUNT__</span>
      </div>
    </div>
    __DOCSECTION__
    <div class="card">
      <details __FILESOPEN__>
        <summary>Generated files (__FILECOUNT__)</summary>
        <ul class="files">__FILELIST__</ul>
      </details>
      <details>
        <summary>Run log</summary>
        <pre>__LOGHTML__</pre>
      </details>
    </div>
  </div>
  __DOCSCRIPT__
</body>
</html>
"""

DOC_HTML = r"""<div class="card">
      <div class="toolbar">
        <a class="btn" href="__PRIMARY__" target="_blank" rel="noopener">Open full documentation</a>
      </div>
      <iframe class="docframe" src="__PRIMARY__" title="Generated documentation"></iframe>
    </div>"""

DOC_ADOC = r"""<div class="card">
      <div class="toolbar">
        <a class="btn" href="__PRIMARY__" download>Download AsciiDoc</a>
        <button class="btn" id="toggleRaw" type="button">View raw source</button>
        <span id="renderNote" style="font-size:.8em;color:var(--fg-muted)"></span>
      </div>
      <div class="doc" id="rendered">Rendering documentation...</div>
      <pre id="rawsrc" class="hide"></pre>
    </div>"""

DOC_NONE = r"""<div class="card">
      <p style="margin:0;color:var(--fg-muted)">No documentation was produced. See the run log below for details (the most common causes are Antidoc not being baked into the worker image, or no LabVIEW project being found).</p>
    </div>"""

# Renders the generated AsciiDoc client-side. Progressive: shows the raw source
# until Asciidoctor.js (CDN) loads and converts it; if the CDN is unreachable or
# conversion fails, the raw source stays visible and remains downloadable.
ADOC_SCRIPT = r"""<script>
  (function(){
    var PRIMARY = "__PRIMARY__";
    var IMAGESDIR = "__IMAGESDIR__";
    var rendered = document.getElementById('rendered');
    var rawsrc = document.getElementById('rawsrc');
    var note = document.getElementById('renderNote');
    var toggle = document.getElementById('toggleRaw');
    var source = '';
    toggle.addEventListener('click', function(){
      var showRaw = rawsrc.classList.contains('hide');
      rawsrc.classList.toggle('hide', !showRaw);
      rendered.classList.toggle('hide', showRaw);
      toggle.textContent = showRaw ? 'View rendered' : 'View raw source';
    });
    function showRawOnly(msg){
      rendered.classList.add('hide');
      rawsrc.classList.remove('hide');
      toggle.textContent = 'View rendered';
      if (note) note.textContent = msg || '';
    }
    fetch(PRIMARY).then(function(r){ if(!r.ok) throw new Error('HTTP '+r.status); return r.text(); })
      .then(function(text){
        source = text;
        rawsrc.textContent = text;
        var s = document.createElement('script');
        s.src = 'https://cdn.jsdelivr.net/npm/asciidoctor@2.2.6/dist/browser/asciidoctor.min.js';
        s.onload = function(){
          try{
            var factory = window.Asciidoctor;
            var ad = (typeof factory === 'function') ? factory() : factory;
            var htmlOut = ad.convert(source, {standalone:false, safe:'safe',
              attributes:{showtitle:true, 'imagesdir':IMAGESDIR, icons:'font', sectanchors:true}});
            rendered.innerHTML = htmlOut;
            if (note) note.textContent = '';
          }catch(e){ showRawOnly('Showing raw source (render failed).'); }
        };
        s.onerror = function(){ showRawOnly('Showing raw source (renderer offline).'); };
        document.head.appendChild(s);
      })
      .catch(function(e){
        rendered.textContent = 'Could not load the generated document (' + e.message + ').';
      });
  })();
</script>"""


def build(report_dir: Path, args) -> None:
    meta = read_meta(report_dir)
    primary_kind, primary_path, rel_files = scan_doc(report_dir)
    # Prefer the runner's own determination, fall back to a fresh scan.
    m_primary = meta.get("primary") or {}
    if m_primary.get("kind") and m_primary.get("kind") != "none":
        primary_kind = m_primary.get("kind", primary_kind)
        primary_path = m_primary.get("path", primary_path)
    if not rel_files and meta.get("files"):
        rel_files = list(meta.get("files"))

    generated = primary_kind in ("html", "adoc")
    status = "passed" if generated else "failed"
    status_label = "documentation generated" if generated else "no documentation produced"
    status_color = "#2ea043" if generated else "#da3633"

    title = args.title or meta.get("title") or (args.repo.split("/")[-1] if args.repo else "LabVIEW Project")
    duration = meta.get("duration", "")
    lv_version = meta.get("lvVersion", args.labview_version or "")
    project = meta.get("project", "")
    sha = args.sha or ""
    short = sha[:7] if sha else ""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    # Per-file download list.
    file_items = []
    for rel in rel_files:
        try:
            size = (report_dir / rel).stat().st_size
        except OSError:
            size = 0
        file_items.append(
            f'<li><a href="{html.escape(rel)}">{html.escape(rel)}</a> '
            f'<span style="color:var(--fg-muted)">({size} B)</span></li>')
    file_list_html = "".join(file_items) or '<li style="color:var(--fg-muted)">(none)</li>'

    # Documentation section + optional render script depend on what was produced.
    doc_script = ""
    if primary_kind == "html":
        doc_section = DOC_HTML.replace("__PRIMARY__", html.escape(primary_path))
    elif primary_kind == "adoc":
        images_dir = os.path.dirname(primary_path)  # e.g. 'doc' (Kroki images live beside the .adoc)
        doc_section = DOC_ADOC.replace("__PRIMARY__", html.escape(primary_path))
        doc_script = (ADOC_SCRIPT
                      .replace("__PRIMARY__", primary_path.replace('"', '\\"'))
                      .replace("__IMAGESDIR__", images_dir.replace('"', '\\"')))
    else:
        doc_section = DOC_NONE

    # The header's "Run log" link points here (matches DOCTYPES rawName); when the
    # report is framed the header derives the path from the embedded src instead.
    raw_url = "antidoc.log"
    hdr_cfg = ("window.LVCI={context:'antidoc-report',repo:'%s',pagesUrl:'../..',sha:'%s',short:'%s',platform:'%s',rawUrl:'%s'};"
               % (args.repo, sha, short, args.platform, raw_url))

    page = (PAGE
            .replace("__TITLE__", html.escape(title))
            .replace("__HDRCFG__", hdr_cfg)
            .replace("__STATUSCOLOR__", status_color)
            .replace("__STATUSLABEL__", status_label)
            .replace("__DATE__", now)
            .replace("__DURATION__", str(duration))
            .replace("__PROJECT__", html.escape(project) or "-")
            .replace("__LVVERSION__", html.escape(str(lv_version)) or "-")
            .replace("__FILECOUNT__", str(len(rel_files)))
            .replace("__FILESOPEN__", "open" if not generated else "")
            .replace("__FILELIST__", file_list_html)
            .replace("__LOGHTML__", html.escape(read_log(report_dir)))
            .replace("__DOCSECTION__", doc_section)
            .replace("__DOCSCRIPT__", doc_script))

    (report_dir / "index.html").write_text(page, encoding="utf-8")

    # Augment the machine-readable summary with run/commit context.
    summary = {
        "status": status,
        "title": title,
        "project": project,
        "lvVersion": lv_version,
        "platform": args.platform,
        "sha": sha,
        "primary": {"kind": primary_kind, "path": primary_path},
        "fileCount": len(rel_files),
        "duration": duration,
        "generated_at": now,
        "commit": {"message": args.commit_msg, "author": args.author, "date": args.date},
    }
    (report_dir / "summary.json").write_text(json.dumps(summary), encoding="utf-8")
    print(f"Antidoc report -> {report_dir/'index.html'} (status={status}, primary={primary_kind})")


def main() -> None:
    ap = argparse.ArgumentParser(description="Build the friendly Antidoc report.")
    ap.add_argument("--in", dest="in_dir", required=True,
                    help="Report directory holding antidoc-meta.json + doc/ (usually same as --out).")
    ap.add_argument("--out", required=True, help="Output directory for index.html + summary.json.")
    ap.add_argument("--platform", default="windows")
    ap.add_argument("--sha", default="")
    ap.add_argument("--repo", default="")
    ap.add_argument("--pages-url", dest="pages_url", default="")
    ap.add_argument("--title", default="")
    ap.add_argument("--labview-version", dest="labview_version", default="")
    ap.add_argument("--commit-msg", dest="commit_msg", default="")
    ap.add_argument("--author", default="")
    ap.add_argument("--date", default="")
    args = ap.parse_args()

    report_dir = Path(args.out)
    report_dir.mkdir(parents=True, exist_ok=True)
    build(report_dir, args)


if __name__ == "__main__":
    main()
