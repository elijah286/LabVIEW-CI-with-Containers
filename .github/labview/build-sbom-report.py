#!/usr/bin/env python3
"""
build-sbom-report.py — Generates a friendly, navigable Software Bill of Materials (SBOM) 
report for LabVIEW continuous integration workflows.

INPUTS
    --sbom <file>     Path to an SPDX-compliant sbom.json file.
                      Default: search inside --results directory for sbom.json.
    --results <dir>   Directory containing sbom.json (and optional _tooling.json).

OUTPUTS
    <out>/index.html  The deployed HTML report (viewable on dashboard).
    <out>/results.json The unified model output.
"""
from __future__ import annotations

import argparse
import html
import json
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote


# ── SBOM Parsing & Processing ────────────────────────────────────────────────
def _supplier_from_purl(purl: str) -> str:
    purl = str(purl or "")
    if purl.startswith("pkg:nipkg/"):
        return "NIPM"
    if purl.startswith("pkg:vipm/"):
        return "VIPM"
    return ""


def _supplier_name(value) -> str:
    if isinstance(value, dict):
        return str(value.get("name") or value.get("Name") or "")
    return str(value or "")


def parse_sbom(sbom_path: Path) -> dict:
  """Parse a CycloneDX or SPDX JSON file into a list of standardized package dictionaries."""
  if not sbom_path.exists():
    return {"spdx_version": "Unknown", "packages": [], "created": ""}

  try:
    data = json.loads(sbom_path.read_text(encoding="utf-8-sig"))
  except Exception as e:
    return {
      "spdx_version": "Unknown",
      "packages": [],
      "created": "",
      "parse_error": str(e),
    }

  raw_packages = data.get("components", []) or data.get("packages", [])
  packages = []
  for pkg in raw_packages:
    if isinstance(pkg, dict):
      vendor = (
        _supplier_name(pkg.get("supplier"))
        or _supplier_name(pkg.get("Supplier"))
        or str(pkg.get("Vendor") or pkg.get("vendor") or "")
        or str(pkg.get("publisher") or pkg.get("Publisher") or "")
        or _supplier_from_purl(pkg.get("purl") or pkg.get("PURL"))
        or "N/A"
      )
      packages.append({
        "name": str(pkg.get("Name") or pkg.get("name") or "Unknown Package"),
        "version": str(pkg.get("Version") or pkg.get("version") or "Unknown"),
        "vendor": str(vendor),
      })

  return {
    "spdx_version": (
      f"CycloneDX {data.get('specVersion', 'Unknown')}"
      if data.get("bomFormat") == "CycloneDX"
      else data.get("spdxVersion", "SPDX-2.3")
    ),
    "created": data.get("created", ""),
    "packages": packages,
  }


def clean(text: str) -> str:
    return (text or "").strip()


# ── Assemble Model ───────────────────────────────────────────────────────────
def build_data(args) -> dict:
    sbom_file = None
    if args.sbom:
        sbom_file = Path(args.sbom)
    elif args.results:
        candidate = Path(args.results) / "sbom.json"
        if candidate.exists():
            sbom_file = candidate

    sbom_data = parse_sbom(sbom_file) if sbom_file else {"spdx_version": "Unknown", "packages": []}
    packages = sbom_data.get("packages", [])

    meta_extra = {}
    if args.meta and Path(args.meta).exists():
        try:
            meta_extra = json.loads(Path(args.meta).read_text(encoding="utf-8-sig"))
        except Exception:
            meta_extra = {}

    if args.platform == "windows":
        platforms = [{"id": "windows", "url": None}, {"id": "linux", "url": "linux/results.json"}]
        snap_depth = "../../"
    else:
        platforms = [{"id": "windows", "url": "../results.json"}, {"id": "linux", "url": None}]
        snap_depth = "../../../"

    tooling = {}
    res_dir = Path(args.results) if args.results else None
    if res_dir and (res_dir / "_tooling.json").exists():
        try:
            tooling = json.loads((res_dir / "_tooling.json").read_text(encoding="utf-8-sig"))
        except Exception:
            tooling = {}
    if not isinstance(tooling, dict):
        tooling = {}
    
    _miss = tooling.get("missing")
    tooling["missing"] = [_miss] if isinstance(_miss, dict) else (_miss or [])

    pages_url = (args.pages_url or "").rstrip("/")
    return {
        "meta": {
            "sha": args.sha,
            "short": (args.sha or "")[:7],
            "platform": args.platform,
            "repo": args.repo,
            "pages_url": pages_url,
            "dash_url": (pages_url + "/") if pages_url else snap_depth,
            "labview_version": args.labview_version or meta_extra.get("labview_version", ""),
            "commit": {"message": args.commit_msg, "author": args.author, "date": args.date},
            "generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
            "spdx_version": sbom_data.get("spdx_version", "SPDX-2.3"),
            "created": sbom_data.get("created", ""),
        },
        "summary": {
            "total_packages": len(packages),
        },
        "platforms": platforms,
        "packages": packages,
        "tooling": tooling,
    }


# ── Renderer ─────────────────────────────────────────────────────────────────
def _esc(s) -> str:
    return html.escape(str(s if s is not None else ""), quote=True)


def tooling_banner_html(missing: list, configure_url: str) -> str:
    if isinstance(missing, dict):
        missing = [missing]
    miss = [x for x in (missing or []) if isinstance(x, dict) and (x.get("kind") in (None, "", "missing-tooling"))]
    if not miss:
        return ""
    names = ", ".join(_esc(x.get("name") or x.get("tool") or "") for x in miss if (x.get("name") or x.get("tool")))
    detail = next((x.get("detail") for x in miss if x.get("detail")), "")
    detail_html = f'<div class="lvci-needtool-d">{_esc(detail)}</div>' if detail else ""
    cta = (f'<a class="lvci-needtool-cta" href="{_esc(configure_url)}" target="_top" rel="noopener">'
           'Set up the container</a>') if configure_url else ""
    return (
        '<div class="lvci-needtool" role="alert">'
        '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
        'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
        '<path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/>'
        '<line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>'
        '<div class="lvci-needtool-t"><strong>This activity could not run.</strong>'
        'The selected container did not contain the dependencies needed to generate an SBOM'
        f'{(" (" + names + ")") if names else ""}. '
        'Set up the container to add the required tooling, then re-run.'
        f'{detail_html}</div>'
        f'{cta}</div>'
    )


def render(data: dict) -> str:
    blob = json.dumps(data, ensure_ascii=False)
    blob = blob.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    m = data.get("meta", {}) or {}
    pages = (m.get("pages_url") or "").rstrip("/")
    is_linux = m.get("platform") == "linux"
    hdr_src = "../../../lvci-header.js" if is_linux else "../../lvci-header.js"
    hdr_cfg = {
        "context": "sbom-report",
        "repo": m.get("repo", ""),
        "pagesUrl": pages or ("../../.." if is_linux else "../.."),
        "sha": m.get("sha", ""),
        "short": m.get("short", ""),
        "platform": m.get("platform", "windows"),
    }
    dash = m.get("dash_url") or ""
    repo = m.get("repo") or ""
    cfg_url = (dash or "") + "configure.html" + ("?repo=" + quote(repo, safe="") if repo else "")
    banner = tooling_banner_html((data.get("tooling") or {}).get("missing") or [], cfg_url)

    out = _TEMPLATE.replace("__SBOM_DATA_JSON__", blob)
    out = out.replace("__SBOM_HEADER_CFG__", json.dumps(hdr_cfg, ensure_ascii=False))
    out = out.replace("__LVCI_HEADER_SRC__", hdr_src)
    out = out.replace("__SBOM_TOOLING_BANNER__", banner)
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Build an SBOM report from SPDX sbom.json.")
    ap.add_argument("--sbom", default="", help="Path to sbom.json file")
    ap.add_argument("--results", default="", help="Directory containing sbom.json")
    ap.add_argument("--out", required=True, help="Output directory")
    ap.add_argument("--platform", default="windows", choices=["windows", "linux"])
    ap.add_argument("--meta", default="", help="meta.json metadata file")
    ap.add_argument("--sha", default="")
    ap.add_argument("--repo", default="")
    ap.add_argument("--pages-url", dest="pages_url", default="")
    ap.add_argument("--commit-msg", dest="commit_msg", default="")
    ap.add_argument("--author", default="")
    ap.add_argument("--date", default="")
    ap.add_argument("--labview-version", dest="labview_version", default="")
    args = ap.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    data = build_data(args)
    (out_dir / "results.json").write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    (out_dir / "index.html").write_text(render(data), encoding="utf-8")
    s = data["summary"]
    print(f"SBOM report: {s['total_packages']} package(s) documented -> {out_dir / 'index.html'}")


# ── HTML Template ────────────────────────────────────────────────────────────
_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Software Bill of Materials (SBOM) — LabVIEW CI</title>
<script>window.LVCI = __SBOM_HEADER_CFG__;</script>
<script src="__LVCI_HEADER_SRC__" defer></script>
<style>
:root{--bg:#0d1117;--surface:#161b22;--surface2:#0d1117;--border:#30363d;--fg:#e6edf3;--muted:#8b949e;--link:#58a6ff;--code:#010409}
@media(prefers-color-scheme:light){:root{--bg:#fff;--surface:#f6f8fa;--surface2:#fff;--border:#d0d7de;--fg:#1f2328;--muted:#57606a;--link:#0969da;--code:#f6f8fa}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;line-height:1.5}
.wrap{max-width:1040px;margin:0 auto;padding:20px 18px 64px}
h1{font-size:1.45em;margin:0 0 2px}
.sub{color:var(--muted);font-size:.86em;margin:2px 0 16px}
.cards{display:flex;gap:10px;flex-wrap:wrap;margin:14px 0}
.card{flex:1 1 120px;min-width:110px;background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:12px 14px}
.card .n{font-size:1.6em;font-weight:700;line-height:1}
.card .l{color:var(--muted);font-size:.78em;margin-top:3px}
.toolbar{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin:6px 0 14px}
.toolbar input[type=search]{flex:1 1 220px;min-width:180px;padding:8px 10px;background:var(--surface2);color:var(--fg);border:1px solid var(--border);border-radius:7px;font-size:.9em}
.count{color:var(--muted);font-size:.8em;margin-left:auto}
.plat{display:inline-flex;border:1px solid var(--border);border-radius:7px;overflow:hidden;margin-left:8px;vertical-align:middle}
.plat button{background:transparent;color:var(--muted);border:0;padding:4px 11px;font-size:.8em;cursor:pointer}
.plat button.active{background:rgba(177,186,196,.16);color:var(--fg)}
.plat button[disabled]{opacity:.4;cursor:default}
.table-container{border:1px solid var(--border);border-radius:10px;overflow:hidden;background:var(--surface)}
table{width:100%;border-collapse:collapse;text-align:left;font-size:.88em}
th,td{padding:10px 14px;border-bottom:1px solid var(--border)}
tr:last-child td{border-bottom:0}
th{background:var(--surface2);color:var(--muted);font-weight:600}
.pkg-name{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-weight:600}
.empty{color:var(--muted);text-align:center;padding:40px 0}
.hidden{display:none!important}
.lvci-needtool{display:flex;align-items:flex-start;gap:12px;max-width:1040px;margin:16px auto 0;padding:13px 16px;background:rgba(187,128,9,.13);border:1px solid rgba(187,128,9,.45);border-left:4px solid #bb8009;border-radius:10px}
.lvci-needtool svg{flex:0 0 auto;width:20px;height:20px;color:#bb8009;margin-top:1px}
.lvci-needtool-t{flex:1 1 auto;font-size:.9em}
.lvci-needtool-t strong{display:block;margin-bottom:2px}
.lvci-needtool-d{color:var(--muted);font-size:.92em;margin-top:5px}
.lvci-needtool-cta{flex:0 0 auto;align-self:center;font-size:.85em;font-weight:600;color:#fff;background:#bb8009;border-radius:7px;padding:8px 13px;text-decoration:none;white-space:nowrap}
</style>
</head>
<body>
__SBOM_TOOLING_BANNER__
<div class="wrap">
  <h1>Software Bill of Materials (SBOM) <span class="plat" id="plat-toggle"></span></h1>
  <div class="sub" id="sub"></div>

  <div class="cards" id="cards"></div>

  <div class="toolbar">
    <input id="q" type="search" placeholder="Filter packages by name or vendor…">
    <span class="count" id="rescount"></span>
  </div>

  <div class="table-container">
    <table>
      <thead>
        <tr>
          <th>Package Name</th>
          <th>Version</th>
          <th>Vendor / Supplier</th>
        </tr>
      </thead>
      <tbody id="pkg-list"></tbody>
    </table>
  </div>
</div>

<script id="sbom-data" type="application/json">__SBOM_DATA_JSON__</script>
<script>
const SELF = JSON.parse(document.getElementById('sbom-data').textContent);
const PLATFORMS = SELF.platforms || [{id:SELF.meta.platform,url:null}];
const SELF_PLATFORM = SELF.meta.platform;
const CACHE = { [SELF_PLATFORM]: SELF };
let CUR = SELF_PLATFORM, D = SELF;
const META = SELF.meta;
const esc = s => String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const PLAT_LABEL = {windows:'Windows', linux:'Linux'};
let query='';

(function header(){
  const m = META;
  const commitMsg = (m.commit && m.commit.message) ? esc(m.commit.message) : '';
  const shaLink = m.repo && m.sha ? `https://github.com/${m.repo}/commit/${m.sha}` : '';
  document.getElementById('sub').innerHTML =
    (m.short ? `Commit ${shaLink?`<a href="${shaLink}" target="_top">${esc(m.short)}</a>`:esc(m.short)} ` : '') +
    (commitMsg ? `&middot; ${commitMsg} ` : '') +
    (m.spdx_version ? `&middot; ${esc(m.spdx_version)} ` : '') +
    `&middot; generated ${esc(m.generated_utc||'')}`;
})();

function renderToggle(){
  const host = document.getElementById('plat-toggle');
  host.innerHTML = PLATFORMS.map(p=>{
    const dis = (p.id!==SELF_PLATFORM && p.url==null) ? 'disabled' : '';
    return `<button data-plat="${p.id}" class="${p.id===CUR?'active':''}" ${dis}>${esc(PLAT_LABEL[p.id]||p.id)}</button>`;
  }).join('');
  host.querySelectorAll('button').forEach(b=>b.addEventListener('click',()=>switchPlatform(b.dataset.plat)));
}

async function switchPlatform(pid){
  if(pid===CUR) return;
  const p = PLATFORMS.find(x=>x.id===pid); if(!p) return;
  let data = CACHE[pid];
  if(data===undefined){
    try{ data = await fetch(p.url).then(r=>r.json()); }catch(e){ data = null; }
    CACHE[pid] = data;
  }
  CUR = pid;
  if(!data){ renderToggle(); showEmpty(pid); return; }
  D = data; renderToggle(); renderAll();
}

function showEmpty(pid){
  document.getElementById('cards').innerHTML='';
  document.getElementById('pkg-list').innerHTML=`<tr><td colspan="3" class="empty">No SBOM available for ${esc(PLAT_LABEL[pid]||pid)}.</td></tr>`;
  document.getElementById('rescount').textContent='';
}

function renderAll(){
  const s = D.summary;
  document.getElementById('cards').innerHTML = `<div class="card"><div class="n">${(s.total_packages||0).toLocaleString()}</div><div class="l">Packages</div></div>`;
  renderPackages();
  apply();
}

function renderPackages(){
  const host = document.getElementById('pkg-list');
  if(!D.packages || !D.packages.length){
    host.innerHTML = `<tr><td colspan="3" class="empty">No packages found in SBOM.</td></tr>`;
    return;
  }
  host.innerHTML = D.packages.map(p => {
    const hay = (p.name + ' ' + p.vendor + ' ' + p.version).toLowerCase();
    return `<tr class="pkg-row" data-text="${esc(hay)}">
      <td class="pkg-name">${esc(p.name)}</td>
      <td>${esc(p.version)}</td>
      <td>${esc(p.vendor)}</td>
    </tr>`;
  }).join('');
}

function apply(){
  let vis = 0;
  document.querySelectorAll('#pkg-list .pkg-row').forEach(row => {
    const show = !query || row.dataset.text.includes(query);
    row.classList.toggle('hidden', !show);
    if(show) vis++;
  });
  document.getElementById('rescount').textContent = `${vis} package${vis===1?'':'s'} shown`;
}

document.getElementById('q').addEventListener('input', e => {
  query = e.target.value.trim().toLowerCase();
  apply();
});

renderToggle();
renderAll();
</script>
</body>
</html>
"""

if __name__ == "__main__":
    main()