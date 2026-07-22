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


_IMG_EXTS = (".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp")


def _doc_viewer_data(report_dir: Path, rel_files, primary_path):
    """Work out what the client viewer needs: the main AsciiDoc (the top-level
    document that pulls the sections together with include::), the include key
    for each .adoc, the image list, and the imagesdir the deployed page must use.
    Returns (main_rel, doc_dir, main_key, doc_manifest, img_manifest, images_dir)."""
    adoc = [r for r in rel_files if r.lower().endswith(".adoc")]
    imgs = [r for r in rel_files if r.lower().endswith(_IMG_EXTS)]

    def size(r):
        try:
            return (report_dir / r).stat().st_size
        except OSError:
            return 0

    # Prefer a top-level document (one segment below the doc root) that actually
    # has include:: directives; else the largest top-level doc; else the primary.
    tops = [r for r in adoc if r.count("/") == 1]
    main_rel = ""
    for r in sorted(tops or adoc, key=lambda x: -size(x)):
        try:
            if "include::" in (report_dir / r).read_text(encoding="utf-8", errors="replace"):
                main_rel = r
                break
        except OSError:
            pass
    if not main_rel:
        main_rel = tops[0] if tops else (adoc[0] if adoc else primary_path)

    doc_dir = os.path.dirname(main_rel)  # e.g. 'doc'

    def rel_to_doc(r):
        if doc_dir and r.startswith(doc_dir + "/"):
            return r[len(doc_dir) + 1:]
        return r

    # Main document first, then its section files sorted by name.
    others = sorted([r for r in adoc if r != main_rel], key=lambda x: x.lower())
    ordered = ([main_rel] if main_rel in adoc else []) + others
    doc_manifest = [{"path": r, "key": rel_to_doc(r)} for r in ordered]
    main_key = rel_to_doc(main_rel)

    img_manifest = sorted(imgs, key=lambda x: x.lower())
    # imagesdir the page must reference so `image::X[]` resolves to the deployed
    # file; Antidoc puts images in <doc>/Images and sets `:imagesdir: Images`.
    images_dir = os.path.dirname(img_manifest[0]) if img_manifest else doc_dir

    return main_rel, doc_dir, main_key, doc_manifest, img_manifest, images_dir


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
    /* Two-pane documentation viewer */
    .viewer{display:flex;border:1px solid var(--border);border-radius:8px;overflow:hidden;min-height:60vh}
    .vsidebar{flex:0 0 244px;background:var(--bg);border-right:1px solid var(--border);overflow:auto;max-height:80vh;padding:6px 0;font-size:.85em}
    .vgroup{padding:12px 12px 4px;color:var(--fg-muted);font-size:.72em;text-transform:uppercase;letter-spacing:.05em;font-weight:700}
    .vfile{display:block;width:100%;text-align:left;border:0;border-left:2px solid transparent;background:none;padding:5px 12px 5px 20px;color:var(--fg);cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font:inherit}
    .vfile:hover{background:var(--surface);text-decoration:none}
    .vfile.active{background:var(--surface);border-left-color:var(--link);color:var(--link);font-weight:600}
    .vmain{flex:1 1 auto;min-width:0;overflow:auto;max-height:80vh}
    .vmain .doc{border:0;border-radius:0;min-height:100%}
    .vmain pre{border:0;border-radius:0;max-height:none}
    .imgview{padding:20px;text-align:center}
    .imgview img{max-width:100%;height:auto;border:1px solid var(--border);border-radius:6px;background:#fff}
    .imgview .cap{margin-top:10px;font-size:.82em;color:var(--fg-muted);word-break:break-all}
    @media(max-width:720px){.viewer{flex-direction:column}.vsidebar{flex:none;max-height:210px;border-right:0;border-bottom:1px solid var(--border)}}
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
        <a class="btn" href="__MAINADOC__" download>Download AsciiDoc</a>
        <a class="btn" href="__MAINADOC__" target="_blank" rel="noopener">Open raw source</a>
        <span id="renderNote" style="font-size:.8em;color:var(--fg-muted)"></span>
      </div>
      <div class="viewer">
        <nav class="vsidebar" id="vsidebar" aria-label="Generated documentation files"></nav>
        <div class="vmain">
          <div class="doc" id="rendered">Rendering documentation&hellip;</div>
          <pre id="rawsrc" class="hide"></pre>
          <div class="imgview hide" id="imgview"></div>
        </div>
      </div>
    </div>"""

DOC_NONE = r"""<div class="card">
      <p style="margin:0;color:var(--fg-muted)">No documentation was produced. See the run log below for details (the most common causes are Antidoc not being baked into the worker image, or no LabVIEW project being found).</p>
    </div>"""

# Client-side documentation viewer. A file navigator on the left lists the main
# AsciiDoc, its section includes and every rendered image; the pane on the right
# shows the fully rendered document by default (Asciidoctor.js from a CDN, with a
# custom include-processor that resolves Antidoc's `include::Includes/NNN.adoc[]`
# from files fetched up front, and imagesdir pinned at the deployed image folder),
# or the raw source of any file / a preview of any image on demand. If the CDN is
# unreachable the raw main source stays visible and every file remains downloadable.
ADOC_SCRIPT = r"""<script>
  (function(){
    var MAINKEY   = "__MAINKEY__";
    var IMAGESDIR = "__IMAGESDIR__";
    var DOCFILES  = __DOCFILES__;   // [{path:'doc/Includes/000.adoc', key:'Includes/000.adoc'}]
    var IMGFILES  = __IMGFILES__;   // ['doc/Images/foo.png', ...]
    var rendered = document.getElementById('rendered');
    var rawsrc   = document.getElementById('rawsrc');
    var imgview  = document.getElementById('imgview');
    var sidebar  = document.getElementById('vsidebar');
    var note     = document.getElementById('renderNote');
    var DOCMAP = {};          // include key -> source text
    var activeBtn = null;

    function show(which){
      rendered.classList.toggle('hide', which !== 'doc');
      rawsrc.classList.toggle('hide',   which !== 'raw');
      imgview.classList.toggle('hide',  which !== 'img');
    }
    function setActive(btn){ if(activeBtn) activeBtn.classList.remove('active'); activeBtn = btn; if(btn) btn.classList.add('active'); }
    function basename(p){ return p.split('/').pop(); }
    function mkFile(label, title, onClick){
      var b = document.createElement('button');
      b.className = 'vfile'; b.type = 'button'; b.textContent = label; if(title) b.title = title;
      b.addEventListener('click', function(){ setActive(b); onClick(); });
      return b;
    }
    function mkGroup(label){ var d = document.createElement('div'); d.className = 'vgroup'; d.textContent = label; sidebar.appendChild(d); }

    function viewDoc(){ show('doc'); }
    function viewRaw(key){ show('raw'); rawsrc.textContent = (DOCMAP[key] != null ? DOCMAP[key] : '(unavailable)'); rawsrc.scrollTop = 0; }
    function viewImg(path){
      show('img'); imgview.innerHTML = '';
      var i = document.createElement('img'); i.src = encodeURI(path); i.alt = basename(path); i.loading = 'lazy';
      var c = document.createElement('div'); c.className = 'cap'; c.textContent = basename(path);
      imgview.appendChild(i); imgview.appendChild(c);
    }

    // Build the file navigator.
    var docBtn = mkFile('\uD83D\uDCD6  Rendered document', 'The full generated document', viewDoc);
    sidebar.appendChild(docBtn); setActive(docBtn);
    mkGroup('Source files (' + DOCFILES.length + ')');
    DOCFILES.forEach(function(f){
      var isMain = (f.key === MAINKEY);
      sidebar.appendChild(mkFile((isMain ? '\u2605  ' : '') + f.key, f.path, function(){ viewRaw(f.key); }));
    });
    if (IMGFILES.length){
      mkGroup('Images (' + IMGFILES.length + ')');
      IMGFILES.forEach(function(p){ sidebar.appendChild(mkFile(basename(p), p, function(){ viewImg(p); })); });
    }

    function fetchText(url){ return fetch(encodeURI(url)).then(function(r){ if(!r.ok) throw new Error('HTTP '+r.status); return r.text(); }); }

    // Fetch every source file, then render the main document with an include-processor.
    Promise.all(DOCFILES.map(function(f){
      return fetchText(f.path).then(function(t){ DOCMAP[f.key] = t; }).catch(function(){ DOCMAP[f.key] = ''; });
    })).then(function(){
      var main = DOCMAP[MAINKEY] || '';
      rawsrc.textContent = main;
      var s = document.createElement('script');
      s.src = 'https://cdn.jsdelivr.net/npm/@asciidoctor/core@2.2.6/dist/browser/asciidoctor.js';
      s.integrity = 'sha384-sfmkIywMu6zzFP/nd8/OECbZxHtZhbc+AihuuveRHvvgXnadNUiWzFXMCD+lBU+6';
      s.crossOrigin = 'anonymous';
      s.onload = function(){
        try{
          var factory = window.Asciidoctor;
          var ad = (typeof factory === 'function') ? factory() : factory;
          var reg = ad.Extensions.create();
          reg.includeProcessor(function(){
            this.handles(function(){ return true; });
            this.process(function(doc, reader, target, attrs){
              var content = DOCMAP[target];
              if (content == null) content = 'NOTE: include not found: ' + target;
              return reader.pushInclude(content, target, target, 1, attrs);
            });
          });
          var htmlOut = ad.convert(main, {standalone:false, safe:'safe', backend:'html5',
            extension_registry: reg,
            attributes:{showtitle:true, 'imagesdir':IMAGESDIR, icons:'font', sectanchors:true, 'source-highlighter':null}});
          rendered.innerHTML = htmlOut;
          if (note) note.textContent = '';
        }catch(e){ rendered.classList.add('hide'); show('raw'); if(note) note.textContent = 'Showing raw source (render failed).'; }
      };
      s.onerror = function(){ rendered.classList.add('hide'); show('raw'); if(note) note.textContent = 'Showing raw source (renderer offline).'; };
      document.head.appendChild(s);
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
        main_rel, doc_dir, main_key, doc_manifest, img_manifest, images_dir = _doc_viewer_data(
            report_dir, rel_files, primary_path)
        doc_section = DOC_ADOC.replace("__MAINADOC__", html.escape(main_rel))
        doc_script = (ADOC_SCRIPT
                      .replace("__MAINKEY__", main_key.replace('"', '\\"'))
                      .replace("__IMAGESDIR__", images_dir.replace('"', '\\"'))
                      .replace("__DOCFILES__", json.dumps(doc_manifest))
                      .replace("__IMGFILES__", json.dumps(img_manifest)))
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
