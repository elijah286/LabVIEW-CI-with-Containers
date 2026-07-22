#!/usr/bin/env bash
# =============================================================================
# build-binaries.sh - Executes LabVIEW build specifications in a Linux container
# =============================================================================
# Linux counterpart of build-binaries.ps1. For every build specification found in
# the project's .lvproj files it invokes the built-in
# 'LabVIEWCLI -OperationName ExecuteBuildSpec' operation, stages the built
# artifacts into ci-out/builds/dist/ with SHA-256 checksums and a provenance
# manifest, and writes summary.json + a fallback index.html.
#
# ExecuteBuildSpec is build-type agnostic. This runner is platform-aware only for
# OS gating: Installer and .NET Interop Assembly specifications are Windows-only,
# so on Linux they are skipped (recorded 'skipped', never failed).
#
# Usage (inside container, workspace mounted at /workspace):
#   bash /workspace/.github/labview/build-binaries.sh /workspace /workspace/ci-out/builds
# =============================================================================
set -uo pipefail

WORKSPACE_ROOT="${1:-/workspace}"
REPORT_DIR="${2:-/report}"
PROJECTS="${3:-}"

mkdir -p "$REPORT_DIR/dist"

# LabVIEWCLI is on PATH in the NI Linux container; the LabVIEW executable year
# varies by image tag (mirrors masscompile.sh).
LABVIEWCLI="${LABVIEWCLI:-LabVIEWCLI}"
LABVIEW_EXE="$(find /usr/local/natinst -name 'labviewprofull' 2>/dev/null | head -1)"
if [ -z "$LABVIEW_EXE" ]; then
  echo "ERROR: labviewprofull not found in /usr/local/natinst" >&2
  exit 1
fi
LABVIEW_VERSION="$(printf '%s' "$LABVIEW_EXE" | grep -oE '20[0-9]{2}' | head -1)"
LABVIEW_VERSION="${LABVIEW_VERSION:-2026}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required by build-binaries.sh but was not found in the container." >&2
  echo "       Add python3 to the Linux worker image (labview-ci.Dockerfile-linux)." >&2
  exit 1
fi

echo "=== Build LabVIEW binaries (Linux) ==="
echo "  Workspace : $WORKSPACE_ROOT"
echo "  LabVIEW   : $LABVIEW_EXE"
echo "  CLI       : $LABVIEWCLI"
echo ""

export WORKSPACE_ROOT REPORT_DIR PROJECTS LABVIEWCLI LABVIEW_EXE LABVIEW_VERSION

# The parse-enumerate-build loop, JSON assembly and checksums run in python3 for
# robustness (XML parsing + JSON escaping in bash is fragile). LabVIEWCLI is
# invoked per spec via subprocess. Success is judged by the CLI exit code.
python3 - <<'PY'
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

workspace = Path(os.environ["WORKSPACE_ROOT"]).resolve()
report_dir = Path(os.environ["REPORT_DIR"]).resolve()
dist_dir = report_dir / "dist"
dist_dir.mkdir(parents=True, exist_ok=True)
cli = os.environ.get("LABVIEWCLI", "LabVIEWCLI")
lv_exe = os.environ.get("LABVIEW_EXE", "")
lv_version = os.environ.get("LABVIEW_VERSION", "2026")
projects_arg = os.environ.get("PROJECTS", "").strip()

# Installer / .NET Interop are Windows-only build spec types.
WINDOWS_ONLY = re.compile(r"installer|\.net|interop", re.IGNORECASE)

TOOLING_DIR = re.compile(r"(^|/)(\.github|actions|ci-out|build)/")


def slug(s):
    s = re.sub(r"[^A-Za-z0-9._-]+", "-", s or "").strip("-")
    return s or "unnamed"


def sha256(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return ""


def strip_ns(tag):
    return tag.split("}", 1)[-1] if "}" in tag else tag


def load_builds_selection(ws):
    """Read config.builds from .github/labview-ci.yml -> (run_all, {key: os-set}).
    key = '<project-rel-forward-slash>::<spec name>'. When run_all is True (default
    or no config) every discovered spec builds on every supported platform."""
    cfg = ws / ".github" / "labview-ci.yml"
    if not cfg.is_file():
        return True, {}
    run_all = True
    sel = {}
    in_builds = in_specs = saw = False
    try:
        lines = cfg.read_text(encoding="utf-8").splitlines()
    except OSError:
        return True, {}
    for line in lines:
        if re.match(r"^\s{2}builds:\s*$", line):
            in_builds = True
            continue
        if in_builds:
            if re.match(r"^\s{0,1}\S", line):
                break
            m = re.match(r"^\s{4}runAll:\s*(true|false)", line)
            if m:
                run_all = m.group(1) == "true"
                in_specs = saw = True
                continue
            if re.match(r"^\s{4}specs:\s*$", line):
                in_specs = saw = True
                continue
            if in_specs:
                m = re.match(r'^\s{6}-\s*"?([^"]+?)"?\s*$', line)
                if m:
                    parts = m.group(1).split("::")
                    if len(parts) >= 3:
                        os_set = set() if parts[2] == "none" else set(parts[2].split("+"))
                        sel[parts[0] + "::" + parts[1]] = os_set
                    saw = True
    return (run_all if saw else True), sel


def find_build_specs(proj_path):
    """Return build specs declared in a .lvproj: name/type/target/destDir."""
    specs = []
    try:
        tree = ET.parse(proj_path)
    except ET.ParseError:
        print("  Could not parse project XML: %s" % proj_path, file=sys.stderr)
        return specs
    root = tree.getroot()
    proj_dir = Path(proj_path).parent

    # Walk items, tracking the enclosing target name and Build-Specifications node.
    def walk(node, target_name):
        for child in list(node):
            if strip_ns(child.tag) != "Item":
                continue
            ctype = child.get("Type", "")
            cname = child.get("Name", "")
            if ctype == "Build":
                # Children of the Build Specifications item are the specs; the
                # current target_name applies to them.
                for spec in list(child):
                    if strip_ns(spec.tag) != "Item":
                        continue
                    sname = spec.get("Name", "")
                    stype = spec.get("Type", "")
                    if not sname:
                        continue
                    dest = ""
                    for prop in spec.findall("./Property") + spec.findall(
                        "./{*}Property"
                    ):
                        if prop.get("Name") == "Bld_localDestDir":
                            raw = (prop.text or "").strip()
                            if raw:
                                # Expand LabVIEW build tokens: NI_AB_PROJECTNAME ->
                                # project name, NI_AB_TARGETNAME -> target name, so
                                # the collected dir matches where LabVIEW wrote.
                                proj_name = Path(proj_path).stem
                                raw = raw.replace(
                                    "NI_AB_PROJECTNAME", proj_name
                                ).replace("NI_AB_TARGETNAME", target_name)
                                p = Path(raw)
                                dest = str(
                                    p if p.is_absolute() else (proj_dir / raw).resolve()
                                )
                            break
                    specs.append(
                        {
                            "name": sname,
                            "type": stype,
                            "target": target_name,
                            "destDir": dest,
                        }
                    )
            else:
                # A target (e.g. "My Computer") or nested virtual folder; recurse.
                nt = cname if ctype == "" or ctype not in ("VI",) else target_name
                walk(child, nt or target_name)

    walk(root, "My Computer")
    return specs


# Discover projects.
if projects_arg:
    project_files = []
    for p in projects_arg.split(";"):
        p = p.strip()
        if not p:
            continue
        full = Path(p) if os.path.isabs(p) else workspace / p
        if full.exists():
            project_files.append(str(full.resolve()))
        else:
            print("  Configured project not found: %s" % p, file=sys.stderr)
else:
    project_files = [
        str(p)
        for p in workspace.rglob("*.lvproj")
        if not TOOLING_DIR.search(str(p).replace("\\", "/"))
    ]

log_lines = []
spec_results = []
start = time.time()
run_all_cfg, builds_sel = load_builds_selection(workspace)

for proj in project_files:
    proj_rel = os.path.relpath(proj, workspace)
    specs = find_build_specs(proj)
    if not specs:
        log_lines.append("Project has no build specifications: %s" % proj_rel)
        continue
    for spec in specs:
        # Honor the Builds config: when not building all, skip specs the user did
        # not select for this (Linux) platform.
        if not run_all_cfg:
            allowed = builds_sel.get(proj_rel.replace(os.sep, "/") + "::" + spec["name"])
            if not allowed or "linux" not in allowed:
                continue
        spec_start = time.time()
        result = {
            "project": proj_rel,
            "name": spec["name"],
            "type": spec["type"],
            "target": spec["target"],
            "status": "built",
            "outputs": [],
            "message": "",
            "duration": 0,
        }
        if WINDOWS_ONLY.search(spec["type"] or ""):
            result["status"] = "skipped"
            result["message"] = "%s build specifications only build on Windows." % (
                spec["type"] or "This"
            )
            result["duration"] = round(time.time() - spec_start, 1)
            log_lines.append(
                "=== SKIP '%s' [%s] (Windows-only) in %s ==="
                % (spec["name"], spec["type"], proj_rel)
            )
            print("--- Skipping '%s' [%s] (Windows-only) ---" % (spec["name"], spec["type"]))
            spec_results.append(result)
            continue

        print(
            "--- Building '%s' [%s] target '%s' in %s ---"
            % (spec["name"], spec["type"], spec["target"], proj_rel)
        )
        log_lines.append(
            "=== ExecuteBuildSpec '%s' [%s] target '%s' in %s ==="
            % (spec["name"], spec["type"], spec["target"], proj_rel)
        )
        cmd = [
            cli,
            "-LogToConsole", "TRUE",
            "-OperationName", "ExecuteBuildSpec",
            "-ProjectPath", proj,
            "-TargetName", spec["target"],
            "-BuildSpecName", spec["name"],
            "-LabVIEWPath", lv_exe,
        ]
        try:
            proc = subprocess.run(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
            )
            log_lines.append(proc.stdout or "")
            exit_code = proc.returncode
        except OSError as exc:
            log_lines.append("Failed to launch LabVIEWCLI: %s" % exc)
            exit_code = 1

        if exit_code != 0:
            result["status"] = "failed"
            result["message"] = "ExecuteBuildSpec exited %d" % exit_code
            print("  FAILED (exit %d)" % exit_code)
        else:
            stage = dist_dir / slug(proj_rel) / slug(spec["name"])
            stage.mkdir(parents=True, exist_ok=True)
            collected = []
            src = spec["destDir"]
            if src and os.path.isdir(src):
                src_path = Path(src)
                for f in src_path.rglob("*"):
                    if not f.is_file():
                        continue
                    rel = f.relative_to(src_path)
                    target = stage / rel
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(f.read_bytes())
                    collected.append(
                        {
                            "file": str(rel).replace("\\", "/"),
                            "size": target.stat().st_size,
                            "sha256": sha256(target),
                        }
                    )
            result["outputs"] = collected
            if not collected:
                result["message"] = (
                    "Built, but no output files were located (destination dir: '%s')."
                    % src
                )
                print("  BUILT (no output files located; verify Bld_localDestDir)")
            else:
                print("  BUILT (%d file(s))" % len(collected))
        result["duration"] = round(time.time() - spec_start, 1)
        spec_results.append(result)

duration = round(time.time() - start, 1)
total = len(spec_results)
built = sum(1 for r in spec_results if r["status"] == "built")
failed = sum(1 for r in spec_results if r["status"] == "failed")
skipped = sum(1 for r in spec_results if r["status"] == "skipped")

if total <= 0:
    status = "passed"
elif failed > 0:
    status = "failed"
elif skipped > 0:
    status = "partial"
else:
    status = "passed"

log_text = "\n".join(log_lines) or "(no build specifications found)"
(report_dir / "builds.log").write_text(log_text, encoding="utf-8")

summary = {
    "platform": "linux",
    "status": status,
    "total": total,
    "built": built,
    "skipped": skipped,
    "failed": failed,
    "duration": duration,
    "labview_version": lv_version,
    "specs": spec_results,
}
(report_dir / "summary.json").write_text(
    json.dumps(summary, separators=(",", ":")), encoding="utf-8"
)

manifest = {
    "repo": os.environ.get("GITHUB_REPOSITORY", ""),
    "sha": os.environ.get("GITHUB_SHA", ""),
    "ref": os.environ.get("GITHUB_REF", ""),
    "platform": "linux",
    "arch": os.uname().machine if hasattr(os, "uname") else "",
    "labview_version": lv_version,
    "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "specs": spec_results,
}
(dist_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

# Fallback HTML report (build-binaries-report.py overwrites this on the runner).
color = {"passed": "#2ea043", "failed": "#da3633"}.get(status, "#bb8009")
log_html = (
    log_text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
)
repo = os.environ.get("GITHUB_REPOSITORY", "")
sha = os.environ.get("GITHUB_SHA", "")
short = sha[:7]
ts = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())
html = (
    "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\">"
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    "<title>Builds (Linux) - LabVIEW-CI-with-Containers</title>"
    "<script>window.LVCI={context:'builds-report',repo:'%s',pagesUrl:'../../..',sha:'%s',short:'%s',platform:'linux',rawUrl:'builds.log'};</script>"
    "<script src=\"../../../lvci-header.js\" defer></script>"
    "<style>:root{--bg:#0d1117;--surface:#161b22;--border:#30363d;--fg:#e6edf3;--fg-muted:#8b949e}"
    "@media(prefers-color-scheme:light){:root{--bg:#fff;--surface:#f6f8fa;--border:#d0d7de;--fg:#1f2328;--fg-muted:#57606a}}"
    "body{margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--fg)}"
    ".wrap{max-width:1180px;margin:0 auto;padding:20px}"
    ".badge{display:inline-block;padding:3px 10px;border-radius:4px;font-weight:700;font-size:.85em;color:#fff;background:%s}"
    "pre{background:var(--surface);border:1px solid var(--border);border-radius:6px;padding:14px;font-size:.75em;white-space:pre-wrap;word-break:break-all}</style>"
    "</head><body><div class=\"wrap\"><h1>Builds (Linux)</h1><span class=\"badge\">%s</span>"
    "<p style=\"color:var(--fg-muted);font-size:.82em\">Date: %s &middot; %d built &middot; %d skipped &middot; %d failed of %d</p>"
    "<pre>%s</pre></div></body></html>"
) % (repo, sha, short, color, status, ts, built, skipped, failed, total, log_html)
(report_dir / "index.html").write_text(html, encoding="utf-8")

print("")
print(
    "=== Build finished (status=%s: %d built, %d skipped, %d failed of %d; duration=%ss) ==="
    % (status, built, skipped, failed, total, duration)
)

sys.exit(1 if status == "failed" else 0)
PY
