#!/usr/bin/env python3
"""
install.py - Install LabVIEW CI capabilities into a target repository.

This is the catalog-driven installer that powers the "Integrate this CI pipeline"
button on the dashboard. It is invoked by install.sh / install.ps1 (which fetch
the tooling and locate Python), or directly:

    python3 .github/labview-ci/install.py --activities masscompile,vi-analyzer,dashboard \
                                          --os windows,linux --labview-version 2026

What it does
  1. Reads the capability catalog (.github/labview-ci/catalog.json) from the
     tooling SOURCE (the directory this script lives in, or --source).
  2. Resolves the file set for the selected activities x operating systems,
     plus their hard `requires`, plus the always-installed base files.
  3. Copies those files into the TARGET repo (cwd, or --target), creating dirs.
  4. Rewrites cosmetic branding (the source project name / owner / Pages host)
     to the target repo's identifiers in copied text files. Functional wiring
     (image name, Pages URL, LabVIEW version) is NOT rewritten - it already
     derives at runtime from the GitHub context and Actions variables.
  5. Writes a manifest (.github/labview-ci.yml) recording what was installed.
  6. Prints the remaining manual steps (enable Pages, set permissions/variables).

Nothing here runs LabVIEW, pushes commits, or mutates the remote: it only writes
files into the working tree, so the result is easy to review with `git diff`.

Dependencies: Python 3.8+ standard library only.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# File extensions treated as text for branding substitution. Anything else
# (LabVIEW binaries, images, archives) is copied byte-for-byte.
TEXT_EXTS = {
    ".yml", ".yaml", ".ps1", ".sh", ".py", ".html", ".htm", ".md", ".json",
    ".xml", ".viancfg", ".txt", ".cfg", ".css", ".js", ".svg",
}

# The installer's own tooling directory is never rebranded: it must keep pointing
# at the tooling SOURCE repo (catalog.source) so re-runs / upgrades still work.
NO_SUBSTITUTION_PREFIX = ".github/labview-ci/"
DEFAULT_EXCLUDED_STATUSES = {"planned", "experimental"}
GITHUB_WORKFLOW_PREFIX = ".github/workflows/"


def log(msg: str = "") -> None:
    print(msg, flush=True)


def warn(msg: str) -> None:
    print(f"  ! {msg}", file=sys.stderr, flush=True)


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def parse_csv(value: str) -> list[str]:
    return [v.strip() for v in (value or "").split(",") if v.strip()]


def load_catalog(source_root: Path) -> dict:
    catalog_path = source_root / ".github" / "labview-ci" / "catalog.json"
    if not catalog_path.is_file():
        die(f"catalog not found at {catalog_path}. Use --source to point at the tooling checkout.")
    try:
        return json.loads(catalog_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        die(f"catalog.json is not valid JSON: {exc}")
    return {}  # unreachable


def detect_target_repo(target_root: Path, explicit: str | None) -> tuple[str | None, str | None]:
    """Return (owner, name) for the target repo, or (None, None) if unknown."""
    if explicit:
        if "/" in explicit:
            owner, name = explicit.split("/", 1)
            return owner, name
        warn(f"--repo '{explicit}' is not in owner/name form; ignoring.")
    # Try the git remote.
    try:
        url = subprocess.check_output(
            ["git", "-C", str(target_root), "remote", "get-url", "origin"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None, None
    # Handle both git@github.com:owner/name.git and https://github.com/owner/name(.git)
    m = re.search(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?$", url)
    if m:
        return m.group(1), m.group(2)
    return None, None


def read_manifest(target_root: Path):
    """Parse a previously-written .github/labview-ci.yml (our own simple format)."""
    p = target_root / ".github" / "labview-ci.yml"
    if not p.is_file():
        return None
    info = {"activities": [], "os": [], "labviewVersion": "", "installedVersion": ""}
    in_acts = False
    for line in p.read_text(encoding="utf-8").splitlines():
        if re.match(r"^\s*activities:\s*$", line):
            in_acts = True
            continue
        if in_acts:
            m = re.match(r"^\s*-\s*(\S+)", line)
            if m:
                info["activities"].append(m.group(1))
                continue
            in_acts = False
        m = re.match(r'^\s*labviewVersion:\s*"?([^"\s]+)"?', line)
        if m:
            info["labviewVersion"] = m.group(1)
        m = re.match(r"^\s*installedVersion:\s*(\S+)", line)
        if m:
            info["installedVersion"] = m.group(1)
        m = re.match(r"^\s*os:\s*\[([^\]]*)\]", line)
        if m:
            info["os"] = [x.strip() for x in m.group(1).split(",") if x.strip()]
    return info


def build_substitutions(catalog: dict, owner: str | None, name: str | None,
                        provider: str = "github") -> list[tuple[str, str]]:
    if not owner or not name:
        return []
    pages_host = f"{owner.lower()}.gitlab.io" if provider == "gitlab" else f"{owner.lower()}.github.io"
    tokens = {
        "pagesHost": pages_host,
        "ownerRepo": f"{owner}/{name}",
        "repoName": name,
    }
    subs: list[tuple[str, str]] = []
    for rule in catalog.get("substitutions", {}).get("ordered", []):
        find = rule["find"]
        replace = rule["replaceWith"].format(**tokens)
        if find != replace:
            subs.append((find, replace))
    return subs


def default_activities(catalog: dict) -> list[str]:
    return [
        c["id"] for c in catalog.get("capabilities", [])
        if c.get("recommended") and c.get("status", "stable") not in DEFAULT_EXCLUDED_STATUSES
    ]


def resolve_file_list(catalog: dict, activities: list[str], os_list: list[str]) -> list[str]:
    by_id = {c["id"]: c for c in catalog.get("capabilities", [])}

    # Expand hard requires (transitively).
    selected: list[str] = []
    stack = list(activities)
    while stack:
        cid = stack.pop(0)
        if cid in selected:
            continue
        cap = by_id.get(cid)
        if cap is None:
            warn(f"unknown activity '{cid}' - skipping.")
            continue
        if cap.get("status") == "planned":
            warn(f"activity '{cid}' is planned/not yet available - skipping.")
            continue
        selected.append(cid)
        for req in cap.get("requires", []):
            if req not in selected:
                stack.append(req)

    files: list[str] = list(catalog.get("base", {}).get("files", []))

    for cid in selected:
        cap = by_id[cid]
        supported = set(cap.get("supportsOs", []))
        cap_os = supported & set(os_list)
        files.extend(cap.get("files", {}).get("any", []))
        for osname in sorted(cap_os):
            files.extend(cap.get("files", {}).get(osname, []))
        if supported and not cap_os:
            warn(f"'{cid}' supports {sorted(supported)} but you selected {os_list}; "
                 f"only its shared files were installed.")

    # De-duplicate, preserve order.
    seen: set[str] = set()
    ordered: list[str] = []
    for f in files:
        if f not in seen:
            seen.add(f)
            ordered.append(f)
    return ordered


def should_substitute(rel_path: str) -> bool:
    if rel_path.replace("\\", "/").startswith(NO_SUBSTITUTION_PREFIX):
        return False
    return Path(rel_path).suffix.lower() in TEXT_EXTS


def apply_substitutions(text: str, subs: list[tuple[str, str]]) -> str:
    for find, replace in subs:
        text = text.replace(find, replace)
    return text


def copy_one(src: Path, dst: Path, rel_path: str, subs: list[tuple[str, str]],
             force: bool, dry_run: bool, stats: dict,
             preserve: set = frozenset(), update: bool = False) -> None:
    norm = rel_path.replace("\\", "/")
    # On update, never clobber the consumer's own config files.
    if update and norm in preserve and dst.exists():
        stats["preserved"] += 1
        log(f"  preserve (cfg)  {rel_path}")
        return
    existed = dst.exists()
    if existed and not force:
        stats["skipped"] += 1
        log(f"  skip (exists)   {rel_path}")
        return
    if dry_run:
        stats["planned"] += 1
        log(f"  would {'update ' if (update and existed) else 'install'}  {rel_path}")
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    if subs and should_substitute(rel_path):
        try:
            text = src.read_text(encoding="utf-8")
            dst.write_text(apply_substitutions(text, subs), encoding="utf-8")
        except UnicodeDecodeError:
            shutil.copy2(src, dst)
    else:
        shutil.copy2(src, dst)
    if update and existed:
        stats["updated"] += 1
        log(f"  update          {rel_path}")
    else:
        stats["installed"] += 1
        log(f"  install         {rel_path}")


def copy_entry(entry: str, source_root: Path, target_root: Path,
               subs: list[tuple[str, str]], force: bool, dry_run: bool, stats: dict,
               preserve: set = frozenset(), update: bool = False) -> None:
    is_dir = entry.endswith("/")
    src = source_root / entry
    if is_dir:
        if not src.is_dir():
            warn(f"missing source directory {entry} - skipping.")
            return
        for child in sorted(src.rglob("*")):
            if child.is_file():
                rel = child.relative_to(source_root).as_posix()
                copy_one(child, target_root / rel, rel, subs, force, dry_run, stats, preserve, update)
    else:
        if not src.is_file():
            warn(f"missing source file {entry} - skipping.")
            return
        copy_one(src, target_root / entry, entry, subs, force, dry_run, stats, preserve, update)


def write_manifest(target_root: Path, catalog: dict, activities: list[str], os_list: list[str],
                   labview_version: str, image_name: str | None, branch: str,
                   dry_run: bool, provider: str = "github") -> None:
    src = catalog.get("source", {})
    now = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines = [
        "# LabVIEW CI install manifest - generated by .github/labview-ci/install.py",
        "# Records what was installed so the install can be reviewed, re-run, or upgraded.",
        f"schemaVersion: {catalog.get('schemaVersion', 1)}",
        f"installedVersion: {catalog.get('version', '0.0.0')}",
        f"installedAt: {now}",
        f"provider: {provider}",
        "source:",
        f"  repo: {src.get('repo', '')}",
        # Pin to the EXACT published version (an immutable tag), never the source's
        # own ref ("main"). The dashboard caller awk-reads this `ref` to check out
        # the tooling at runtime, so a consumer's whole pipeline only changes when
        # they run "Update now" (which rewrites this line) — not whenever the source
        # repo's main advances.
        f"  ref: v{catalog.get('version', '0.0.0')}",
        "config:",
        f"  labviewVersion: \"{labview_version}\"",
        f"  branch: {branch}",
        f"  os: [{', '.join(os_list)}]",
    ]
    if image_name:
        lines.append(f"  imageName: {image_name}")
    lines.append("activities:")
    for a in activities:
        lines.append(f"  - {a}")
    content = "\n".join(lines) + "\n"
    dst = target_root / ".github" / "labview-ci.yml"
    if dry_run:
        log(f"  would write     .github/labview-ci.yml")
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(content, encoding="utf-8")
    log(f"  write           .github/labview-ci.yml")


def print_next_steps(catalog: dict, owner: str | None, name: str | None, activities: list[str],
                     labview_version: str, image_name: str | None, print_vars: bool) -> None:
    repo = f"{owner}/{name}" if owner and name else "<owner>/<repo>"
    log("")
    log("Next steps")
    log("  1. Review the changes:        git status && git diff")
    log("  2. Commit and push:           git add .github && git commit -m \"Add LabVIEW CI\" && git push")
    log("  3. Enable GitHub Pages from the 'gh-pages' branch (Settings > Pages).")
    log("  4. Allow Actions to write:    Settings > Actions > General >")
    log("       'Workflow permissions' -> Read and write permissions.")
    if print_vars:
        log("  5. (Optional) Pin configuration as Actions variables:")
        log(f"       gh variable set LABVIEW_VERSION  -R {repo} -b {labview_version}")
        if image_name:
            log(f"       gh variable set LABVIEW_IMAGE_NAME -R {repo} -b {image_name}")
        log("     (All variables have safe fallbacks, so this is optional.)")
    if "custom-image" in activities:
        log("  6. Run 'Build LabVIEW CI Image' once so the analyzer image exists.")
    log("")
    log("Done. Open a pull request that changes a VI to see the pipeline run.")


def gitlab_pages_url(owner: str | None, name: str | None) -> str:
    if not owner or not name:
        return "https://<namespace>.gitlab.io/<project>"
    return f"https://{owner.lower()}.gitlab.io/{name}"


def gitlab_root_ci() -> str:
    return (
        "# LabVIEW CI - GitLab entrypoint. Installed by .github/labview-ci/install.py.\n"
        "# The shared provider-specific jobs live under .gitlab/labview-ci/.\n"
        "include:\n"
        "  - local: '.gitlab/labview-ci/pipeline.yml'\n"
    )


def gitlab_pipeline_yml(branch: str) -> str:
    br = branch or "main"
    return (
        "# LabVIEW CI - GitLab pipeline scaffold.\n"
        "# This provider slice publishes dashboard assets to GitLab Pages.\n"
        "# Windows LabVIEW workers require a registered Windows Docker GitLab Runner.\n"
        "stages:\n"
        "  - dashboard\n"
        "  - pages\n\n"
        "variables:\n"
        "  LVCI_PROVIDER: gitlab\n"
        "  LVCI_TARGET_SHA: $CI_COMMIT_SHA\n\n"
        "lvci:dashboard:\n"
        "  stage: dashboard\n"
        "  image: python:3.12-alpine\n"
        "  rules:\n"
        f"    - if: '$CI_COMMIT_BRANCH == \"{br}\"'\n"
        "    - if: '$CI_PIPELINE_SOURCE == \"web\"'\n"
        "    - if: '$CI_PIPELINE_SOURCE == \"schedule\"'\n"
        "  script:\n"
        "    - python .gitlab/labview-ci/build-dashboard.py\n"
        "  artifacts:\n"
        "    paths:\n"
        "      - public\n"
        "    expire_in: 1 week\n\n"
        "pages:\n"
        "  stage: pages\n"
        "  needs:\n"
        "    - job: lvci:dashboard\n"
        "      artifacts: true\n"
        "  rules:\n"
        f"    - if: '$CI_COMMIT_BRANCH == \"{br}\"'\n"
        "    - if: '$CI_PIPELINE_SOURCE == \"web\"'\n"
        "  script:\n"
        "    - test -d public\n"
        "  artifacts:\n"
        "    paths:\n"
        "      - public\n"
    )


def gitlab_dashboard_builder(catalog: dict, owner: str | None, name: str | None) -> str:
    version = str(catalog.get("version", "0.0.0"))
    pages = gitlab_pages_url(owner, name)
    fallback_repo = (owner + "/" + name) if owner and name else "namespace/project"
    return f'''#!/usr/bin/env python3
"""Build the first GitLab-hosted LabVIEW CI dashboard payload."""

from __future__ import annotations

import html
import json
import os
import shutil
from pathlib import Path


ROOT = Path.cwd()
PUBLIC = ROOT / "public"
PAGES_SRC = ROOT / ".github" / "pages"
CATALOG = ROOT / ".github" / "labview-ci" / "catalog.json"
MANIFEST = ROOT / ".github" / "labview-ci.yml"


def copy_pages() -> None:
    PUBLIC.mkdir(parents=True, exist_ok=True)
    if PAGES_SRC.is_dir():
        for child in PAGES_SRC.iterdir():
            dst = PUBLIC / child.name
            if child.is_dir():
                if dst.exists():
                    shutil.rmtree(dst)
                shutil.copytree(child, dst)
            else:
                shutil.copy2(child, dst)
    if CATALOG.is_file():
        shutil.copy2(CATALOG, PUBLIC / "catalog.json")


def read_catalog() -> dict:
    if CATALOG.is_file():
        return json.loads(CATALOG.read_text(encoding="utf-8"))
    return {{"version": "{version}"}}


def selected_activities() -> list[str]:
    if not MANIFEST.is_file():
        return []
    activities = []
    in_activities = False
    for raw in MANIFEST.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line == "activities:":
            in_activities = True
            continue
        if in_activities and line.startswith("- "):
            activities.append(line[2:].strip())
        elif in_activities and line and not raw.startswith(" "):
            break
    return activities


def main() -> None:
    copy_pages()
    cat = read_catalog()
    repo = html.escape(os.environ.get("CI_PROJECT_PATH", "{fallback_repo}"))
    version = html.escape(str(cat.get("version", "{version}")))
    sha = html.escape(os.environ.get("CI_COMMIT_SHA", "")[:12])
    pages = html.escape(os.environ.get("CI_PAGES_URL", "{pages}"))
    activities = selected_activities() or ["dashboard"]
    activity_html = "".join("<li>" + html.escape(a) + "</li>" for a in activities)
    (PUBLIC / "index.html").write_text("""<!doctype html>
<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<title>LabVIEW CI - GitLab</title>
<style>body{{margin:0;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;background:#f6f8fa;color:#24292f}}main{{max-width:920px;margin:0 auto;padding:42px 20px}}.panel{{background:#fff;border:1px solid #d0d7de;border-radius:8px;padding:24px}}code{{background:#afb8c133;border-radius:6px;padding:.16em .38em}}</style></head>
<body><main><div class=\"panel\"><h1>LabVIEW CI for GitLab</h1>
<p>This repository has the first GitLab provider scaffold for LabVIEW CI installed. Shared dashboard assets and catalog metadata stay versioned with the GitHub provider while GitLab-specific CI templates publish this Pages site.</p>
<p><strong>Project:</strong> <code>""" + repo + """</code><br><strong>Tooling version:</strong> <code>""" + version + """</code><br><strong>Pages URL:</strong> <code>""" + pages + """</code><br><strong>Commit:</strong> <code>""" + sha + """</code></p>
<h2>Installed Activities</h2><ul>""" + activity_html + """</ul>
<p>Full Windows LabVIEW worker parity requires a registered Windows Docker GitLab Runner.</p>
</div></main></body></html>\n""", encoding="utf-8")


if __name__ == "__main__":
    main()
'''


def write_gitlab_scaffold(target_root: Path, catalog: dict, owner: str | None, name: str | None,
                          branch: str, dry_run: bool) -> None:
    files = {
        ".gitlab-ci.yml": gitlab_root_ci(),
        ".gitlab/labview-ci/pipeline.yml": gitlab_pipeline_yml(branch),
        ".gitlab/labview-ci/build-dashboard.py": gitlab_dashboard_builder(catalog, owner, name),
        ".gitlab/labview-ci/README.md": (
            "# LabVIEW CI for GitLab\n\n"
            "This directory contains the GitLab CI provider adapter generated by "
            "`.github/labview-ci/install.py --provider gitlab`. The shared catalog, "
            "dashboard assets, and LabVIEW scripts remain versioned with the GitHub "
            "provider so both integrations stay in one release stream.\n\n"
            "Full Windows LabVIEW worker parity requires a registered Windows Docker "
            "GitLab Runner. The initial scaffold publishes the dashboard payload to "
            "GitLab Pages and reserves the provider boundary for worker jobs.\n"
        ),
    }
    for rel, content in files.items():
        if dry_run:
            log(f"  would write     {rel}")
            continue
        dst = target_root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(content, encoding="utf-8")
        log(f"  write           {rel}")


def print_gitlab_next_steps(owner: str | None, name: str | None) -> None:
    log("")
    log("Next steps")
    log("  1. Review the changes:        git status && git diff")
    log("  2. Commit and push to GitLab: git add .github .gitlab .gitlab-ci.yml && git commit -m \"Add LabVIEW CI for GitLab\" && git push")
    log("  3. In GitLab, let the pipeline run and publish the Pages artifact.")
    log(f"  4. Open the Pages site:       {gitlab_pages_url(owner, name)}")
    log("  5. Full worker parity requires a registered Windows Docker GitLab Runner.")
    log("")
    log("GitLab provider status: dashboard/Pages scaffold installed; worker jobs and browser dispatch adapters are the next slices.")


def thin_install(catalog: dict, target_root: Path, owner: str | None, name: str | None,
                 activities: list[str], os_list: list[str], labview_version: str,
                 branch: str, dry_run: bool) -> int:
    """Write thin caller workflows + Dependabot + config that reference the source
    repo's reusable workflow/actions at the major tag, instead of vendoring copies.
    A thin consumer holds only these small files; updates arrive via the moving tag.
    """
    src = catalog.get("source", {}) or {}
    src_repo = src.get("repo", "") or ""
    version = str(catalog.get("version", "0.0.0"))
    major = version.split(".")[0] if version else "1"
    alias = f"v{major}"
    # The caller pins the reusable workflow at the major alias (@v1) — a stable
    # orchestration "harness". The CAPABILITY version, however, is pinned to this
    # exact release in the config below (source.ref). The reusable workflow checks
    # out the tooling at that exact ref at runtime, so a consumer's capabilities
    # never change version automatically — only when they click "Update now",
    # which edits this config file (a token-free change; not a workflow file).
    cap_ref = f"v{version}"
    now = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    acts = [a for a in activities
            if a in {c["id"] for c in catalog.get("capabilities", []) if c.get("status") != "planned"}]
    os_csv = ", ".join(os_list)

    def write(rel: str, content: str) -> None:
        dst = target_root / rel
        if dry_run:
            log(f"  would write     {rel}")
            return
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(content, encoding="utf-8")
        log(f"  write           {rel}")

    # 1) The CI caller — triggers + delegate to the reusable workflow @major.
    write(".github/workflows/labview-ci.yml",
        "# LabVIEW CI — thin caller. All logic lives in the shared reusable workflow;\n"
        "# this file owns only the triggers. Updates arrive automatically through the\n"
        f"# moving major tag (@{alias}); Dependabot can also bump it.\n"
        "name: LabVIEW CI\n\n"
        "on:\n"
        "  pull_request:\n"
        "    paths: ['**.vi', '**.ctl', '**.lvproj', '**.lvlib', '**.lvclass']\n"
        "  push:\n"
        f"    branches: [{branch}]\n"
        "    paths: ['**.vi', '**.ctl', '**.lvproj', '**.lvlib', '**.lvclass']\n"
        "  workflow_dispatch:\n\n"
        "jobs:\n"
        "  labview-ci:\n"
        "    permissions:\n"
        "      contents: write\n"
        "      statuses: write\n"
        "      packages: read\n"
        f"    uses: {src_repo}/.github/workflows/labview-ci.reusable.yml@{alias}\n"
        "    with:\n"
        f"      labview-version: \"{labview_version}\"\n"
        "    secrets: inherit\n")

    # 2) The dashboard caller — meta-triggered; delegates to the dashboard action
    #    at the version this repo opted into (config source.ref), checked out at
    #    runtime, so the dashboard never changes version automatically.
    if "dashboard" in acts:
        write(".github/workflows/dashboard.yml",
            "# CI Dashboard — thin caller. Rebuilds on every commit status, after the\n"
            "# LabVIEW CI workflow, and hourly. The build logic lives in the shared\n"
            "# dashboard action, pulled at the capability version this repo opted into\n"
            "# (.github/labview-ci.yml: source.ref) — so the dashboard updates only when\n"
            "# you opt in via \"Update now\", never automatically. Owns the triggers + deploy.\n"
            "name: CI Dashboard\n"
            "run-name: Publish CI dashboard - ${{ github.event_name == 'workflow_dispatch' && 'manual run' || github.sha }}\n\n"
            "on:\n"
            "  status:\n"
            "  workflow_run:\n"
            "    workflows: [\"LabVIEW CI\"]\n"
            "    types: [completed]\n"
            "  schedule:\n"
            "    - cron: '0 * * * *'\n"
            "  workflow_dispatch:\n\n"
            "concurrency:\n"
            "  group: dashboard-pages\n"
            "  cancel-in-progress: true\n\n"
            "permissions:\n"
            "  contents: write\n"
            "  statuses: read\n"
            "  actions: read\n\n"
            "jobs:\n"
            "  dashboard:\n"
            "    runs-on: ubuntu-latest\n"
            "    steps:\n"
            "      - uses: actions/checkout@v5\n"
            "      - name: Read opted-in tooling ref from config\n"
            "        id: cfg\n"
            "        shell: bash\n"
            "        run: |\n"
            "          REF=$(awk '/^[[:space:]]*ref:[[:space:]]/{print $2; exit}' .github/labview-ci.yml 2>/dev/null)\n"
            "          echo \"ref=${REF:-" + alias + "}\" >> \"$GITHUB_OUTPUT\"\n"
            "      - name: Check out tooling (opted-in version)\n"
            "        uses: actions/checkout@v5\n"
            "        with:\n"
            f"          repository: {src_repo}\n"
            "          ref: ${{ steps.cfg.outputs.ref }}\n"
            "          path: _lvci\n"
            "      - uses: ./_lvci/actions/dashboard\n"
            "        with:\n"
            "          github-token: ${{ secrets.GITHUB_TOKEN }}\n"
            "      - uses: peaceiris/actions-gh-pages@v4.1.0\n"
            "        id: deploy\n"
            "        continue-on-error: true\n"
            "        with:\n"
            "          github_token: ${{ secrets.GITHUB_TOKEN }}\n"
            "          publish_dir: ci-out/dashboard\n"
            "          destination_dir: .\n"
            "          keep_files: true\n"
            # Retry once if a concurrent gh-pages push (configurator site, VI
            # snapshots, report deploys) made this a non-fast-forward; peaceiris
            # re-clones gh-pages each run, so the retry starts from the new tip.
            "      - name: Wait out a gh-pages push race\n"
            "        if: steps.deploy.outcome == 'failure'\n"
            "        run: sleep 30\n"
            "      - name: Deploy dashboard to GitHub Pages (retry)\n"
            "        if: steps.deploy.outcome == 'failure'\n"
            "        uses: peaceiris/actions-gh-pages@v4.1.0\n"
            "        with:\n"
            "          github_token: ${{ secrets.GITHUB_TOKEN }}\n"
            "          publish_dir: ci-out/dashboard\n"
            "          destination_dir: .\n"
            "          keep_files: true\n")

    # 3) Dependabot — auto-PRs to bump the @major pin (token-free updates).
    write(".github/dependabot.yml",
        "# Auto-update the pinned LabVIEW CI tooling. Dependabot opens a reviewable PR\n"
        "# whenever the referenced reusable workflow / action tag gets a new release.\n"
        "version: 2\n"
        "updates:\n"
        "  - package-ecosystem: \"github-actions\"\n"
        "    directory: \"/\"\n"
        "    schedule:\n"
        "      interval: \"weekly\"\n"
        "    commit-message:\n"
        "      prefix: \"ci\"\n"
        "    labels:\n"
        "      - \"dependencies\"\n"
        "      - \"labview-ci\"\n")

    # 4) The consumer config the reusable workflow reads to gate activities.
    cfg = [
        "# .github/labview-ci.yml — LabVIEW CI consumer config (thin install).",
        "schemaVersion: 1",
        f"installedVersion: {version}",
        f"installedAt: {now}",
        "source:",
        f"  repo: {src_repo}",
        f"  ref: {cap_ref}",
        "config:",
        f"  labviewVersion: \"{labview_version}\"",
        f"  os: [{os_csv}]",
        "  concurrency:",
        "    # Per-repo cap on parallel CI jobs. GitHub's real limit is per ACCOUNT",
        "    # (Free 20, Pro 40, Team 60, Enterprise 500 jobs shared across ALL your",
        "    # repos), and submissions/upgrades draw from it too -- so keep it modest.",
        "    maxParallel: 5",
        "activities:",
    ] + [f"  - {a}" for a in acts] + [""]
    write(".github/labview-ci.yml", "\n".join(cfg))

    log("")
    if dry_run:
        log("Dry run (thin): re-run without --dry-run to write the files.")
        return 0
    repo = f"{owner}/{name}" if owner and name else "<owner>/<repo>"
    log("Thin install complete — your repo references the shared reusable workflow "
        f"at @{alias} and runs capabilities pinned to {cap_ref}.")
    log("")
    log("Next steps")
    log("  1. Review:  git status && git diff")
    log("  2. Commit:  git add .github && git commit -m \"Add LabVIEW CI (thin)\" && git push")
    log("  3. Enable GitHub Pages from the 'gh-pages' branch (Settings > Pages).")
    log("  4. Settings > Actions > General > Workflow permissions > Read and write.")
    if "custom-image" in acts:
        log("  5. (vi-analyzer) Build the shared image once, or set vars.LABVIEW_IMAGE_NAME.")
    log("")
    log(f"Updates: capabilities stay on {cap_ref} until you opt in. When a newer "
        "release ships, run the \"Update LabVIEW CI tooling\" workflow (the dashboard's "
        "\"Update now\" button) to bump source.ref — a reviewable, token-free PR.")
    return 0


def consumer_dashboard_workflow(catalog: dict, branch: str = "main") -> str:
    """Thin dashboard workflow for a vendored consumer.

    The dashboard generator lives in actions/dashboard, a LOCAL path that only
    exists in the tooling repo (the source's own dashboard-pages.yml runs it via
    ./actions/dashboard) and that cannot be copied into a consumer because the
    branding substitution would rewrite the generator's source-repo references.
    So a consumer runs the dashboard by checking the tooling out at its opted-in
    ref into _lvci/ at runtime and using ./_lvci/actions/dashboard - the same
    approach as --thin. This is written over the vendored copy after install.
    """
    src = catalog.get("source", {}) or {}
    src_repo = src.get("repo", "") or ""
    # Fallback ref for the generated workflow's awk (used only if labview-ci.yml
    # can't be read): pin to this exact version, not the source's "main".
    ref = f"v{catalog.get('version', '0.0.0')}"
    br = branch or "main"
    return (
        "# CI Dashboard \u2014 GitHub Pages. Thin caller installed by .github/labview-ci/install.py.\n"
        "# The dashboard build logic lives in the shared composite action, pulled at the tooling\n"
        "# version this repo opted into (.github/labview-ci.yml: source.ref) and checked out at\n"
        "# runtime \u2014 so this repo keeps no copy of the generator and the dashboard updates only\n"
        "# when you opt in. Owns the triggers + the Pages deploy.\n"
        "name: CI Dashboard \u2014 GitHub Pages\n"
        "run-name: Publish CI dashboard - ${{ github.event_name == 'workflow_dispatch' && 'manual run' || github.sha }}\n\n"
        "on:\n"
        "  # Build on the install merge + whenever the config changes, so the dashboard\n"
        "  # publishes itself the first time without waiting for the hourly schedule.\n"
        "  push:\n"
        "    branches: [" + br + "]\n"
        "    paths:\n"
        "      - '.github/labview-ci.yml'\n"
        "      - '.github/workflows/dashboard-pages.yml'\n"
        "  status:\n"
        "  workflow_run:\n"
        "    workflows:\n"
        '      - "Mass Compile \u2014 Windows Container"\n'
        '      - "Mass Compile Backfill \u2014 Windows Container"\n'
        '      - "Run VI Analyzer \u2014 Windows Container"\n'
        '      - "VIDiff Report \u2014 Windows Container"\n'
        '      - "VIDiff Report \u2014 Linux Container"\n'
        '      - "VIDiff Deploy \u2014 Pages + PR Comment"\n'
        '      - "VI Snapshots and VI Browser"\n'
        "    types: [completed]\n"
        "  schedule:\n"
        "    - cron: '0 * * * *'\n"
        "  workflow_dispatch:\n\n"
        "concurrency:\n"
        "  group: dashboard-pages\n"
        "  cancel-in-progress: true\n\n"
        "permissions:\n"
        "  contents: write\n"
        "  statuses: read\n"
        "  actions: read\n\n"
        "jobs:\n"
        "  build-dashboard:\n"
        "    runs-on: ubuntu-latest\n"
        "    steps:\n"
        "      - name: Checkout repository\n"
        "        uses: actions/checkout@v5\n"
        "      - name: Read opted-in tooling ref from config\n"
        "        id: cfg\n"
        "        shell: bash\n"
        "        run: |\n"
        "          REF=$(awk '/^[[:space:]]*ref:[[:space:]]/{print $2; exit}' .github/labview-ci.yml 2>/dev/null)\n"
        '          echo "ref=${REF:-' + ref + '}" >> "$GITHUB_OUTPUT"\n'
        "      - name: Check out tooling (opted-in version)\n"
        "        uses: actions/checkout@v5\n"
        "        with:\n"
        "          repository: " + src_repo + "\n"
        "          ref: ${{ steps.cfg.outputs.ref }}\n"
        "          path: _lvci\n"
        "      - name: Build CI dashboard\n"
        "        uses: ./_lvci/actions/dashboard\n"
        "        with:\n"
        "          github-token: ${{ secrets.GITHUB_TOKEN }}\n"
        "      - name: Deploy dashboard to GitHub Pages\n"
        "        id: deploy\n"
        "        continue-on-error: true\n"
        "        uses: peaceiris/actions-gh-pages@v4.1.0\n"
        "        with:\n"
        "          github_token: ${{ secrets.GITHUB_TOKEN }}\n"
        "          publish_dir: ci-out/dashboard\n"
        "          destination_dir: .\n"
        "          keep_files: true\n"
        # Retry once if a concurrent gh-pages push (configurator site, VI
        # snapshots, report deploys) made this a non-fast-forward; peaceiris
        # re-clones gh-pages each run, so the retry starts from the new tip.
        "      - name: Wait out a gh-pages push race\n"
        "        if: steps.deploy.outcome == 'failure'\n"
        "        run: sleep 30\n"
        "      - name: Deploy dashboard to GitHub Pages (retry)\n"
        "        if: steps.deploy.outcome == 'failure'\n"
        "        uses: peaceiris/actions-gh-pages@v4.1.0\n"
        "        with:\n"
        "          github_token: ${{ secrets.GITHUB_TOKEN }}\n"
        "          publish_dir: ci-out/dashboard\n"
        "          destination_dir: .\n"
        "          keep_files: true\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Install LabVIEW CI capabilities into a repository.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--activities", default="",
                        help="Comma-separated capability ids (e.g. masscompile,vi-analyzer,dashboard).")
    parser.add_argument("--os", default="",
                        help="Comma-separated operating systems: windows,linux (default: catalog default).")
    parser.add_argument("--labview-version", default="",
                        help="LabVIEW year (default: catalog default, e.g. 2026).")
    parser.add_argument("--image-name", default="",
                        help="Override the GHCR image name (default: <repo>-labview).")
    parser.add_argument("--branch", default="",
                        help="Default branch the workflows trigger on (default: catalog default).")
    parser.add_argument("--repo", default="",
                        help="Target repo owner/name (default: inferred from the git remote).")
    parser.add_argument("--provider", choices=("github", "gitlab"), default="github",
                        help="Target CI provider to scaffold (default: github).")
    parser.add_argument("--source", default="",
                        help="Path to the tooling checkout to copy from (default: this script's repo root).")
    parser.add_argument("--target", default="",
                        help="Path to the target repo (default: current directory).")
    parser.add_argument("--list", action="store_true", help="List available capabilities and exit.")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be installed without writing.")
    parser.add_argument("--force", action="store_true", help="Overwrite files that already exist.")
    parser.add_argument("--update", action="store_true",
                        help="Re-pull the latest tooling for an existing install (overwrites tooling, "
                             "preserves your config files). Reads the prior selection from the manifest.")
    parser.add_argument("--thin", action="store_true",
                        help="Thin install: write small caller workflows that reference the shared "
                             "reusable workflow + composite actions at the source repo's major tag "
                             "(e.g. @v1), plus Dependabot, instead of vendoring full copies. Updates "
                             "then arrive automatically via the moving tag — no token, no re-install.")
    parser.add_argument("--no-vars", action="store_true", help="Do not print the optional 'gh variable set' steps.")
    args = parser.parse_args()

    source_root = Path(args.source).resolve() if args.source else Path(__file__).resolve().parents[2]
    target_root = Path(args.target).resolve() if args.target else Path.cwd()
    catalog = load_catalog(source_root)

    if args.list:
        log(f"{catalog.get('name', 'LabVIEW CI')} v{catalog.get('version', '0.0.0')} - available capabilities:\n")
        for cap in catalog.get("capabilities", []):
            status = cap.get("status", "stable")
            tag = "" if status == "stable" else f" [{status}]"
            rec = " (recommended)" if cap.get("recommended") else ""
            log(f"  {cap['id']:<14}{tag}{rec}")
            log(f"      {cap['summary']}")
            log(f"      OS: {', '.join(cap.get('supportsOs', []))}")
            log("")
        return 0

    defaults = catalog.get("defaults", {})

    # In --update mode, recover the previous selection from the target's manifest so
    # a plain `install.py --update` re-pulls exactly what was installed before.
    manifest = read_manifest(target_root) if args.update else None
    if args.update and manifest is None:
        die("--update needs an existing install: .github/labview-ci.yml not found in the "
            "target. Run a normal install first.")
    prev = manifest or {}

    activities = parse_csv(args.activities) or prev.get("activities") or default_activities(catalog)
    os_list = parse_csv(args.os) or prev.get("os") or list(defaults.get("os", ["windows"]))
    valid_os = {"windows", "linux"}
    bad_os = [o for o in os_list if o not in valid_os]
    if bad_os:
        die(f"invalid --os values {bad_os}; allowed: windows, linux.")
    labview_version = args.labview_version or prev.get("labviewVersion") or defaults.get("labviewVersion", "2026")
    branch = args.branch or defaults.get("branch", "main")
    image_name = args.image_name or None

    # Update overwrites tooling files but preserves the consumer's own config.
    update = args.update
    force = args.force or update
    preserve = {p.replace("\\", "/") for p in catalog.get("userConfig", {}).get("files", [])}

    if args.provider == "gitlab" and args.thin:
        die("--thin is currently only supported for --provider github.")

    if source_root == target_root:
        warn("source and target are the same directory (installing into the tooling repo itself).")

    owner, name = detect_target_repo(target_root, args.repo)
    subs = build_substitutions(catalog, owner, name, args.provider)
    # Vendored workflows carry a static `branches: [main]` push-trigger filter that
    # YAML can't express as the default branch; rewrite it to the target repo's
    # actual default branch so push-to-default CI fires on non-"main" repos.
    if branch and branch != "main":
        subs.append(("branches: [main]", f"branches: [{branch}]"))
    if not subs:
        warn("target repo owner/name unknown - cosmetic branding left as-is "
             "(functional wiring still adapts at runtime). Pass --repo owner/name to rebrand.")

    log(f"{catalog.get('name', 'LabVIEW CI')} installer")
    log(f"  source:   {source_root}")
    log(f"  target:   {target_root}" + (f"  ({owner}/{name})" if owner and name else ""))
    log(f"  activities: {', '.join(activities)}")
    log(f"  os:         {', '.join(os_list)}")
    log(f"  labview:    {labview_version}")
    log(f"  provider:   {args.provider}")
    if update and prev.get("installedVersion"):
        log(f"  version:    {prev.get('installedVersion')} -> {catalog.get('version', '0.0.0')}")
    log(f"  mode:       {'dry-run ' if args.dry_run else ''}{'update' if update else ('thin install' if args.thin else 'install')}")
    log("")

    if args.thin:
        return thin_install(catalog, target_root, owner, name, activities, os_list,
                            labview_version, branch, args.dry_run)

    file_list = resolve_file_list(catalog, activities, os_list)
    if args.provider == "gitlab":
        file_list = [f for f in file_list if not f.replace("\\", "/").startswith(GITHUB_WORKFLOW_PREFIX)]
    stats = {"installed": 0, "updated": 0, "skipped": 0, "planned": 0, "preserved": 0}
    for entry in file_list:
        copy_entry(entry, source_root, target_root, subs, force, args.dry_run, stats,
                   preserve, update)

    # The dashboard generator (actions/dashboard) is a local path that only exists
    # in the tooling repo and can't be rebranded into a consumer, so the vendored
    # source dashboard-pages.yml (which runs ./actions/dashboard) can't work here.
    # Replace it with a thin caller that checks the tooling out at runtime.
    if args.provider == "github" and any(f.endswith("dashboard-pages.yml") for f in file_list) and not args.dry_run:
        dpath = target_root / ".github" / "workflows" / "dashboard-pages.yml"
        if dpath.exists():
            dpath.write_text(consumer_dashboard_workflow(catalog, branch), encoding="utf-8")
            log("  rewrite (thin)  .github/workflows/dashboard-pages.yml")

    if args.provider == "gitlab":
        write_gitlab_scaffold(target_root, catalog, owner, name, branch, args.dry_run)

    write_manifest(target_root, catalog, [a for a in activities if a in
                   {c["id"] for c in catalog.get("capabilities", []) if c.get("status") != "planned"}],
                   os_list, labview_version, image_name, branch, args.dry_run, args.provider)

    log("")
    if args.dry_run:
        verb = "updated" if update else "installed"
        extra = f", {stats['preserved']} config file(s) preserved" if update else ""
        log(f"Dry run: {stats['planned']} file(s) would be {verb}, {stats['skipped']} already present{extra}.")
        log("Re-run without --dry-run to apply" + ("." if update else " (add --force to overwrite existing files)."))
        return 0
    if update:
        log(f"Update complete: {stats['updated']} file(s) refreshed, {stats['installed']} new, "
            f"{stats['preserved']} config file(s) preserved.")
        log("")
        log("Next steps")
        log("  1. Review what changed:  git diff")
        log("  2. Commit the update:    git add .github && git commit -m \"Update LabVIEW CI\" && git push")
        return 0
    log(f"Installed {stats['installed']} file(s); {stats['skipped']} skipped (already present).")
    if stats["skipped"]:
        log("Use --force to overwrite skipped files.")
    if args.provider == "gitlab":
        print_gitlab_next_steps(owner, name)
    else:
        print_next_steps(catalog, owner, name, activities, labview_version, image_name, not args.no_vars)
    return 0


if __name__ == "__main__":
    sys.exit(main())
