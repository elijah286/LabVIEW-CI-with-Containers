#!/usr/bin/env python3
import html, json, os, re, sys, urllib.request, urllib.error
from urllib.parse import quote

token    = os.environ['GH_TOKEN']
repo     = os.environ['REPO']
pages_url = os.environ['PAGES_URL']

def gh_get(path):
    # NOTE: an empty path must hit the bare repo endpoint (…/repos/{repo}); a
    # trailing slash (…/repos/{repo}/) makes GitHub return 404, which silently
    # broke get_default_branch() below. Only join the '/' when there IS a path.
    url = f"https://api.github.com/repos/{repo}" + (f"/{path}" if path else "")
    req = urllib.request.Request(url, headers={
        'Authorization': f'token {token}',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
    })
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        print(f"  HTTP {e.code} for {path}", file=sys.stderr)
        return None

# ── Resolve the repo's default branch (NOT hard-coded 'main') ─────
# Consumers commonly use 'master' or other default branches. Hard-coding 'main'
# made fetch_commits() request commits from a branch that doesn't exist, so the
# dashboard came up EMPTY on every non-'main' repo. Query the repo's real default
# branch once (cached); fall back to 'main' only if the lookup fails.
_default_branch = None

def get_default_branch():
    global _default_branch
    if _default_branch is not None:
        return _default_branch
    repo_info = gh_get('')
    _default_branch = repo_info.get('default_branch', 'main') if repo_info else 'main'
    return _default_branch

# ── Fetch a JSON file straight from the deployed Pages site ─────
# Reads static gallery/report JSON deployed alongside the dashboard (the snapshot
# blob index, masscompile summaries, …). Returns None on any error (missing file,
# propagation lag, etc.).
def http_json(url):
    req = urllib.request.Request(url, headers={'Accept': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.load(r)
    except Exception:
        return None

# ── Snapshot coverage: which of a revision's VIs have a rendered snapshot ─────
# Snapshots are content-addressed by git blob SHA under vi-snapshots/by-blob/, so
# whether a revision "has snapshots" is answered by the snapshot store itself —
# NOT by VIDiff (which only renders CHANGED VIs and is what this column used to
# read, leaving it blank for every revision that had snapshots but no diff run).
# The set of blobs that have a deployed snapshot is read ONCE: a single blobs.json
# index when build-snapshots.ps1 has written one, else the union of every manifest
# listed in commits.json (also exact — build-gallery writes a full-tree manifest
# per commit and the deploy keeps every by-blob file). A revision's coverage is
# then its VI blobs intersected with that set, which also reveals partial coverage
# (older revisions whose changed VIs were never rendered).
_rendered_blobs_cache = {'set': None}
def rendered_blobs():
    if _rendered_blobs_cache['set'] is not None:
        return _rendered_blobs_cache['set']
    blobs = set()
    idx = http_json(f"{pages_url}/vi-snapshots/blobs.json")
    if isinstance(idx, list):
        blobs = {b for b in idx if isinstance(b, str)}
    elif isinstance(idx, dict) and isinstance(idx.get('blobs'), list):
        blobs = {b for b in idx['blobs'] if isinstance(b, str)}
    else:
        commits = http_json(f"{pages_url}/vi-snapshots/commits.json")
        if isinstance(commits, list):
            for c in commits:
                csha = c.get('sha') if isinstance(c, dict) else None
                if not csha:
                    continue
                man = http_json(f"{pages_url}/vi-snapshots/{csha}/manifest.json")
                if isinstance(man, list):
                    for e in man:
                        if isinstance(e, dict) and e.get('blob'):
                            blobs.add(e['blob'])
    _rendered_blobs_cache['set'] = blobs
    return blobs

_snap_cov_cache = {}
def snapshot_coverage(sha):
    # (have, total) for a revision: how many of its VIs have a rendered snapshot
    # vs how many VIs it has. total = vi_tree (the same VI set the browser shows);
    # have = those whose content blob is in the rendered set.
    if sha in _snap_cov_cache:
        return _snap_cov_cache[sha]
    vis = vi_tree(sha)
    total = len(vis)
    have = 0
    if total:
        rb = rendered_blobs()
        if rb:
            have = sum(1 for v in vis if v.get('blob') in rb)
    res = (have, total)
    _snap_cov_cache[sha] = res
    return res

_mc_cache = {}
def masscompile_summary(sha):
    # {total, ok, bad, percent, status, exit, duration} written by masscompile.ps1
    # and deployed alongside the report at masscompile/<sha>/summary.json. Lets the
    # Mass Compile column show the % of project VIs that compiled instead of a
    # binary pass/fail (most VIs compile even when a few depend on libraries absent
    # from the CI image).
    if sha in _mc_cache:
        return _mc_cache[sha]
    data = http_json(f"{pages_url}/masscompile/{sha}/summary.json")
    _mc_cache[sha] = data if isinstance(data, dict) else None
    return _mc_cache[sha]

# LabVIEW / NI source-file extensions. A revision that touches one of
# these (outside the CI tooling — see below) is a change to the actual
# project, as opposed to a CI/docs/tooling revision.
LV_SOURCE_EXTS = (
    '.vi', '.vit', '.ctl', '.ctt', '.lvclass', '.lvlib', '.lvlibp',
    '.lvproj', '.xctl', '.xnode', '.vipc', '.vip', '.llb', '.mnu', '.lvtest',
)

# Directories that hold CI TOOLING (not the LabVIEW project): vendored workflows
# + scripts under .github/, the shared composite actions (whose helper VIs, e.g.
# actions/vidiff/PrintToSingleFileHtml/*.vi, must NOT count as project work), the
# runtime tooling checkout (_lvci/), and build output. A VI under any of these is
# tooling, so a commit touching only these is a CI revision — keeping the
# CI-vs-project split correct even though the tooling itself ships VIs.
TOOLING_PREFIXES = ('.github/', 'actions/', '_lvci/', 'ci-out/', 'build/')

# ── Classify a commit: does it touch project LabVIEW source? ─────
# Cached so the paged fetch below and the row loop share ONE detail call per
# commit (the file list comes from the per-commit endpoint).
_classify_cache = {}
def classify_commit(sha):
    if sha in _classify_cache:
        return _classify_cache[sha]
    detail = gh_get(f'commits/{sha}') or {}
    files = [f['filename'] for f in (detail.get('files') or [])]
    is_proj = any(
        f.lower().endswith(LV_SOURCE_EXTS) and not f.startswith(TOOLING_PREFIXES)
        for f in files)
    info = {'files': files, 'is_project': is_proj}
    _classify_cache[sha] = info
    return info

# ── Fetch commits, deep enough to surface the project's own history ─────
# The status table needs RECENT commits (for badges), but the project's revisions
# must stay visible even when a long CI/tooling sprint fills the most-recent slots
# on main. So fetch the recent window, then keep paging — classifying each commit —
# until enough project revisions are collected (or a hard scan cap is hit). Beyond
# the recent window only PROJECT revisions are kept, so the deeper scan surfaces
# project history without flooding the table with old CI commits.
_RECENT_WINDOW  = 100   # always keep at least this many most-recent commits
_PROJECT_TARGET = 30    # keep paging until this many project revisions are found
_SCAN_CAP       = 500   # never classify more than this many commits (cost guard)
def fetch_commits():
    out, n_proj, n_scanned, page = [], 0, 0, 1
    branch = get_default_branch()
    while n_scanned < _SCAN_CAP:
        batch = gh_get(f'commits?sha={branch}&per_page=100&page={page}') or []
        if not batch:
            break
        for c in batch:
            n_scanned += 1
            info = classify_commit(c['sha'])
            if n_scanned <= _RECENT_WINDOW or info['is_project']:
                out.append(c)
            if info['is_project']:
                n_proj += 1
            if n_scanned >= _SCAN_CAP:
                break
        if n_scanned >= _RECENT_WINDOW and n_proj >= _PROJECT_TARGET:
            break
        page += 1
    return out
commits_data = fetch_commits()

# ── List the VI files present at a revision ─────────────────
# Powers the VI Browser's file tree INDEPENDENTLY of whether snapshots have
# been rendered: the browser builds its sidebar from this list, so a revision's
# hierarchy is always visible (a missing snapshot just shows a placeholder + a
# "Generate snapshots" prompt). The git tree API returns each blob's SHA, which
# is exactly the content-address the snapshot store keys on
# (vi-snapshots/by-blob/<ab>/<blob>.html), so the browser can map every VI to
# its snapshot (or detect its absence) with no extra index. Filter mirrors
# build-snapshots.ps1 (*.vi/*.ctl, excluding CI/build dirs).
_tree_cache = {}
def vi_tree(sha):
    if sha in _tree_cache:
        return _tree_cache[sha]
    data = gh_get(f'git/trees/{sha}?recursive=1')
    vis = []
    if data and isinstance(data.get('tree'), list):
        for t in data['tree']:
            if t.get('type') != 'blob':
                continue
            p = t.get('path', '')
            pl = p.lower()
            if not (pl.endswith('.vi') or pl.endswith('.ctl')):
                continue
            if p.startswith(TOOLING_PREFIXES):
                continue
            vis.append({'vi_rel': p, 'blob': t.get('sha', '')})
        vis.sort(key=lambda e: e['vi_rel'].lower())
    _tree_cache[sha] = vis
    return vis

# Accumulates one entry per project revision for vi-snapshots/files.json, the
# VI Browser's snapshot-independent source of commits + file trees.
file_commits = []

# ── "Run" targets for empty cells ───────────────────────────────
# Each capability column maps to the consumer-repo workflow(s) that re-run it
# for one commit, so an empty cell can offer a one-click "run". Entries with
# both 'windows' and 'linux' drive the platform picker; a lone 'all' key is a
# single-target capability (no picker). The inputs are the workflow_dispatch
# fields, with {sha}/{parent} placeholders filled per row in the browser. These
# follow the standard installed workflow names, so they resolve in the consumer
# repo (source + hybrid installs); a thin consumer without them simply gets a
# link that 404s, which is why the affordance is unobtrusive.
RUN_TARGETS = {
    'masscompile': {'label': 'Mass Compile', 'platforms': {
        'windows': {'wf': 'masscompile-windows-container.yml', 'inputs': {'commit_sha': '{sha}'}},
        'linux':   {'wf': 'masscompile-linux-container.yml',   'inputs': {'commit_sha': '{sha}'}}}},
    'vi-analyzer': {'label': 'VI Analyzer', 'platforms': {
        'windows': {'wf': 'run-vi-analyzer-windows-container.yml', 'inputs': {'commit_sha': '{sha}'}},
        'linux':   {'wf': 'run-vi-analyzer-linux-container.yml',   'inputs': {'commit_sha': '{sha}'}}}},
    'vidiff': {'label': 'VIDiff', 'platforms': {
        'windows': {'wf': 'vidiff-windows-container.yml', 'inputs': {'head_sha': '{sha}', 'base_sha': '{parent}'}},
        'linux':   {'wf': 'vidiff-linux-container.yml',   'inputs': {'head_sha': '{sha}', 'base_sha': '{parent}'}}}},
    'snapshots': {'label': 'VI Snapshots', 'platforms': {
        # Snapshots are content-addressed and deduped, so a single backfill renders
        # exactly the MISSING VIs across all history (already-rendered blobs are
        # skipped instantly). Dispatching backfill — not head — means clicking Run
        # on an empty snapshot cell actually fills that revision (head would only
        # ever re-render the current HEAD). 'backfill' is a long-standing input on
        # every consumer's vi-snapshots.yml (the "Populate history" card uses it),
        # so this needs no workflow-file change to reach existing installs.
        'all': {'wf': 'vi-snapshots.yml', 'inputs': {'mode': 'backfill'}}}},
    # Unit tests run in the Windows worker only: Caraya and VI Tester are
    # VIPM packages (Windows-only). The runner emits JUnit that
    # build-unittest-report.py normalises into one report.
    'unit-tests': {'label': 'Unit Tests', 'platforms': {
        'windows': {'wf': 'unit-tests-windows-container.yml', 'inputs': {'commit_sha': '{sha}'}}}},
    # Antidoc (Wovalab) documentation generation runs in the Windows worker only
    # (the Antidoc CLI is a VIPM package baked into the custom image). Doc-gen is
    # heavier than the per-VI checks, so it is on-demand / push-to-default-branch.
    'antidoc': {'label': 'Antidoc', 'platforms': {
        'windows': {'wf': 'run-antidoc-windows-container.yml', 'inputs': {'commit_sha': '{sha}'}}}},
}
import json as _json
run_targets_json = _json.dumps(RUN_TARGETS)

# Small "image" glyph (GitHub octicon) shown beside a commit message when that
# revision has rendered VI snapshots, so snapshot coverage is discoverable from
# the main table — not just the Snapshots column.
SNAP_ICON = ('<svg viewBox="0 0 16 16" width="12" height="12" fill="currentColor" '
             'aria-hidden="true" style="vertical-align:text-bottom;flex:0 0 auto">'
             '<path d="M1.75 2.5a.25.25 0 0 0-.25.25v10.5c0 .138.112.25.25.25h.94l8.5-8.5a.25.25 0 0 1 '
             '.354 0l1.756 1.757V2.75a.25.25 0 0 0-.25-.25H1.75ZM14.5 9.232 11.06 5.79 3.852 13h9.898a.25.25 '
             '0 0 0 .25-.25V9.232ZM1.75 1h12.5c.966 0 1.75.784 1.75 1.75v10.5A1.75 1.75 0 0 1 14.25 15H1.75A1.75 '
             '1.75 0 0 1 0 13.25V2.75C0 1.784.784 1 1.75 1ZM5.5 6a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0Z"/></svg>')

# ── Framed per-revision reports ─────────────────────────────────────────────────────
# Per-revision reports (Mass Compile, VI Analyzer) open INSIDE the dashboard
# chrome via report-viewer.html (deployed at report/index.html), which frames
# the report under the shared site header — same nav, a revision picker, and a
# Regenerate / Re-run button. So the header no longer "goes away" when a report
# is opened, and reports that predate the header (or carry none of their own)
# still appear inside the chrome. Diff/Snapshots already open the VI Browser (its
# own headered page), so only these two doctypes are wrapped here.
DOC_LABELS = {'vi-analyzer-report': 'VI Analyzer', 'masscompile-report': 'Mass Compile', 'antidoc-report': 'Antidoc'}

def viewer_url(report_url, doctype, sha, short, platform=''):
    """Wrap a deployed report's absolute Pages URL so it opens framed under the
    shared header. ``report_url`` is e.g. ``{pages_url}/masscompile/<sha>/index.html``;
    the viewer lives at ``{pages_url}/report/index.html`` so the embedded ``src``
    is made relative to it (``../<prefix>/<sha>/index.html``)."""
    rel = report_url[len(pages_url):].lstrip('/') if report_url.startswith(pages_url) else report_url
    src = '../' + rel
    title = f'{DOC_LABELS.get(doctype, "CI Report")} \u00b7 {short or sha[:7]}'
    q = ('type=' + quote(doctype, safe='')
         + '&sha=' + quote(sha, safe='')
         + ('&short=' + quote(short, safe='') if short else '')
         + ('&platform=' + quote(platform, safe='') if platform else '')
         + '&src=' + quote(src, safe='')
         + '&title=' + quote(title, safe=''))
    return f'{pages_url}/report/index.html?{q}'

def maybe_frame(url, doctype, prefix, sha, short):
    """Frame ``url`` only when it points at a real deployed report
    (``…/<prefix>/<sha>/index.html``). A failed run whose status links to the
    Actions run page (not a report) is returned unchanged."""
    if url and f'/{prefix}/{sha}/index.html' in url:
        return viewer_url(url, doctype, sha, short)
    return url

import datetime as _dt
def _stale_pending(s):
    # A 'pending' status older than 2h is almost certainly orphaned
    # (a cancelled/abandoned run) rather than one that is still running.
    if not s or s.get('state') != 'pending':
        return False
    try:
        ts = s.get('created_at', '').replace('Z', '+00:00')
        age = _dt.datetime.now(_dt.timezone.utc) - _dt.datetime.fromisoformat(ts)
        return age.total_seconds() > 2 * 3600
    except Exception:
        return False

# A 'pending' commit status only means a run STARTED. If that run later
# crashed or was cancelled WITHOUT posting a terminal status, the pending
# lingers and the dashboard would otherwise show a perpetual "running" spinner
# for a job that has actually stopped (often with an error). Verify the linked
# workflow run is genuinely still active before trusting a pending as live.
_run_active_cache = {}
def run_is_active(url):
    if not url:
        return False
    m = re.search(r'/actions/runs/(\d+)', url)
    if not m:
        return False
    rid = m.group(1)
    if rid in _run_active_cache:
        return _run_active_cache[rid]
    data = gh_get(f'actions/runs/{rid}')
    active = bool(data) and data.get('status') in (
        'queued', 'in_progress', 'requested', 'waiting', 'pending')
    _run_active_cache[rid] = active
    return active

# Set as soon as any cell renders an actively-running activity; drives the
# faster page auto-refresh so a live run (and its result) surfaces promptly.
running_flag = {'on': False}
# Together these gate the "Run all history" backfill card (built after the row
# loop): `any_output` flips True the moment ANY terminal CI result is rendered,
# and `run_count` counts the empty cells that offer a one-click run. The card is
# emitted only on a fresh dashboard — no results, nothing running — that still
# has revisions left to run, so it never appears once CI output exists.
any_output = {'on': False}
run_count  = {'n': 0}

# Project revisions (newest first), fed to the "Populate history" dialog's
# "start from" picker. Only project revisions carry run glyphs (badge() returns
# EMPTY_CELL for non-project commits), so these are exactly the revisions the
# dialog can queue activities for. json.dumps escapes the messages safely for the
# JS string context; the dialog renders them via textContent (no HTML injection).
hist_revs = []

rows_html = []
for c in commits_data:
    sha     = c['sha']
    short   = sha[:7]
    msg     = c['commit']['message'].splitlines()[0][:80]
    author  = c['commit']['author']['name']
    date    = c['commit']['author']['date']
    parent  = (c.get('parents') or [{}])[0].get('sha', '')

    # Classify the revision by scope (cached above): a "project change" touches
    # at least one LabVIEW source file in the project itself — NOT the helper VIs
    # that ship with the CI tooling (.github/, actions/, _lvci/, ci-out/, build/).
    # Everything else (workflows, scripts, docs, metadata, merges) is a non-project
    # revision, hidden by default.
    _info = classify_commit(sha)
    files = _info['files']
    is_project = _info['is_project']
    proj_flag = 'true' if is_project else 'false'

    # Record this revision's VI file tree for the VI Browser (project revisions
    # only — CI/tooling commits don't change the VI set, so they would just
    # duplicate a neighbour's tree). Done here so the browser can render the
    # hierarchy before — or without — any snapshots existing.
    if is_project:
        file_commits.append({
            'sha': sha,
            'short': short,
            'message': msg,
            'author': author,
            'date': date,
            'vis': vi_tree(sha),
        })
        # Newest-first list of revisions the history dialog can populate.
        hist_revs.append({'sha': sha, 'short': short, 'msg': msg})

    # Fetch commit statuses
    statuses_data = gh_get(f'commits/{sha}/statuses') or []
    status_map = {}
    for s in statuses_data:
        ctx = s['context']
        if ctx not in status_map:          # keep latest per context
            status_map[ctx] = s

    def pick_status(*contexts):
        # Gather the latest status for each candidate context (in priority order).
        cands = [status_map[c] for c in contexts if c in status_map]
        if not cands:
            return None
        # Prefer a terminal state (success/failure/error) over 'pending', then
        # take the MOST RECENT one. This means a fresh Linux success wins over a
        # stale Windows failure for the same logical check, and an orphaned
        # 'pending' from a cancelled run never masks a completed result.
        terminal = [c for c in cands if c['state'] in ('success', 'failure', 'error')]
        pool = terminal if terminal else cands
        chosen = max(pool, key=lambda s: s.get('created_at', ''))
        # A 'pending' older than 2h is almost certainly orphaned (cancelled run) —
        # show it as no-status rather than a perpetual spinner.
        if _stale_pending(chosen):
            return None
        return chosen

    EMPTY_CELL = '<td style="text-align:center;color:var(--fg-muted);font-size:.75em">—</td>'

    def run_cell(cap):
        # An empty *project* cell offers a one-click "run": a subtle play glyph
        # that opens the dispatch dialog for this capability + commit. Columns
        # with no re-run workflow (or unknown caps) fall back to a plain dash.
        if cap not in RUN_TARGETS:
            return EMPTY_CELL
        run_count['n'] += 1
        return ('<td style="text-align:center">'
                f'<a href="#" class="cidash-run" data-cap="{cap}" data-sha="{sha}" '
                f'data-parent="{parent}" data-short="{short}" '
                f'title="Run {RUN_TARGETS[cap]["label"]} for commit {short}">&#9655;</a></td>')

    def fresh_pending(*contexts):
        # Return the newest actively-running (fresh 'pending') status among the
        # candidate contexts, or None. Detected separately from pick_status so a
        # re-run in progress reads as "running" even when an older terminal status
        # for the same logical check still exists.
        best = None
        for ctx in contexts:
            s = status_map.get(ctx)
            if not s or s.get('state') != 'pending' or _stale_pending(s):
                continue
            if best is None or s.get('created_at', '') > best.get('created_at', ''):
                best = s
        # A pending whose workflow run has already finished is stale (the run
        # stopped without posting its terminal status) — don't render it live.
        if best is not None and not run_is_active(best.get('target_url', '')):
            return None
        return best

    def running_cell(label, url):
        # A spinning "running" indicator linking straight to the live workflow run
        # so the user can jump to it and see where it is.
        running_flag['on'] = True
        inner = f'<span class="run-spin"></span>{label}'
        body  = (f'<a href="{url}" style="color:#fff;text-decoration:none;display:inline-flex;align-items:center;gap:5px">{inner}</a>'
                 if url else f'<span style="display:inline-flex;align-items:center;gap:5px">{inner}</span>')
        return ('<td style="text-align:center">'
                '<span class="run-badge" title="Running — click to view progress">'
                f'{body}</span></td>')

    def badge(label, *contexts, url_override=None, cap=None, doc=None):
        if not is_project:
            return EMPTY_CELL
        run = fresh_pending(*contexts)
        if run is not None:
            return running_cell(label, run.get('target_url', ''))
        s = pick_status(*contexts)
        if not s:
            return run_cell(cap) if cap else EMPTY_CELL
        any_output['on'] = True
        color  = {'success':'#2ea043','failure':'#da3633','pending':'#9a6700','error':'#da3633'}.get(s['state'],'#555')
        emoji  = {'success':'✅','failure':'❌','pending':'⏳','error':'⚠️'}.get(s['state'],'?')
        url    = url_override or s.get('target_url','')
        # Open a per-revision report inside the dashboard chrome (framed under
        # the shared header) rather than as a bare page — but only when the
        # status actually links to a deployed report (a failed run links to its
        # Actions page, which is left as-is).
        if doc and not url_override:
            url = maybe_frame(url, doc[0], doc[1], sha, short)
        link   = f'<a href="{url}" style="color:inherit">{emoji} {label}</a>' if url else f'{emoji} {label}'
        # When this column has a re-run workflow, tag the result cell with its
        # cap/sha (+ the result's timestamp) so a re-run dispatched from elsewhere
        # (the report's "Re-run analysis" button) can overlay a "Queued" spinner on
        # it via the same lvci_queued_runs bridge the empty-cell Run now uses. The
        # data-ts lets the overlay self-clear once a NEWER result lands.
        cap_attrs = ''
        if cap:
            cap_attrs = (f' class="cidash-cap-cell" data-cap="{cap}" data-sha="{sha}"'
                         f' data-parent="{parent}" data-short="{short}" data-ts="{s.get("created_at","")}"')
        return (f'<td style="text-align:center"{cap_attrs}>'
                f'<span style="background:{color};color:#fff;padding:2px 7px;border-radius:4px;font-size:.75em">{link}</span></td>')

    # Mass Compile column: show the % of project VIs that compiled (most VIs
    # compile even when a few depend on libraries absent from the CI image),
    # sourced from the run's summary.json. Falls back to the plain status badge
    # for older runs that predate summary.json.
    if not is_project:
        mc_badge = EMPTY_CELL
    else:
        _mc_run = fresh_pending('CI / Mass Compile')
        _mc = masscompile_summary(sha)
        if _mc_run is not None:
            mc_badge = running_cell('compile', _mc_run.get('target_url', ''))
        elif _mc and isinstance(_mc.get('percent'), int):
            any_output['on'] = True
            _pct = _mc['percent']
            _ok, _tot = _mc.get('ok', 0), _mc.get('total', 0)
            # Yellow whenever SOME VIs failed (a partial compile); red is reserved
            # for a true failure (0% — nothing compiled / LabVIEW errored); green
            # only at a clean 100%. Prefer the run's own status word, falling back
            # to the percentage for older summaries that predate it.
            _st = _mc.get('status')
            _failed = (_st == 'failed') or (_st is None and _pct <= 0)
            _passed = (_st == 'passed') or (_st is None and _pct >= 100)
            _col = '#2ea043' if _passed else ('#da3633' if _failed else '#bb8009')
            _emoji = '✅' if _passed else ('❌' if _failed else '⚠️')
            # The Mass Compile report opens framed inside the dashboard chrome
            # (report-viewer.html), so the header stays put and even older
            # reports that carry no header of their own still appear under it,
            # with a Regenerate button.
            _url = viewer_url(f'{pages_url}/masscompile/{sha}/index.html', 'masscompile-report', sha, short)
            mc_badge = (f'<td style="text-align:center"><span title="{_ok}/{_tot} project VIs compiled" '
                        f'style="background:{_col};color:#fff;padding:2px 7px;border-radius:4px;font-size:.75em">'
                        f'<a href="{_url}" style="color:inherit">{_emoji} {_pct}%</a></span></td>')
        else:
            mc_badge = badge('compile', 'CI / Mass Compile', cap='masscompile', doc=('masscompile-report', 'masscompile'))
    # Consider both analyzer platforms (mirrors the diff badge): a revision
    # analyzed only on Linux still surfaces its VI Analyzer result instead of
    # showing nothing because the Windows-only context is absent.
    via_badge = badge('analyze',   'CI / VI Analyzer', 'CI / VI Analyzer (Linux)', cap='vi-analyzer',
                      doc=('vi-analyzer-report', 'vi-analyzer'))
    # The diff badge opens the unified VI Browser filtered to this commit's
    # changed VIs (each links to its diff report), rather than a separate table.
    diff_badge= badge('diff',      'CI / VIDiff (windows)', 'CI / VIDiff (linux)',
                       url_override=f'{pages_url}/vi-snapshots/index.html?sha={sha}&changed=1', cap='vidiff')
    # Snapshots column: how many of this revision's VIs have a rendered snapshot
    # (content-addressed by git blob), linking into the VI Browser for the commit.
    # Snapshots are a single content-addressed gallery (not per-platform) and are
    # independent of VIDiff. None yet -> one-click run; partial coverage is flagged
    # amber so the missing VIs are visible (fill them by running this revision, or
    # via "Populate history" — a backfill renders all history oldest -> newest).
    if not is_project:
        snap_badge = '<td style="text-align:center;color:var(--fg-muted);font-size:.75em">—</td>'
    else:
        _snap_run = fresh_pending('CI / VI Snapshots')
        _have, _total = snapshot_coverage(sha)
        if _snap_run is not None:
            snap_badge = running_cell('snapshots', _snap_run.get('target_url', ''))
        elif _have <= 0:
            snap_badge = run_cell('snapshots')
        else:
            any_output['on'] = True
            _href = f'{pages_url}/vi-snapshots/index.html?sha={sha}'
            if _have >= _total:
                _bg, _txt = '#1f6feb', str(_total)
                _tip = f'Snapshots rendered for all {_total} VIs in this revision'
            else:
                _bg, _txt = '#9a6700', f'{_have}/{_total}'
                _tip = (f'{_have} of {_total} VIs have snapshots; {_total - _have} missing '
                        f'- run this revision or use Populate history to backfill')
            snap_badge = (f'<td style="text-align:center"><span title="{_tip}" '
                          f'style="background:{_bg};color:#fff;padding:2px 7px;border-radius:4px;font-size:.75em">'
                          f'<a href="{_href}" style="color:inherit">{_txt}</a></span></td>')

    # Unit Tests column: pass/fail from a LabVIEW unit-test framework (UTF / JKI
    # VI Tester / Caraya) once a runner posts the "CI / Unit Tests" status. The
    # capability is currently "planned" (no runner workflow yet), so this shows a
    # neutral placeholder until results exist; WHICH framework ran belongs in the
    # test report as metadata, not as separate per-framework columns. Now that
    # the runner exists, cap='unit-tests' makes an empty cell a Run-now glyph
    # (dispatches unit-tests-windows-container.yml) and doc= frames the report
    # in the shared chrome (report-viewer), like the other per-revision reports.
    unit_badge = badge('tests', 'CI / Unit Tests', cap='unit-tests',
                       doc=('unit-tests-report', 'unit-tests'))
    # Antidoc column: links to the generated documentation, framed in the
    # dashboard chrome via report-viewer. An empty project cell offers a
    # one-click run (cap='antidoc' dispatches run-antidoc-windows-container.yml).
    antidoc_badge = badge('docs', 'CI / Antidoc', cap='antidoc',
                          doc=('antidoc-report', 'antidoc'))

    # Small camera/image glyph beside the commit message whenever this revision
    # has any rendered VI snapshots, so snapshot coverage is discoverable straight
    # from the main table (tooltip per request). Coverage is cached, so reusing it
    # here costs nothing.
    snap_glyph = ''
    if is_project:
        _gh, _gt = snapshot_coverage(sha)
        if _gh > 0:
            _gtip = ('Snapshots exist for this revision'
                     if _gh >= _gt else
                     f'Snapshots exist for this revision ({_gh} of {_gt} VIs)')
            snap_glyph = (f'<a href="{pages_url}/vi-snapshots/index.html?sha={sha}" '
                          f'class="snap-glyph" title="{_gtip}" aria-label="{_gtip}">{SNAP_ICON}</a>')

    rows_html.append(f"""
    <tr data-project="{proj_flag}">
      <td style="padding:8px;font-family:monospace;font-size:.85em">
        <a href="{pages_url}/vi-snapshots/index.html?sha={sha}" style="color:var(--link)" title="Browse this commit's VIs in the VI Browser">{short}</a>
      </td>
      <td style="padding:8px;font-size:.85em;max-width:320px" title="{html.escape(msg)}"><span style="display:flex;align-items:center;gap:6px;min-width:0"><a href="{pages_url}/vi-snapshots/index.html?sha={sha}" style="color:var(--fg);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0">{html.escape(msg)}</a>{snap_glyph}</span></td>
      <td style="padding:8px;font-size:.82em;color:var(--fg-muted)">{html.escape(author)}</td>
      <td style="padding:8px;font-size:.75em;color:var(--fg-muted)">{date[:10]}</td>
      {mc_badge}
      {via_badge}
      {diff_badge}
      {snap_badge}
      {unit_badge}
      {antidoc_badge}
    </tr>""")

rows = '\n'.join(rows_html)
hist_json = _json.dumps(hist_revs)
now  = __import__('datetime').datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')

# The "Include CI-only revisions" toggle is de-selected by default, so the
# dashboard opens on project revisions (those that change LabVIEW source).
# The toggle is honored strictly: while it is de-selected, CI-only revisions
# stay hidden — there is no automatic override. If that leaves the table
# empty (e.g. during a long CI/tooling sprint where the recent commits don't
# touch VIs), an inline empty-state prompt invites enabling the toggle, so
# the page is never a silently blank table (see the filter script below).

# While something is actively running, poll faster so the live indicator
# (and its eventual result) surfaces promptly; otherwise refresh lazily.
refresh_secs = 60 if running_flag['on'] else 900
refresh_note = ('Live — refreshing every 60 s while CI runs'
                if running_flag['on'] else 'Auto-refreshes every 15 min')

# Title/header brand from the repo at runtime (just the repo name, no owner)
# so a client repo shows ITS own name — not the source repo's — and stays
# correct across tooling updates without any rebrand substitution.
repo_name = repo.split('/')[-1]

# ── Version badge + update notification ─────────────────────
# Read this repo's installed CI tooling version and the source repo it
# pulls tooling from. The badge (left of the toolbar) shows the version.
# Client repos (whose source repo differs from this repo) get a live
# check against the source's catalog and a notification glyph + What's
# New dialog when a newer release exists. The source repo itself always
# runs the latest version, so it needs no check.
_cat = {}
try:
    with open(os.environ.get('CATALOG_PATH', '.github/labview-ci/catalog.json'), encoding='utf-8') as _cf:
        _cat = json.load(_cf)
except Exception:
    _cat = {}
lvci_version   = str(_cat.get('version', '') or '')
_src           = _cat.get('source', {}) or {}
lvci_src_repo  = str(_src.get('repo', '') or '')
lvci_src_ref   = str(_src.get('ref', 'main') or 'main')
# Thin consumers have no catalog.json — fall back to the install manifest
# (.github/labview-ci.yml) for the installed version + source pointer so the
# version badge still works.
if not lvci_version:
    try:
        import re as _re
        _in_src = False
        for _line in open('.github/labview-ci.yml', encoding='utf-8'):
            _m = _re.match(r'^\s*installedVersion:\s*(\S+)', _line)
            if _m: lvci_version = _m.group(1).strip()
            if _re.match(r'^\s*source:\s*$', _line): _in_src = True; continue
            if _in_src:
                _m = _re.match(r'^\s*repo:\s*(\S+)', _line)
                if _m and not lvci_src_repo: lvci_src_repo = _m.group(1).strip()
                _m = _re.match(r'^\s*ref:\s*(\S+)', _line)
                if _m: lvci_src_ref = _m.group(1).strip()
                if _line and not _line[0].isspace(): _in_src = False
    except Exception:
        pass

# Per-repo concurrency cap (config.concurrency.maxParallel in .github/labview-ci.yml,
# default 5). Surfaced on the backfill card so a user queuing all of history knows the
# runs are paced/queued rather than all firing at once.
lvci_max_parallel = 5
try:
    for _cline in open('.github/labview-ci.yml', encoding='utf-8'):
        _cs = _cline.strip()
        if _cs.startswith('maxParallel:'):
            _cv = _cs.split(':', 1)[1].split('#', 1)[0].strip()
            if _cv.isdigit():
                lvci_max_parallel = int(_cv)
            break
except Exception:
    pass
lvci_is_source = (not lvci_src_repo) or (lvci_src_repo.lower() == repo.lower())
lvci_cfg_json  = json.dumps({
    'version': lvci_version, 'sourceRepo': lvci_src_repo,
    'sourceRef': lvci_src_ref, 'isSource': bool(lvci_is_source), 'repo': repo,
})
version_badge_html = ''
version_check_script = ''
if lvci_version:
    _badge_title = ('Latest LabVIEW CI tooling version' if lvci_is_source
                    else 'Installed LabVIEW CI tooling version')
    version_badge_html = (
        '<div id="lvci-version" title="' + _badge_title + '" '
        'style="position:relative;display:inline-flex;align-items:center;gap:6px;'
        'background:rgba(110,118,129,.15);color:var(--fg-muted);'
        'border:1px solid rgba(110,118,129,.35);padding:8px 12px;border-radius:6px;'
        'font-size:.78em;font-weight:600;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;'
        'user-select:none"><span>v' + lvci_version + '</span>'
        '<span id="lvci-update-dot" aria-hidden="true"></span></div>'
    )
    version_check_script = (
        '<style>'
        '#lvci-version.lvci-clickable{cursor:pointer;color:var(--fg)}'
        '#lvci-version.lvci-clickable:hover{background:rgba(110,118,129,.25)}'
        '#lvci-version.lvci-has-update{cursor:pointer;color:var(--fg);'
        'border-color:#d29922;background:rgba(210,153,34,.13)}'
        '#lvci-version.lvci-has-update:hover{background:rgba(210,153,34,.22)}'
        '#lvci-version.lvci-updating{cursor:pointer;color:var(--fg);'
        'border-color:#1f6feb;background:rgba(31,111,235,.14)}'
        '#lvci-version.lvci-updating:hover{background:rgba(31,111,235,.24)}'
        '.lvci-spin{width:10px;height:10px;border:2px solid rgba(88,166,255,.4);'
        'border-top-color:#58a6ff;border-radius:50%;display:inline-block;'
        'animation:lvci-spin-kf .7s linear infinite}'
        '@keyframes lvci-spin-kf{to{transform:rotate(360deg)}}'
        '#lvci-update-dot{display:none}'
        '#lvci-update-dot.on{display:block;position:absolute;top:-5px;right:-5px;'
        'width:11px;height:11px;border-radius:50%;background:#d29922;'
        'box-shadow:0 0 0 2px var(--bg);animation:lvci-pulse 1.7s ease-out infinite}'
        '@keyframes lvci-pulse{0%{box-shadow:0 0 0 2px var(--bg),0 0 0 0 rgba(210,153,34,.5)}'
        '70%{box-shadow:0 0 0 2px var(--bg),0 0 0 7px rgba(210,153,34,0)}'
        '100%{box-shadow:0 0 0 2px var(--bg),0 0 0 0 rgba(210,153,34,0)}}'
        '</style>'
        '<script>(function(){'
        'var C=' + lvci_cfg_json + ';'
        'function cmp(a,b){var p=String(a||"0").split("."),q=String(b||"0").split(".");'
        'for(var i=0;i<Math.max(p.length,q.length);i++){var d=(parseInt(p[i],10)||0)-(parseInt(q[i],10)||0);if(d)return d;}return 0;}'
        'if(!C.version)return;'
        'var b=document.getElementById("lvci-version");if(!b)return;'
        # The badge always opens the release-notes / What's New dialog, whether or
        # not an update exists. A single reassignable action ("act") lets the in-flight
        # branch repoint the click to the running upgrade action without stacking listeners.
        'var src=C.sourceRepo||C.repo;'
        'var go=function(){lvciOpen("whats-new.html?repo="+encodeURIComponent(C.repo)+"&from="+encodeURIComponent(C.version)+"&src="+encodeURIComponent(src)+"&ref="+encodeURIComponent(C.sourceRef),"What\\u2019s New");};'
        'var act=go;'
        'b.classList.add("lvci-clickable");'
        'b.setAttribute("role","button");b.setAttribute("tabindex","0");'
        'b.title="LabVIEW CI v"+C.version+" \\u2014 click for release notes";'
        'b.addEventListener("click",function(){act();});'
        'b.addEventListener("keydown",function(e){if(e.key==="Enter"||e.key===" "){e.preventDefault();act();}});'
        # GitHub API helper. Reuse the Run-now dispatch token if present (higher rate
        # limit); otherwise unauthenticated, which works for public repos.
        'function tok(){try{return localStorage.getItem("lvci_dispatch_token")||"";}catch(e){return "";}}'
        'function api(p){var h={"Accept":"application/vnd.github+json","X-GitHub-Api-Version":"2022-11-28"};var t=tok();if(t)h.Authorization="Bearer "+t;'
        'return fetch("https://api.github.com/repos/"+C.repo+p,{headers:h,cache:"no-store"}).then(function(r){return r.ok?r.json():null;}).catch(function(){return null;});}'
        'function active(runs){var S=["queued","in_progress","requested","waiting","pending"];'
        'return (runs||[]).filter(function(r){return S.indexOf(r.status)>=0&&Date.parse(r.created_at)>Date.now()-2*3600*1000;})[0];}'
        # Replace the version pill with an in-flight "Updating" indicator (spinner +
        # blue) that opens the running action. Takes priority over the update dot.
        'function inflight(label,url,tip){b.classList.remove("lvci-clickable","lvci-has-update");b.classList.add("lvci-updating");'
        'b.textContent="";var sp=document.createElement("span");sp.className="lvci-spin";'
        'var tx=document.createElement("span");tx.textContent=label;b.appendChild(sp);b.appendChild(tx);'
        'b.title=tip;act=function(){window.open(url,"_blank","noopener");};}'
        # Optimistic "Updating" indicator. The apply-tooling-update workflow runs for
        # only a few seconds, so polling for it on a 15-min auto-refresh almost never
        # catches it. When the What's New dialog dispatches the update it records a flag
        # in localStorage (and calls window.lvciMarkUpdating below), so we paint the
        # badge immediately and keep it across refreshes until this build reaches the
        # target version or a 30-min TTL elapses.
        'function updGet(){try{var s=localStorage.getItem("lvci_updating");if(!s)return null;var o=JSON.parse(s);'
        # Dashboards for different repos share one origin (user.github.io) = one
        # localStorage. Ignore (don't clear) a flag written by another repo's dashboard.
        'if(o&&o.repo&&o.repo!==C.repo)return null;'
        'if(!o||!o.v||Date.now()-o.ts>18e5||cmp(C.version,o.v)>=0){localStorage.removeItem("lvci_updating");return null;}return o;}catch(e){return null;}}'
        'function paintUpd(v){inflight("Updating\\u2026","https://github.com/"+C.repo+"/pulls","Updating to v"+v+" \\u2014 click to review or merge the update pull request");}'
        'window.lvciMarkUpdating=function(v){try{localStorage.setItem("lvci_updating",JSON.stringify({v:v,ts:Date.now(),repo:C.repo}));}catch(e){}paintUpd(v);};'
        # The source-of-truth repo never "updates": it ORIGINATES versions. Cutting a
        # release bumps its own catalog ahead of the just-built dashboard, which would
        # otherwise trip the "Updating to vX" redeploy hint below. Skip all updating
        # chrome so the source badge stays a plain release-notes link.
        'if(C.isSource||!C.sourceRepo)return;'
        'var _upd=updGet();if(_upd){paintUpd(_upd.v);return;}'
        # 1) Is the update workflow itself running (just clicked Update now / the PR is
        #    being opened)? -> "Updating..." linking to that run.
        'api("/actions/workflows/apply-tooling-update.yml/runs?per_page=5").then(function(j){'
        'var a=active(j&&j.workflow_runs);'
        'if(a){inflight("Updating\\u2026",a.html_url,"LabVIEW CI update in progress \\u2014 click to view the run");return true;}return false;'
        '}).then(function(done){if(done)return done;'
        # 2) Was an update already merged (this repo\u2019s committed catalog version is newer
        #    than the version THIS page was built at)? Then the dashboard is rebuilding/
        #    deploying \u2014 the exact window where the badge used to silently lag. Show
        #    "Updating to vX..." linking to the in-flight (or latest) dashboard build.
        'return fetch("https://raw.githubusercontent.com/"+C.repo+"/HEAD/.github/labview-ci/catalog.json",{cache:"no-store"})'
        '.then(function(r){return r.ok?r.json():null;}).then(function(cat){'
        'if(!cat||!cat.version||cmp(cat.version,C.version)<=0)return false;'
        'return api("/actions/workflows/dashboard-pages.yml/runs?per_page=3").then(function(j){'
        'var runs=(j&&j.workflow_runs)||[];var r=active(runs)||runs[0];var url=r?r.html_url:("https://github.com/"+C.repo+"/actions");'
        'inflight("Updating to v"+cat.version+"\\u2026",url,"Update to v"+cat.version+" is being deployed \\u2014 click to watch the build");return true;});});'
        '}).then(function(done){if(done)return done;'
        # 3) Otherwise the normal "update available" check (clients only): flag the
        #    badge amber + pulsing dot when the source publishes a newer release.
        #    First follow the relocation pointer (source.json) so a moved project is
        #    compared against its new official home; the badge links to whats-new.html,
        #    which shows the move and re-points this repo on update.
        'if(C.isSource||!C.sourceRepo)return;'
        'var sR=C.sourceRepo,sF=C.sourceRef;'
        'fetch("https://raw.githubusercontent.com/"+sR+"/"+sF+"/.github/labview-ci/source.json",{cache:"no-store"})'
        '.then(function(r){return r.ok?r.json():null;}).then(function(p){'
        'if(p&&p.repo&&p.repo.toLowerCase()!==sR.toLowerCase()){sR=p.repo;sF=p.ref||sF;}'
        'return fetch("https://raw.githubusercontent.com/"+sR+"/"+sF+"/.github/labview-ci/catalog.json",{cache:"no-store"});'
        '}).then(function(r){return r.ok?r.json():null;}).then(function(cat){'
        'if(!cat||!cat.version||cmp(cat.version,C.version)<=0)return;'
        'var d=document.getElementById("lvci-update-dot");'
        'b.classList.remove("lvci-clickable");b.classList.add("lvci-has-update");if(d)d.classList.add("on");'
        'b.title="Update available: v"+C.version+" \\u2192 v"+cat.version+" \\u2014 click to see what\\u2019s new";'
        '}).catch(function(){});});})();</scr' + 'ipt>'
    )

# ── "Run this cell" dialog ──────────────────────────────────
# Styling for the subtle play glyph shown in empty project cells.
run_dialog_css = (
    '.cidash-run{display:inline-block;color:var(--fg-muted);font-size:.95em;'
    'line-height:1;text-decoration:none;opacity:.5;transition:opacity .12s,color .12s}'
    '.cidash-run:hover{opacity:1;color:var(--link);text-decoration:none}'
    'tr:hover .cidash-run{opacity:.85}'
    '.snap-glyph{display:inline-flex;align-items:center;color:var(--fg-muted);'
    'opacity:.6;text-decoration:none;flex:0 0 auto;transition:opacity .12s,color .12s}'
    '.snap-glyph:hover{opacity:1;color:var(--link)}'
    'tr:hover .snap-glyph{opacity:.85}'
    '.cidash-btn{border:1px solid var(--border);border-radius:6px;padding:8px 14px;'
    'font-size:.85em;font-weight:600;cursor:pointer;font-family:inherit}'
    '.cidash-go{background:#238636;color:#fff;border-color:transparent}'
    '.cidash-go:hover{background:#2ea043}.cidash-go:disabled{opacity:.6;cursor:default}'
    '.cidash-ghost{background:var(--bg);color:var(--fg)}'
    '.cidash-ghost:hover{border-color:var(--link)}'
    # Danger button used to cancel a queued run.
    '.cidash-danger{background:#da3633;color:#fff;border-color:transparent}'
    '.cidash-danger:hover{background:#f85149}.cidash-danger:disabled{opacity:.6;cursor:default}'
    # The Queued badge is now a button that opens the manage dialog (view / cancel).
    '.cidash-queued{cursor:pointer}'
    '.cidash-queued:hover{filter:brightness(1.13)}'
    '.cidash-queued:focus-visible{outline:2px solid var(--link);outline-offset:1px}'
    # "#N" place-in-queue chip shown inside the Queued badge when several are waiting.
    '.cidash-qpos{margin-left:5px;font-weight:700;opacity:.92;font-variant-numeric:tabular-nums}'
    '.cidash-qpos:empty{display:none}'
    # "Run all history" backfill card shown above the table on a fresh install.
    '.lvci-backfill{border:1px solid var(--border);border-left:3px solid #1f6feb;'
    'background:var(--surface);border-radius:10px;padding:14px 16px;margin:0 0 18px}'
    '.lvci-bf-main{display:flex;align-items:center;gap:14px;flex-wrap:wrap}'
    '.lvci-bf-icon{font-size:1.5em;line-height:1}'
    '.lvci-bf-text{flex:1 1 320px;min-width:240px;font-size:.9em;line-height:1.5}'
    '.lvci-bf-text strong{display:block;font-size:1.03em;margin-bottom:2px}'
    '.lvci-bf-text span{color:var(--fg-muted)}'
    '.lvci-bf-actions{display:flex;gap:8px;flex-wrap:wrap;align-items:center}'
    '.lvci-bf-tok{margin-top:12px;border-top:1px solid var(--border);padding-top:12px;font-size:.84em;color:var(--fg-muted)}'
    '.lvci-bf-status{font-size:.82em;margin-top:10px}'
    '.lvci-bf-status:empty{display:none}'
    # Concurrency note + the "How concurrency works" disclosure on the backfill card.
    '.lvci-bf-note{display:block;margin-top:8px}'
    '.lvci-bf-info{margin-top:8px;font-size:.92em}'
    '.lvci-bf-info>summary{display:inline-block;cursor:pointer;color:var(--link);list-style:none;font-weight:600}'
    '.lvci-bf-info>summary::-webkit-details-marker{display:none}'
    '.lvci-bf-info>summary:hover{text-decoration:underline}'
    '.lvci-bf-info[open]>summary{margin-bottom:8px}'
    '.lvci-bf-infobody{color:var(--fg-muted);line-height:1.55;border-left:2px solid #1f6feb;padding-left:12px}'
    '.lvci-bf-cfg{display:inline-block;margin-top:8px;color:var(--link);font-weight:600}'
    # "Populate history" dialog — form controls (start-from picker, activity
    # checkboxes, diff-based toggle). Reuses the run-modal chrome + cidash-btn.
    '.cidash-hist-sec{margin:0 0 16px}'
    '.cidash-hist-lbl{display:block;font-size:.72em;font-weight:700;text-transform:uppercase;letter-spacing:.05em;color:var(--fg-muted);margin:0 0 7px}'
    '.cidash-hist-scope{display:flex;flex-direction:column;gap:9px}'
    '.cidash-hist-radio{display:flex;align-items:center;gap:9px;font-size:.9em;cursor:pointer;user-select:none}'
    '.cidash-hist-radio input{accent-color:var(--link);width:15px;height:15px;margin:0;flex:0 0 auto}'
    '.cidash-hist-radio .sub{color:var(--fg-muted);font-size:.88em}'
    '.cidash-hist-rangerow{display:flex;flex-wrap:wrap;gap:10px 14px;align-items:center;padding:2px 0 4px 25px}'
    '.cidash-hist-rangerow label{display:flex;align-items:center;gap:7px;font-size:.84em;color:var(--fg-muted)}'
    '#cidash-hist-from,#cidash-hist-to{padding:7px 9px;background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:6px;font-size:.85em;font-family:inherit;max-width:248px}'
    '.cidash-hist-spectools{display:flex;gap:14px;margin:2px 0 6px 25px;font-size:.8em}'
    '.cidash-hist-spectools a{color:var(--link);cursor:pointer}.cidash-hist-spectools a:hover{text-decoration:underline}'
    '.cidash-hist-speclist{display:flex;flex-direction:column;gap:1px;max-height:210px;overflow:auto;margin-left:25px;padding:5px;border:1px solid var(--border);border-radius:7px;background:var(--bg)}'
    '.cidash-hist-specitem{display:flex;align-items:center;gap:9px;padding:5px 7px;border-radius:5px;font-size:.84em;cursor:pointer;min-width:0}'
    '.cidash-hist-specitem:hover{background:var(--surface)}'
    '.cidash-hist-specitem input{accent-color:var(--link);width:14px;height:14px;margin:0;flex:0 0 auto}'
    '.cidash-hist-specitem .sh{font-family:ui-monospace,Menlo,monospace;color:var(--fg-muted);flex:0 0 auto}'
    '.cidash-hist-specitem .ms{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--fg)}'
    '.cidash-hist-acts{display:flex;flex-direction:column;gap:7px}'
    '.cidash-hist-act{display:flex;align-items:center;gap:9px;padding:8px 11px;border:1px solid var(--border);border-radius:7px;background:var(--bg);cursor:pointer;font-size:.88em;user-select:none}'
    '.cidash-hist-act:hover{border-color:var(--link)}'
    '.cidash-hist-act input{accent-color:var(--link);width:15px;height:15px;margin:0;flex:0 0 auto}'
    '.cidash-hist-act .cidash-hist-actsub{color:var(--fg-muted);font-size:.85em;margin-left:auto;text-align:right}'
    '.cidash-hist-act.disabled{opacity:.45;cursor:default}'
    '.cidash-hist-act.disabled:hover{border-color:var(--border)}'
    '.cidash-hist-toggle{display:flex;align-items:flex-start;gap:10px;padding:11px 13px;border:1px solid var(--border);border-left:3px solid #1f6feb;border-radius:8px;background:var(--surface);cursor:pointer;font-size:.88em;user-select:none}'
    '.cidash-hist-toggle input{accent-color:var(--link);width:15px;height:15px;margin:2px 0 0;flex:0 0 auto}'
    '.cidash-hist-toggle .cidash-hist-tmain{font-weight:600}'
    '.cidash-hist-toggle .cidash-hist-tsub{color:var(--fg-muted);font-size:.9em;margin-top:2px;font-weight:400}'
    '.cidash-hist-summary{font-size:.84em;color:var(--fg-muted);margin:0 0 12px}'
    '.cidash-hist-summary b{color:var(--fg)}'
)
# Modal + controller. Clicking a cell's play glyph opens this; clicking "Run now"
# DISPATCHES the workflow(s) straight to GitHub Actions via the REST API
# (browser -> api.github.com), so the run actually starts — no terminal, no
# copy-paste. Dispatch needs a credential the browser can send, so the user pastes
# a fine-grained token ONCE; it lives only in this browser's localStorage and is
# sent only to api.github.com (never to the repo, the page, or any third party).
# A "Run on GitHub" link is offered as a no-token fallback, and the equivalent
# `gh` command is tucked away for CLI users.
run_dialog = (r"""
  <div id="cidash-run-modal" onclick="if(event.target===this)cidashRunClose()" style="display:none;position:fixed;inset:0;z-index:310;background:rgba(0,0,0,.55)">
    <div role="dialog" aria-modal="true" aria-labelledby="cidash-run-title" style="position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:min(560px,calc(100% - 32px));max-height:calc(100% - 48px);overflow:auto;background:var(--bg);border:1px solid var(--border);border-radius:10px;box-shadow:0 10px 48px rgba(0,0,0,.5)">
      <div style="display:flex;align-items:center;justify-content:space-between;padding:12px 16px;border-bottom:1px solid var(--border);background:var(--surface)">
        <strong id="cidash-run-title" style="font-size:.95em">Run</strong>
        <button onclick="cidashRunClose()" style="background:transparent;border:1px solid var(--border);color:var(--fg);padding:5px 12px;border-radius:6px;cursor:pointer;font-size:.82em">&#10005; Close</button>
      </div>
      <div id="cidash-run-body" style="padding:16px"></div>
    </div>
  </div>
  <div id="cidash-q-modal" onclick="if(event.target===this)cidashQClose()" style="display:none;position:fixed;inset:0;z-index:311;background:rgba(0,0,0,.55)">
    <div role="dialog" aria-modal="true" aria-labelledby="cidash-q-title" style="position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:min(480px,calc(100% - 32px));max-height:calc(100% - 48px);overflow:auto;background:var(--bg);border:1px solid var(--border);border-radius:10px;box-shadow:0 10px 48px rgba(0,0,0,.5)">
      <div style="display:flex;align-items:center;justify-content:space-between;padding:12px 16px;border-bottom:1px solid var(--border);background:var(--surface)">
        <strong id="cidash-q-title" style="font-size:.95em">Queued run</strong>
        <button onclick="cidashQClose()" style="background:transparent;border:1px solid var(--border);color:var(--fg);padding:5px 12px;border-radius:6px;cursor:pointer;font-size:.82em">&#10005; Close</button>
      </div>
      <div id="cidash-q-body" style="padding:16px"></div>
    </div>
  </div>
  <div id="cidash-hist-modal" onclick="if(event.target===this)cidashHistClose()" style="display:none;position:fixed;inset:0;z-index:310;background:rgba(0,0,0,.55)">
    <div role="dialog" aria-modal="true" aria-labelledby="cidash-hist-title" style="position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:min(600px,calc(100% - 32px));max-height:calc(100% - 48px);overflow:auto;background:var(--bg);border:1px solid var(--border);border-radius:10px;box-shadow:0 10px 48px rgba(0,0,0,.5)">
      <div style="display:flex;align-items:center;justify-content:space-between;padding:12px 16px;border-bottom:1px solid var(--border);background:var(--surface)">
        <strong id="cidash-hist-title" style="font-size:.95em">Populate dashboard history</strong>
        <button onclick="cidashHistClose()" style="background:transparent;border:1px solid var(--border);color:var(--fg);padding:5px 12px;border-radius:6px;cursor:pointer;font-size:.82em">&#10005; Close</button>
      </div>
      <div id="cidash-hist-body" style="padding:16px"></div>
    </div>
  </div>
  <script>
  (function(){
    var RT = __RUN_TARGETS__;
    var REPO = "__REPO__";
    var BRANCH = "__BRANCH__";
    var TOK_KEY = "lvci_dispatch_token";
    var state = {cap:null, sha:'', parent:'', short:''};
    function $(id){ return document.getElementById(id); }
    function esc(s){ return String(s==null?'':s).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }
    function fill(t){ return String(t).replace(/\{sha\}/g, state.sha).replace(/\{parent\}/g, state.parent||''); }
    // The dashboard's own dispatch token; if it isn't set, fall back to the token
    // saved during "Apply to New Repo" (lvci_install_token — same browser, same
    // origin) so the SAME token used to set the dashboard up also queues runs here
    // with no second token to create. It still needs Actions: Read and write to
    // dispatch; if it lacks that, the 403 hint explains the one box to add.
    function getTok(){ try{ return localStorage.getItem(TOK_KEY)||localStorage.getItem("lvci_install_token")||''; }catch(e){ return ''; } }
    function setTok(v){ try{ localStorage.setItem(TOK_KEY, v); }catch(e){} }
    function clearTok(){ try{ localStorage.removeItem(TOK_KEY); }catch(e){} }
    function ghCmd(wf, inputs){
      var s = "gh workflow run " + wf + " --ref " + BRANCH;
      Object.keys(inputs).forEach(function(k){ s += " -f " + k + "=" + fill(inputs[k]); });
      return s;
    }
    function actionsUrl(wf){ return "https://github.com/" + REPO + "/actions/workflows/" + wf; }
    // Pre-fill the fine-grained token form: name, resource owner, and the one
    // permission a workflow_dispatch needs (Actions: write). GitHub provides no
    // URL param to pre-select the specific repo, so "Repository access" stays a
    // manual step. Same token (lvci_dispatch_token) the report header + What's New use.
    function tokenSetupUrl(){
      var owner = (REPO.split("/")[0]) || "";
      var qp = "name=" + encodeURIComponent("LabVIEW CI dispatch")
        + "&description=" + encodeURIComponent("Queue LabVIEW CI runs for " + REPO + " (Run now / Re-run / Update).")
        + (owner ? "&target_name=" + encodeURIComponent(owner) : "")
        + "&actions=write";
      return "https://github.com/settings/personal-access-tokens/new?" + qp;
    }
    function cap(s){ return s.charAt(0).toUpperCase() + s.slice(1); }
    function selectedPlats(def){
      var keys = Object.keys(def.platforms);
      if (keys.length === 1) return keys;
      var boxes = keys.map(function(k){ return $("cidash-plat-"+k); });
      if (boxes.every(function(b){ return !b; })) return keys.slice();
      return keys.filter(function(k){ var b = $("cidash-plat-"+k); return b && b.checked; });
    }
    function setStatus(html, kind){
      var s = $("cidash-run-status"); if(!s) return;
      var col = kind==='ok' ? '#3fb950' : (kind==='err' ? '#f85149' : (kind==='warn' ? '#d29922' : 'var(--fg-muted)'));
      s.style.color = col; s.innerHTML = html || '';
    }
    function filledInputs(p){ var o={}; Object.keys(p.inputs).forEach(function(k){ o[k]=fill(p.inputs[k]); }); return o; }
    function dispatchOne(wf, inputs){
      return fetch('https://api.github.com/repos/'+REPO+'/actions/workflows/'+encodeURIComponent(wf)+'/dispatches', {
        method:'POST',
        headers:{ 'Authorization':'Bearer '+getTok(), 'Accept':'application/vnd.github+json',
                  'X-GitHub-Api-Version':'2022-11-28', 'Content-Type':'application/json' },
        body: JSON.stringify({ ref: BRANCH, inputs: inputs })
      }).then(function(r){ return { wf:wf, ok:r.status===204, status:r.status }; })
        .catch(function(e){ return { wf:wf, ok:false, status:0, err:String(e&&e.message||e) }; });
    }
    // ── Optimistic "queued" overlay ──────────────────────────────
    // A successful dispatch returns 204 with no body, and the server-rendered
    // "running" badge only appears once the run posts a pending commit status AND
    // the Pages site rebuilds — minutes later. So the dispatched cell would keep
    // showing its empty run-glyph, making it look like nothing happened. Paint the
    // cell as "Queued" immediately and remember it per-browser (localStorage) so it
    // survives the page's auto-refresh until the real status takes over. Entries
    // self-expire so a run that never reports a status can't wedge a fake spinner.
    var QKEY = "lvci_queued_runs";
    var QTTL = 20*60*1000;   // anti-phantom: drop an entry we could NEVER tie to a real run (no run id) after 20 min
    var QDONE = 5*60*1000;   // after a run finishes OK, keep the cell up to this long while the server result rebuilds
    var QFAST = 60*1000;     // re-check this often while a queued run is unconfirmed
    var qReloadArmed = false;
    var qCapturing = {};     // key -> [callbacks] while a run-id lookup is in flight
    function qLoad(){ try{ return JSON.parse(localStorage.getItem(QKEY)||"{}")||{}; }catch(e){ return {}; } }
    function qSave(o){ try{ localStorage.setItem(QKEY, JSON.stringify(o)); }catch(e){} }
    function qPaint(td, c, sha){
      // Overlay the spinning "Queued" badge onto the cell, replacing its run glyph.
      // The badge is now a BUTTON (not a link): clicking it opens the manage dialog
      // where the run can be viewed on GitHub or cancelled. A "#N" chip (filled in
      // by qRenumber) shows the run's place in the queue when several are waiting.
      if(!td) return;
      td.classList.add('cidash-queued-cell');
      td.setAttribute('data-qcap', c); td.setAttribute('data-qsha', sha);
      td.innerHTML = '<span class="run-badge cidash-queued" role="button" tabindex="0" '
        + 'title="Queued from this browser \u2014 click to view it on GitHub or cancel it">'
        + '<span class="run-spin"></span>Queued<span class="cidash-qpos"></span></span>';
    }
    function qPaintFailed(td, c, sha){
      // A run we CONFIRMED failed on GitHub: replace the spinner with a sticky red
      // "bang" badge (same button affordance as Queued, so clicking opens the
      // manage dialog to view the failed run or dismiss it). Never reverts on its own.
      if(!td) return;
      td.classList.add('cidash-queued-cell');
      td.setAttribute('data-qcap', c); td.setAttribute('data-qsha', sha);
      td.innerHTML = '<span class="run-badge cidash-queued cidash-failed" role="button" tabindex="0" '
        + 'title="This run failed \u2014 click to see the error on GitHub or dismiss it">'
        + '<span class="cidash-bang" aria-hidden="true">!</span>Failed</span>';
    }
    function qArmReload(){
      // While a queued run is still unconfirmed, reload sooner than the lazy
      // meta-refresh so the real status surfaces promptly (mirrors the server's
      // own faster cadence while CI is live).
      if(qReloadArmed) return; qReloadArmed = true;
      setTimeout(function(){ location.reload(); }, QFAST);
    }
    function qLiveEntries(o){
      // The still-queued entries, oldest first - this IS the queue order. A failed
      // or finished entry is terminal so it is no longer "in line". An entry stays
      // while we can still reconcile its real run (a captured run id + a token),
      // while inside the optimistic window, OR while qSync still sees a run active
      // (e.activeAt), so a run held behind GitHub's concurrency cap keeps its place.
      var now = Date.now(); var tok = getTok();
      return Object.keys(o)
        .filter(function(k){ var e=o[k]; if(!e || e.failed || e.done) return false;
          var hasRun = (e.runs||[]).some(function(r){ return r && r.id; });
          return (hasRun && tok) || (now-(e.ts||0))<=QTTL || (e.activeAt && (now-e.activeAt)<=QTTL); })
        .map(function(k){ return { key:k, ts:o[k].ts||0 }; })
        .sort(function(a,b){ return a.ts - b.ts; });
    }
    function qRenumber(){
      // Number the optimistic queued cells by the order they were queued (oldest
      // = #1) so the user can see each run's place in the line. The chip is hidden
      // when only one run is queued (a position is only meaningful among several).
      var o = qLoad(); var live = qLiveEntries(o); var show = live.length > 1;
      live.forEach(function(en, idx){
        var i = en.key.indexOf('|'); var c = en.key.slice(0,i); var sha = en.key.slice(i+1);
        var td = document.querySelector('td.cidash-queued-cell[data-qcap="'+c+'"][data-qsha="'+sha+'"]');
        if(!td) return;
        var pos = td.querySelector('.cidash-qpos');
        if(pos) pos.textContent = show ? ('#'+(idx+1)) : '';
      });
    }
    function markQueued(c, sha, plats, parent, ts){
      var o = qLoad();
      o[c+'|'+sha] = { ts: ts || Date.now(), plats: plats||[], parent: parent||'', short: (sha||'').slice(0,7), runs: [] };
      qSave(o);
      var a = document.querySelector('a.cidash-run[data-cap="'+c+'"][data-sha="'+sha+'"]');
      var td = a ? (a.closest ? a.closest('td') : null)
                 : document.querySelector('td.cidash-queued-cell[data-qcap="'+c+'"][data-qsha="'+sha+'"]');
      qPaint(td, c, sha);
      qArmReload();
      qRenumber();
    }
    function qForget(c, sha){
      // Drop the optimistic entry and restore the cell's run glyph so the cell is
      // immediately actionable again (re-run) without waiting for a reload.
      var o = qLoad(); var entry = o[c+'|'+sha];
      delete o[c+'|'+sha]; qSave(o);
      var td = document.querySelector('td.cidash-queued-cell[data-qcap="'+c+'"][data-qsha="'+sha+'"]');
      if(td){
        td.classList.remove('cidash-queued-cell');
        td.removeAttribute('data-qcap'); td.removeAttribute('data-qsha');
        if(entry && entry.orig){
          // Result cell (re-run overlay) — restore its original status badge.
          td.innerHTML = entry.orig;
        } else {
          var parent = (entry && entry.parent) || '';
          var short = (entry && entry.short) || sha.slice(0,7);
          var label = (RT[c] && RT[c].label) || c;
          td.innerHTML = '<a href="#" class="cidash-run" data-cap="'+esc(c)+'" data-sha="'+esc(sha)+'" '
            + 'data-parent="'+esc(parent)+'" data-short="'+esc(short)+'" '
            + 'title="Run '+esc(label)+' for commit '+esc(short)+'">\u25B7</a>';
        }
      }
      qRenumber();
    }
    function entryItems(c, entry){
      // The (workflow, platform) pairs this queued entry dispatched.
      var def = RT[c]; if(!def || !entry) return [];
      return (entry.plats||[]).map(function(plat){
        var p = def.platforms[plat]; return p ? { wf: p.wf, plat: plat } : null;
      }).filter(function(x){ return x; });
    }
    function claimedRunIds(){
      // Run ids already attributed to some queued cell, so a lookup never grabs a
      // run that belongs to a different cell.
      var o = qLoad(); var s = {};
      Object.keys(o).forEach(function(k){ ((o[k]||{}).runs||[]).forEach(function(r){ if(r && r.id) s[r.id]=1; }); });
      return s;
    }
    function captureRuns(c, sha, attempt, cb){
      // A workflow_dispatch returns 204 with no run id, so to later CANCEL the run
      // (and link straight to it) we look it up: poll the workflow's recent
      // dispatch runs and claim the freshest active one we have not already
      // attributed to another cell. Best-effort, non-blocking, and self-limiting.
      // Concurrent lookups for the SAME cell (e.g. the manage dialog opening AND a
      // Cancel click) are coalesced so they share one network pass and both get
      // their callback when it resolves — no duplicate claims, no stalled retries.
      var key = c+'|'+sha;
      attempt = attempt || 1;
      if(attempt === 1){
        if(qCapturing[key]){ if(cb) qCapturing[key].push(cb); return; }
        qCapturing[key] = cb ? [cb] : [];
      }
      function done(){ var cbs = qCapturing[key] || []; delete qCapturing[key]; cbs.forEach(function(fn){ try{ fn(); }catch(e){} }); }
      var tok = getTok(); if(!tok){ done(); return; }
      var entry = qLoad()[key];
      if(!entry){ done(); return; }
      var need = entryItems(c, entry).filter(function(it){
        return !((entry.runs||[]).some(function(r){ return r.plat===it.plat; }));
      });
      if(!need.length){ done(); return; }
      var t0 = entry.ts || Date.now();
      var byWf = {}; need.forEach(function(it){ (byWf[it.wf]=byWf[it.wf]||[]).push(it.plat); });
      Promise.all(Object.keys(byWf).map(function(wf){
        return fetch('https://api.github.com/repos/'+REPO+'/actions/workflows/'+encodeURIComponent(wf)+'/runs?event=workflow_dispatch&per_page=20',
          { headers:{ 'Authorization':'Bearer '+tok, 'Accept':'application/vnd.github+json', 'X-GitHub-Api-Version':'2022-11-28' } })
          .then(function(r){ return r.ok ? r.json() : null; })
          .then(function(j){ return { wf: wf, runs: (j&&j.workflow_runs)||[] }; })
          .catch(function(){ return { wf: wf, runs: [] }; });
      })).then(function(resps){
        var claim = claimedRunIds();
        var o = qLoad(); var e = o[key]; if(!e){ done(); return; }
        e.runs = e.runs || [];
        var have = {}; e.runs.forEach(function(r){ have[r.plat]=1; });
        resps.forEach(function(rp){
          var cands = rp.runs.filter(function(run){
            var created = Date.parse(run.created_at || run.run_started_at || 0);
            var active = ['queued','in_progress','requested','waiting','pending','action_required'].indexOf(run.status) >= 0;
            return active && created >= (t0 - 12000) && !claim[run.id];
          }).sort(function(a,b){ return Date.parse(b.created_at) - Date.parse(a.created_at); });
          (byWf[rp.wf]||[]).forEach(function(plat){
            if(have[plat]) return;
            var run = cands.shift(); if(!run) return;
            e.runs.push({ wf: rp.wf, plat: plat, id: run.id, url: run.html_url, status: run.status });
            claim[run.id] = 1; have[plat] = 1;
          });
        });
        o[key] = e; qSave(o);
        var gotAll = entryItems(c, e).every(function(it){ return (e.runs||[]).some(function(r){ return r.plat===it.plat; }); });
        if(!gotAll && attempt < 5){ setTimeout(function(){ captureRuns(c, sha, attempt+1, null); }, 2000); }
        else { done(); }
      });
    }
    function captureSnapshotRun(t0, attempt){
      // The "Populate history" backfill is ONE snapshots run that walks the whole
      // history, so every "snapshots|<sha>" entry shares it. captureRuns' per-cell
      // claim would hand the single run to just the first sha, so look it up once
      // and write it into EVERY snapshot entry still missing a run id.
      var tok = getTok(); if(!tok) return;
      t0 = t0 || Date.now(); attempt = attempt || 1;
      fetch('https://api.github.com/repos/'+REPO+'/actions/workflows/'+encodeURIComponent('vi-snapshots.yml')+'/runs?event=workflow_dispatch&per_page=20',
        { headers:{ 'Authorization':'Bearer '+tok, 'Accept':'application/vnd.github+json', 'X-GitHub-Api-Version':'2022-11-28' } })
        .then(function(r){ return r.ok ? r.json() : null; })
        .then(function(j){
          var runs = (j && j.workflow_runs) || [];
          var run = runs.filter(function(rn){
            return Date.parse(rn.created_at || rn.run_started_at || 0) >= (t0 - 12000);
          }).sort(function(a,b){ return Date.parse(b.created_at) - Date.parse(a.created_at); })[0];
          if(!run){ if(attempt < 4){ setTimeout(function(){ captureSnapshotRun(t0, attempt+1); }, 2500); } return; }
          var o = qLoad(); var changed = false;
          Object.keys(o).forEach(function(key){
            if(key.indexOf('snapshots|') !== 0) return;
            var e = o[key]; if(!e || (e.runs||[]).length) return;
            e.runs = [{ wf:'vi-snapshots.yml', plat:'all', id:run.id, url:run.html_url, status:run.status }];
            changed = true;
          });
          if(changed) qSave(o);
        }).catch(function(){});
    }
    function qSync(){
      // Reconcile the optimistic "Queued" overlays against the REAL run status on
      // GitHub so a cell never silently reverts to its run glyph: a run still
      // queued/running keeps its badge alive (so a run held behind GitHub's
      // concurrency cap keeps its badge for as long as it takes), a run that
      // FAILED becomes a sticky red "bang" badge (an early failure may never post
      // a commit status for the server to render), and a finished-OK run is marked
      // done so the server result can take over. Runs are matched by their captured
      // id and looked up directly when too old to appear in the recent activity
      // list, so this still works when you come back to the dashboard much later.
      var tok = getTok(); if(!tok) return;
      var o = qLoad();
      var live = Object.keys(o).filter(function(k){ return o[k] && !o[k].failed && !o[k].done; });
      if(!live.length) return;
      var snapTs = 0, snapNeedsId = false;
      live.forEach(function(k){
        if(k.indexOf('snapshots|')===0){ var ts=o[k].ts||0; if(!snapTs||ts<snapTs) snapTs=ts; if(!((o[k].runs||[]).length)) snapNeedsId=true; }
      });
      if(snapNeedsId) captureSnapshotRun(snapTs);
      live.forEach(function(k){
        var c = k.slice(0, k.indexOf('|')); var sha = k.slice(k.indexOf('|')+1);
        if(c!=='snapshots' && !((o[k].runs||[]).length)) captureRuns(c, sha);
      });
      // Every run id we still need a verdict on, across all non-terminal entries.
      var wantIds = {};
      live.forEach(function(k){ ((o[k]||{}).runs||[]).forEach(function(r){ if(r && r.id) wantIds[r.id]=1; }); });
      fetch('https://api.github.com/repos/'+REPO+'/actions/runs?per_page=100',
        { headers:{ 'Authorization':'Bearer '+tok, 'Accept':'application/vnd.github+json', 'X-GitHub-Api-Version':'2022-11-28' } })
        .then(function(r){ return r.ok ? r.json() : null; })
        .then(function(j){
          var byId = {}; if(j && j.workflow_runs){ j.workflow_runs.forEach(function(run){ byId[run.id] = run; }); }
          // A run from an earlier session can be too old for the recent list; fetch
          // those directly by id so a long-finished (or still-queued) run is still
          // reconciled. Capped so a big backlog can't fan out into many requests.
          var miss = Object.keys(wantIds).filter(function(id){ return !byId[id]; }).slice(0, 12);
          return Promise.all(miss.map(function(id){
            return fetch('https://api.github.com/repos/'+REPO+'/actions/runs/'+id,
              { headers:{ 'Authorization':'Bearer '+tok, 'Accept':'application/vnd.github+json', 'X-GitHub-Api-Version':'2022-11-28' } })
              .then(function(r){ return r.ok ? r.json() : null; })
              .then(function(run){ if(run && run.id) byId[run.id] = run; })
              .catch(function(){});
          })).then(function(){ return byId; });
        })
        .then(function(byId){
          if(!byId) return;
          var o2 = qLoad(); var changed = false; var now = Date.now();
          var FAIL = ['failure','timed_out','startup_failure','cancelled'];
          var ACTIVE = ['queued','in_progress','requested','waiting','pending','action_required'];
          Object.keys(o2).forEach(function(key){
            var e = o2[key]; if(!e || e.failed || e.done) return;
            var ids = (e.runs||[]).map(function(r){ return r.id; }).filter(Boolean);
            if(!ids.length) return;
            var anyActive = false, anyFail = false, allKnown = true, allDone = true, failUrl = '';
            ids.forEach(function(id){
              var run = byId[id]; if(!run){ allKnown = false; allDone = false; return; }
              if(ACTIVE.indexOf(run.status) >= 0){ anyActive = true; allDone = false; }
              else if(run.status === 'completed'){ if(FAIL.indexOf(run.conclusion) >= 0){ anyFail = true; failUrl = failUrl || run.html_url || ''; } }
              else { allDone = false; }
            });
            if(anyActive){ e.activeAt = now; changed = true; }
            else if(anyFail && allKnown){ e.failed = { url: failUrl }; changed = true; }
            else if(allKnown && allDone){ e.done = now; changed = true; }
          });
          if(changed){ qSave(o2); applyQueued(); }
        }).catch(function(){});
    }
    function applyQueued(){
      // Re-apply remembered queued badges after each (auto-)reload. A confirmed
      // failure stays a sticky red "bang" badge; a confirmed-finished run hands off
      // to the server result; an entry whose run we can still reconcile (a captured
      // run id + a token) is kept alive until it actually finishes, even past the
      // optimistic window, so a run queued behind GitHub's concurrency cap never
      // silently vanishes. Entries we could never tie to a real run still age out.
      var o = qLoad(); var now = Date.now(); var changed = false; var live = 0; var tok = getTok();
      Object.keys(o).forEach(function(key){
        var e = o[key]; var i = key.indexOf('|'); var c = key.slice(0,i); var sha = key.slice(i+1);
        if(!e){ delete o[key]; changed = true; return; }
        var painted = document.querySelector('td.cidash-queued-cell[data-qcap="'+c+'"][data-qsha="'+sha+'"]');
        var a = document.querySelector('a.cidash-run[data-cap="'+c+'"][data-sha="'+sha+'"]');
        var rc = document.querySelector('td.cidash-cap-cell[data-cap="'+c+'"][data-sha="'+sha+'"]');
        if(e.failed){
          if(rc){
            var frts = Date.parse(rc.getAttribute('data-ts')||'') || 0;
            if(frts && frts > (e.ts||0)){ delete o[key]; changed = true; return; }
          }
          var ftd = painted || (a ? a.closest('td') : null) || rc;
          if(ftd){ if(rc && !e.orig){ e.orig = rc.innerHTML; changed = true; } qPaintFailed(ftd, c, sha); }
          return;
        }
        if(e.done){
          // The run finished OK - hand off to the server-rendered result: forget as
          // soon as a real result cell is present, or after a short grace for the
          // Pages site to rebuild; until then it keeps showing the spinner below.
          if(rc){ delete o[key]; changed = true; return; }
          if((now - (e.done||0)) > QDONE){ delete o[key]; changed = true; return; }
        }
        var hasRun = (e.runs||[]).some(function(r){ return r && r.id; });
        var alive = (hasRun && tok) || (now - (e.ts||0)) <= QTTL || (e.activeAt && (now - e.activeAt) <= QTTL);
        if(!alive){ delete o[key]; changed = true; return; }
        if(painted){ live++; }
        else if(a){ qPaint(a.closest('td'), c, sha); live++; }
        else if(rc){
          var rts = Date.parse(rc.getAttribute('data-ts')||'') || 0;
          if(rts && rts > (e.ts||0)){ delete o[key]; changed = true; }
          else { if(!e.orig){ e.orig = rc.innerHTML; changed = true; } qPaint(rc, c, sha); live++; }
        }
        else { delete o[key]; changed = true; }
      });
      if(changed) qSave(o);
      if(live > 0) qArmReload();
      qRenumber();
    }
    function runNow(){
      var def = RT[state.cap]; if(!def) return;
      var sel = selectedPlats(def);
      if(!sel.length){ setStatus('Select at least one platform.', 'warn'); return; }
      if(!getTok()){ showTokenPanel(); return; }
      var go = $("cidash-run-go"); if(go){ go.disabled = true; }
      setStatus('Queuing\u2026', null);
      var t0 = Date.now();   // dispatch start — used to match the new run(s) for cancel
      var jobs = sel.map(function(k){ var p=def.platforms[k];
        return dispatchOne(p.wf, filledInputs(p)).then(function(res){ res.plat=k; return res; }); });
      Promise.all(jobs).then(function(results){
        if(go){ go.disabled = false; }
        if(results.some(function(r){return r.status===401;})){
          clearTok(); setStatus('That token was rejected (401). Paste a valid one.', 'err'); showTokenPanel(); return;
        }
        // Reflect any successful dispatch on the dashboard right away, before the
        // server-side status/Pages rebuild catches up (covers partial success too).
        var okPlats = results.filter(function(r){return r.ok;}).map(function(r){return r.plat;});
        if(okPlats.length){ markQueued(state.cap, state.sha, okPlats, state.parent, t0); captureRuns(state.cap, state.sha); }
        if(results.every(function(r){return r.ok;})){
          var n=results.length;
          setStatus('\u2713 Queued '+n+' run'+(n>1?'s':'')+'. <a href="https://github.com/'+REPO+'/actions" target="_blank" rel="noopener" style="color:var(--link)">View runs \u2197</a>', 'ok');
        } else {
          var multi = Object.keys(RT[state.cap].platforms).length > 1;
          var parts = results.map(function(r){ return (multi?cap(r.plat)+': ':'') + (r.ok?'queued':('HTTP '+r.status)); });
          var has403 = results.some(function(r){return r.status===403;});
          var has404 = results.some(function(r){return r.status===404;});
          var hint;
          if (has403) hint = ' \u2014 <strong>403</strong>: the token is missing the <strong>Actions: Read and write</strong> permission. On the token page open <strong>Permissions \u2192 Repository permissions \u2192 Actions \u2192 Read and write</strong> (selecting the repository is not enough), then <strong>Update</strong> and run again.';
          else if (has404) hint = ' \u2014 <strong>404</strong>: the token cannot see <code>'+esc(REPO)+'</code>. Grant it <strong>Repository access</strong> to this repo AND the <strong>Actions: Read and write</strong> permission.';
          else hint = ' \u2014 check the token has <strong>Actions: Read and write</strong> on this repository.';
          setStatus(parts.join(' \u00b7 ') + hint + ' <a href="#" id="cidash-fixtok" style="color:var(--link);white-space:nowrap">Update token \u2192</a>', 'err');
          var ft=$("cidash-fixtok"); if(ft) ft.addEventListener('click', function(e){ e.preventDefault(); showTokenPanel(); });
        }
      });
    }
    function showTokenPanel(){ var p=$("cidash-tok-panel"); if(p){ p.style.display='block'; var i=$("cidash-tok-input"); if(i) i.focus(); } }
    function hideTokenPanel(){ var p=$("cidash-tok-panel"); if(p){ p.style.display='none'; } }
    function saveTokAndRun(){ var i=$("cidash-tok-input"); var v=(i&&i.value||'').trim(); if(!v){ if(i) i.focus(); return; } setTok(v); hideTokenPanel(); runNow(); }
    function render(){
      var def = RT[state.cap]; if(!def) return;
      var keys = Object.keys(def.platforms);
      var multi = keys.length > 1;
      var sel = selectedPlats(def);
      var haveTok = !!getTok();
      var h = '';
      h += '<p style="margin:0 0 12px;color:var(--fg-muted);font-size:.85em">Run <strong>'+esc(def.label)+'</strong> for commit <code style="font-family:monospace">'+esc(state.short)+'</code>. Click <strong>Run now</strong> and it is queued on GitHub Actions \u2014 no terminal.</p>';
      if (multi){
        h += '<div style="display:flex;gap:18px;margin:0 0 14px;font-size:.9em">';
        keys.forEach(function(k){
          h += '<label style="display:inline-flex;align-items:center;gap:6px;cursor:pointer"><input type="checkbox" class="cidash-plat" id="cidash-plat-'+k+'" '+(sel.indexOf(k)>=0?'checked':'')+' style="accent-color:var(--link)">'+esc(cap(k))+'</label>';
        });
        h += '</div>';
      }
      // One-time token setup panel (hidden until needed).
      h += '<div id="cidash-tok-panel" style="display:none;border:1px solid var(--border);border-radius:8px;padding:12px;background:var(--surface);margin:0 0 12px">';
      h += '<div style="font-size:.82em;color:var(--fg);font-weight:600;margin-bottom:6px">One-time setup \u2014 a token to queue runs</div>';
      h += '<ol style="font-size:.8em;color:var(--fg-muted);margin:0 0 8px;padding-left:18px;line-height:1.6">';
      h += '<li><a href="'+tokenSetupUrl()+'" target="_blank" rel="noopener" style="color:var(--link)">Create a fine-grained token \u2197</a> \u2014 opens with the name, owner, and <strong>Actions: Read and write</strong> already set.</li>';
      h += '<li><strong>Repository access</strong> \u2192 Only select repositories \u2192 add <code>'+esc(REPO)+'</code>. <span style="opacity:.8">(the one step a link can\u2019t pre-fill)</span></li>';
      h += '<li><strong>Permissions \u2192 Repository permissions \u2192 Actions \u2192 Read and write</strong>. Required \u2014 selecting the repo alone gives a 403.</li>';
      h += '<li>Generate, then paste it below.</li>';
      h += '</ol>';
      h += '<div style="font-size:.76em;color:var(--fg-muted);margin-bottom:8px">Stored only in this browser (localStorage); sent only to api.github.com \u2014 never to the repo, the page, or CI.</div>';
      h += '<div style="display:flex;gap:8px;flex-wrap:wrap"><input id="cidash-tok-input" type="password" autocomplete="off" placeholder="github_pat_\u2026 or ghp_\u2026" style="flex:1 1 240px;min-width:180px;padding:7px 10px;background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:6px;font-family:ui-monospace,Menlo,monospace;font-size:.8em">';
      h += '<button class="cidash-btn cidash-go" id="cidash-tok-save">Save &amp; run</button>';
      h += '<button class="cidash-btn cidash-ghost" id="cidash-tok-cancel">Cancel</button></div></div>';
      // Status line (dispatch result / hints).
      h += '<div id="cidash-run-status" style="font-size:.82em;min-height:1.2em;margin:0 0 12px"></div>';
      // Primary actions.
      h += '<div style="display:flex;gap:10px;flex-wrap:wrap;align-items:center">';
      h += '<button class="cidash-btn cidash-go" id="cidash-run-go">\u25B6 Run now</button>';
      sel.forEach(function(k){
        h += '<a class="cidash-btn cidash-ghost" style="text-decoration:none" href="'+actionsUrl(def.platforms[k].wf)+'" target="_blank" rel="noopener">Run '+esc(multi?cap(k):def.label)+' on GitHub \u2197</a>';
      });
      if (haveTok){ h += '<button class="cidash-btn cidash-ghost" id="cidash-tok-forget" title="Remove the token saved in this browser">Forget token</button>'; }
      h += '</div>';
      // CLI fallback, collapsed.
      var cmds = sel.map(function(k){ return ghCmd(def.platforms[k].wf, def.platforms[k].inputs); });
      h += '<details style="margin-top:14px"><summary style="cursor:pointer;color:var(--link);font-size:.82em">Prefer the command line?</summary>';
      h += '<div style="position:relative;margin:10px 0 0"><pre id="cidash-run-cmd" style="background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:12px;margin:0;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.78em;white-space:pre-wrap;word-break:break-word">'+esc(cmds.join("\n"))+'</pre>';
      h += '<button onclick="cidashRunCopy()" style="position:absolute;top:8px;right:8px;background:var(--bg);border:1px solid var(--border);color:var(--fg);border-radius:6px;padding:4px 10px;font-size:.74em;cursor:pointer">Copy</button></div>';
      h += '<p style="color:var(--fg-muted);font-size:.76em;margin:8px 0 0">Run with the <a href="https://cli.github.com/" target="_blank" rel="noopener" style="color:var(--link)">GitHub CLI</a>, or use <strong>Run on GitHub</strong> above and paste the SHA into the form.</p></details>';
      $("cidash-run-body").innerHTML = h;
      Array.prototype.forEach.call(document.querySelectorAll('.cidash-plat'), function(b){ b.addEventListener('change', render); });
      var go=$("cidash-run-go"); if(go) go.addEventListener('click', runNow);
      var sv=$("cidash-tok-save"); if(sv) sv.addEventListener('click', saveTokAndRun);
      var cn=$("cidash-tok-cancel"); if(cn) cn.addEventListener('click', hideTokenPanel);
      var fg=$("cidash-tok-forget"); if(fg) fg.addEventListener('click', function(){ clearTok(); render(); setStatus('Token removed from this browser.', null); });
      var ti=$("cidash-tok-input"); if(ti) ti.addEventListener('keydown', function(e){ if(e.key==='Enter'){ e.preventDefault(); saveTokAndRun(); } });
    }
    window.cidashRunCopy = function(){
      var pre = $("cidash-run-cmd"); if(!pre || !navigator.clipboard) return;
      navigator.clipboard.writeText(pre.textContent);
    };
    window.cidashRunClose = function(){ var m=$("cidash-run-modal"); if(m){ m.style.display='none'; } if(!qModalOpen()){ document.body.style.overflow=''; } };
    function openRun(c, sha, parent, short){
      if(!RT[c]) return;
      state = {cap:c, sha:sha||'', parent:parent||'', short:short||''};
      $("cidash-run-title").textContent = "Run " + RT[c].label;
      render();
      $("cidash-run-modal").style.display='block';
      document.body.style.overflow='hidden';
    }
    // ── Manage a queued run: view it on GitHub, or cancel it ──────
    // Clicking a "Queued" badge opens this dialog (rather than jumping straight to
    // the Actions tab) so the user can either follow the run or stop it. Cancel
    // POSTs the runs/{id}/cancel REST API with the same browser token used to queue.
    var qState = { cap:null, sha:'' };
    function qModalOpen(){ var m=$("cidash-q-modal"); return !!(m && m.style.display==='block'); }
    function runModalOpen(){ var m=$("cidash-run-modal"); return !!(m && m.style.display==='block'); }
    window.cidashQClose = function(){ var m=$("cidash-q-modal"); if(m){ m.style.display='none'; } qState={cap:null,sha:''}; if(!runModalOpen()){ document.body.style.overflow=''; } };
    function qSetStatus(html, kind){
      var s = $("cidash-q-status"); if(!s) return;
      var col = kind==='ok' ? '#3fb950' : (kind==='err' ? '#f85149' : (kind==='warn' ? '#d29922' : 'var(--fg-muted)'));
      s.style.color = col; s.innerHTML = html || '';
    }
    function qViewLinks(c, entry){
      // Prefer a direct link to each captured run; else the workflow's runs page
      // (or the repo's Actions tab) so "view" always works even before capture.
      var def = RT[c]; var runs = (entry && entry.runs) || []; var multi = Object.keys(def.platforms).length > 1;
      var out = [];
      if(runs.length){
        runs.forEach(function(r){
          var nm = multi ? cap(r.plat) : def.label;
          out.push('<a class="cidash-btn cidash-ghost" style="text-decoration:none" href="'+esc(r.url||('https://github.com/'+REPO+'/actions'))+'" target="_blank" rel="noopener">View '+esc(nm)+' run \u2197</a>');
        });
      } else {
        var seen = {};
        (entry.plats||[]).forEach(function(plat){
          var p = def.platforms[plat]; if(!p || seen[p.wf]) return; seen[p.wf]=1;
          out.push('<a class="cidash-btn cidash-ghost" style="text-decoration:none" href="'+actionsUrl(p.wf)+'" target="_blank" rel="noopener">View '+esc(def.label)+' runs \u2197</a>');
        });
        if(!out.length){ out.push('<a class="cidash-btn cidash-ghost" style="text-decoration:none" href="https://github.com/'+REPO+'/actions" target="_blank" rel="noopener">View on GitHub Actions \u2197</a>'); }
      }
      return out.join('');
    }
    function renderQ(){
      var c = qState.cap, sha = qState.sha; if(!c) return;
      var o = qLoad(); var entry = o[c+'|'+sha]; var def = RT[c];
      if(!entry || !def){ cidashQClose(); return; }
      var failed = !!entry.failed;
      var plats = (entry.plats||[]).map(cap).join(', ');
      var short = entry.short || sha.slice(0,7);
      var live = qLiveEntries(o); var pos = 0;
      live.forEach(function(en, idx){ if(en.key===c+'|'+sha) pos = idx+1; });
      var h = '';
      h += '<p style="margin:0 0 12px;color:var(--fg-muted);font-size:.85em"><strong>'+esc(def.label)+'</strong> for commit <code style="font-family:monospace">'+esc(short)+'</code>'+(plats?' \u00b7 '+esc(plats):'')+(failed?' \u2014 <span style="color:#f85149">this run failed</span>.':'.')+'</p>';
      if(!failed && live.length>1 && pos){ h += '<p style="margin:0 0 12px;font-size:.85em">Place in queue: <strong>#'+pos+'</strong> <span style="color:var(--fg-muted)">of '+live.length+' queued from this browser (oldest first).</span></p>'; }
      h += '<div id="cidash-q-status" style="font-size:.82em;min-height:1.2em;margin:0 0 12px"></div>';
      h += '<div style="display:flex;gap:10px;flex-wrap:wrap;align-items:center">';
      h += qViewLinks(c, entry);
      if(failed){ h += '<button class="cidash-btn cidash-ghost" id="cidash-q-dismiss">Dismiss</button>'; }
      else { h += '<button class="cidash-btn cidash-danger" id="cidash-q-cancel">\u2715 Cancel run</button>'; }
      h += '</div>';
      if(failed){ h += '<p style="color:var(--fg-muted);font-size:.76em;margin:12px 0 0"><strong>View</strong> opens the failed run on GitHub to see what went wrong. <strong>Dismiss</strong> clears this badge so you can run it again from the dashboard.</p>'; }
      else { h += '<p style="color:var(--fg-muted);font-size:.76em;margin:12px 0 0"><strong>Cancel run</strong> stops it on GitHub Actions (uses the same token you queued it with). <strong>View</strong> opens it on GitHub, where you can watch it or stop it manually.</p>'; }
      $("cidash-q-body").innerHTML = h;
      var cb=$("cidash-q-cancel"); if(cb) cb.addEventListener('click', function(){ cancelQueued(c, sha); });
      var db=$("cidash-q-dismiss"); if(db) db.addEventListener('click', function(){ qForget(c, sha); cidashQClose(); });
    }
    function openQ(c, sha){
      if(!RT[c]) return;
      qState = { cap:c, sha:sha };
      var entry = qLoad()[c+'|'+sha];
      $("cidash-q-title").textContent = (entry && entry.failed ? "Failed: " : "Queued: ") + RT[c].label;
      renderQ();
      $("cidash-q-modal").style.display='block';
      document.body.style.overflow='hidden';
      // Look up the run id(s) now (if not captured yet) so Cancel + the direct run
      // links resolve; re-render when they arrive.
      if(entry && !((entry.runs||[]).length)){
        captureRuns(c, sha, 1, function(){ if(qState.cap===c && qState.sha===sha) renderQ(); });
      }
    }
    function cancelQueued(c, sha){
      var entry = qLoad()[c+'|'+sha]; if(!entry){ cidashQClose(); return; }
      if(!getTok()){ qSetStatus('No token in this browser \u2014 use \u201cView on GitHub Actions\u201d to cancel it there.', 'warn'); return; }
      var btn = $("cidash-q-cancel"); if(btn){ btn.disabled = true; }
      var runs = (entry.runs||[]).filter(function(r){ return r && r.id; });
      if(runs.length){ doCancel(c, sha, runs); return; }
      // No run id captured yet — try one more lookup before giving up.
      qSetStatus('Finding the run\u2026', null);
      captureRuns(c, sha, 1, function(){
        var r2 = ((qLoad()[c+'|'+sha]||{}).runs||[]).filter(function(r){ return r && r.id; });
        if(!r2.length){ if(btn){ btn.disabled=false; } qSetStatus('Could not find the run automatically \u2014 use \u201cView on GitHub Actions\u201d to cancel it there.', 'err'); return; }
        doCancel(c, sha, r2);
      });
    }
    function doCancel(c, sha, runs){
      var tok = getTok();
      qSetStatus('Cancelling\u2026', null);
      var jobs = runs.map(function(r){
        return fetch('https://api.github.com/repos/'+REPO+'/actions/runs/'+r.id+'/cancel', {
          method:'POST', headers:{ 'Authorization':'Bearer '+tok, 'Accept':'application/vnd.github+json', 'X-GitHub-Api-Version':'2022-11-28' }
        }).then(function(resp){ return { id:r.id, ok:(resp.status===202||resp.status===409), status:resp.status }; })
          .catch(function(){ return { id:r.id, ok:false, status:0 }; });
      });
      Promise.all(jobs).then(function(res){
        var btn = $("cidash-q-cancel");
        if(res.some(function(r){return r.status===401;})){ clearTok(); if(btn){ btn.disabled=false; } qSetStatus('That token was rejected (401). Re-queue with a valid token, or cancel it on GitHub.', 'err'); return; }
        if(res.every(function(r){return r.ok;})){
          qForget(c, sha);
          qSetStatus('\u2713 Cancelled \u2014 the run is stopping on GitHub.', 'ok');
          setTimeout(cidashQClose, 1100);
        } else {
          if(btn){ btn.disabled=false; }
          var has403 = res.some(function(r){return r.status===403;});
          var hint = has403 ? ' The token needs <strong>Actions: Read and write</strong> on this repo.' : '';
          qSetStatus('Could not cancel ('+res.map(function(r){return 'HTTP '+r.status;}).join(', ')+').'+hint+' Use \u201cView on GitHub Actions\u201d to stop it there.', 'err');
        }
      });
    }
    document.addEventListener('click', function(e){
      var a = e.target.closest ? e.target.closest('a.cidash-run') : null;
      if(!a) return;
      e.preventDefault();
      openRun(a.getAttribute('data-cap'), a.getAttribute('data-sha'), a.getAttribute('data-parent'), a.getAttribute('data-short'));
    });
    document.addEventListener('click', function(e){
      var b = e.target.closest ? e.target.closest('.cidash-queued') : null;
      if(!b) return;
      e.preventDefault();
      var td = b.closest ? b.closest('td') : null; if(!td) return;
      openQ(td.getAttribute('data-qcap'), td.getAttribute('data-qsha'));
    });
    document.addEventListener('keydown', function(e){
      if((e.key==='Enter' || e.key===' ') && e.target && e.target.classList && e.target.classList.contains('cidash-queued')){
        e.preventDefault();
        var td = e.target.closest ? e.target.closest('td') : null;
        if(td) openQ(td.getAttribute('data-qcap'), td.getAttribute('data-qsha'));
      }
    });
    document.addEventListener('keydown', function(e){ if(e.key==='Escape'){ if(qModalOpen()) cidashQClose(); else cidashRunClose(); } });
    // ── "Run all history" backfill card ──────────────────────────────
    // On a fresh dashboard (gated server-side: no results, nothing running) the
    // card offers to queue CI for the WHOLE history in one click, oldest commit
    // first. Snapshots are not per-commit (every snapshot cell dispatches the same
    // gallery workflow), so instead of one run per row we fire a SINGLE run in the
    // workflow's "backfill" mode — it walks history oldest→newest and seeds from
    // the already-deployed gallery, so nothing is rendered twice. Mass Compile /
    // VI Analyzer / VIDiff are per-revision, so those are dispatched once each,
    // oldest first and gently throttled. The card self-hides once anything is
    // queued and can be dismissed (remembered per repo).
    var BF_DISMISS_KEY = "lvci_backfill_dismissed";
    function bfCard(){ return document.getElementById('lvci-backfill'); }
    function bfDismissed(){ try{ return localStorage.getItem(BF_DISMISS_KEY) === REPO; }catch(e){ return false; } }
    function bfHide(){ var c=bfCard(); if(c) c.style.display='none'; }
    function bfDismiss(){ try{ localStorage.setItem(BF_DISMISS_KEY, REPO); }catch(e){} bfHide(); }
    function bfTokPanel(show){ var p=document.getElementById('lvci-bf-tok'); if(p) p.style.display = show ? 'block' : 'none'; }
    function bfStatus(html, kind){
      var s=document.getElementById('lvci-bf-status'); if(!s) return;
      var col = kind==='ok' ? '#3fb950' : (kind==='err' ? '#f85149' : (kind==='warn' ? '#d29922' : 'var(--fg-muted)'));
      s.style.color=col; s.innerHTML=html||'';
    }
    function bfCells(){
      // Every empty run-glyph paired with its row order. The table is rendered
      // newest-first, so a larger row index = an older commit; dispatching in
      // descending row order is therefore oldest-first.
      var out=[]; var rows=document.querySelectorAll('tbody tr[data-project]');
      Array.prototype.forEach.call(rows, function(tr, idx){
        Array.prototype.forEach.call(tr.querySelectorAll('a.cidash-run'), function(a){
          out.push({ cap:a.getAttribute('data-cap'), sha:a.getAttribute('data-sha'),
                     parent:a.getAttribute('data-parent')||'', order:idx });
        });
      });
      return out;
    }
    function bfShow(){
      var c=bfCard(); if(!c) return;
      // Hide on a repo we've dismissed, or once anything has been queued from here
      // ("disappear after anything is run"); otherwise show with a live count.
      var queued = Object.keys(qLoad()).length > 0;
      if(bfDismissed() || queued){ c.style.display='none'; return; }
      var cells=bfCells(); if(!cells.length){ c.style.display='none'; return; }
      var shas={}; cells.forEach(function(x){ shas[x.sha]=1; });
      var n=document.getElementById('lvci-bf-count'); if(n) n.textContent=String(Object.keys(shas).length);
      c.style.display='';
    }
    function bfFill(t, sha, parent){ return String(t).replace(/\{sha\}/g, sha).replace(/\{parent\}/g, parent||''); }
    function bfInputs(p, sha, parent){ var o={}; Object.keys(p.inputs).forEach(function(k){ o[k]=bfFill(p.inputs[k], sha, parent); }); return o; }
    // Shared dispatch engine for BOTH the fresh-install backfill card and the
    // Populate-history dialog: queue a set of empty run-cells, snapshots as ONE
    // backfill run (the workflow walks the whole history oldest->newest and dedupes)
    // and the per-revision activities oldest-first, gently throttled so a long
    // history doesn't trip GitHub's secondary rate limits. Resolves with an
    // {ok, err, total} tally; the caller owns its own status line + buttons.
    function dispatchCells(cells, statusFn){
      var perRev=[]; var snapShas=[]; var sawSnap=false;
      cells.forEach(function(x){
        if(x.cap==='snapshots'){ sawSnap=true; snapShas.push(x.sha); }
        else if(!(x.cap==='vidiff' && !x.parent)){ perRev.push(x); }   // a root commit has no base to diff
      });
      perRev.sort(function(a,b){ return b.order - a.order; });   // oldest first
      var total=perRev.length + (sawSnap?1:0);
      var t0=Date.now(); var ok=0, err=0, done=0;
      statusFn('Queuing '+total+' workflow'+(total>1?'s':'')+'\u2026', null);
      var chain=Promise.resolve();
      // 1) Snapshots — one backfill run for the whole history (oldest→newest, deduped).
      if(sawSnap){
        chain=chain.then(function(){
          return dispatchOne('vi-snapshots.yml', { mode:'backfill' }).then(function(r){
            done++;
            if(r.ok){ ok++; snapShas.forEach(function(sha){ markQueued('snapshots', sha, ['all'], '', t0); }); captureSnapshotRun(t0); }
            else { err++; if(r.status===401) clearTok(); }
            statusFn('Queuing\u2026 '+done+'/'+total, null);
          });
        });
      }
      // 2) Per-revision capabilities, oldest first, gently throttled.
      perRev.forEach(function(x){
        chain=chain.then(function(){
          var def=RT[x.cap]; if(!def){ return; }
          var plats=Object.keys(def.platforms);
          var jobs=plats.map(function(k){ var p=def.platforms[k]; return dispatchOne(p.wf, bfInputs(p, x.sha, x.parent)).then(function(r){ r.plat=k; return r; }); });
          return Promise.all(jobs).then(function(results){
            done++;
            if(results.some(function(r){return r.status===401;})) clearTok();
            var okPlats=results.filter(function(r){return r.ok;}).map(function(r){return r.plat;});
            if(okPlats.length){ ok++; markQueued(x.cap, x.sha, okPlats, x.parent, Date.now()); captureRuns(x.cap, x.sha); }
            else { err++; }
            statusFn('Queuing\u2026 '+done+'/'+total, null);
          }).then(function(){ return new Promise(function(res){ setTimeout(res, 650); }); });
        });
      });
      return chain.then(function(){ return { ok:ok, err:err, total:total }; });
    }
    function bfRunAll(){
      var cells=bfCells();
      if(!cells.length){ bfStatus('Nothing left to run \u2014 every revision is queued or already has results.', 'ok'); return; }
      if(!getTok()){ bfTokPanel(true); bfStatus('Add a token (Actions: Read and write) to queue runs.', 'warn'); var i=document.getElementById('lvci-bf-tok-input'); if(i) i.focus(); return; }
      bfTokPanel(false);
      var runBtn=document.getElementById('lvci-bf-run'); var disBtn=document.getElementById('lvci-bf-dismiss');
      if(runBtn) runBtn.disabled=true; if(disBtn) disBtn.disabled=true;
      dispatchCells(cells, bfStatus).then(function(res){
        if(runBtn) runBtn.disabled=false; if(disBtn) disBtn.disabled=false;
        if(res.ok && !res.err){
          bfStatus('\u2713 Queued '+res.ok+' workflow'+(res.ok>1?'s':'')+', oldest first \u2014 results appear as they finish. <a href="https://github.com/'+REPO+'/actions" target="_blank" rel="noopener" style="color:var(--link)">View runs \u2197</a>', 'ok');
          bfDismiss();
        } else if(res.ok && res.err){
          bfStatus('Queued '+res.ok+', but '+res.err+' could not be dispatched \u2014 check the token has <strong>Actions: Read and write</strong> on this repo. <a href="https://github.com/'+REPO+'/actions" target="_blank" rel="noopener" style="color:var(--link)">View runs \u2197</a>', 'warn');
        } else {
          bfStatus('Could not queue runs. The token needs <strong>Actions: Read and write</strong> on <code>'+esc(REPO)+'</code> (runs dispatch on <code>'+esc(BRANCH)+'</code>). <a href="'+tokenSetupUrl()+'" target="_blank" rel="noopener" style="color:var(--link)">Create or update a token \u2197</a>', 'err');
          bfTokPanel(true);
        }
      });
    }
    function bfInit(){
      var c=bfCard(); if(!c) return;
      var run=document.getElementById('lvci-bf-run'); if(run) run.addEventListener('click', bfRunAll);
      var dis=document.getElementById('lvci-bf-dismiss'); if(dis) dis.addEventListener('click', function(){ bfDismiss(); });
      var save=document.getElementById('lvci-bf-tok-save'); if(save) save.addEventListener('click', function(){ var i=document.getElementById('lvci-bf-tok-input'); var v=(i&&i.value||'').trim(); if(!v){ if(i) i.focus(); return; } setTok(v); bfRunAll(); });
      var inp=document.getElementById('lvci-bf-tok-input'); if(inp) inp.addEventListener('keydown', function(e){ if(e.key==='Enter'){ e.preventDefault(); var v=(inp.value||'').trim(); if(v){ setTok(v); bfRunAll(); } } });
      var link=document.getElementById('lvci-bf-tok-link'); if(link) link.href=tokenSetupUrl();
      var cust=document.getElementById('lvci-bf-custom'); if(cust) cust.addEventListener('click', function(e){ e.preventDefault(); histOpen(); });
      bfShow();
    }
    // ── "Populate dashboard history" dialog ──────────────────────────────
    // Opened from the header's More menu (window.lvciRunHistory) and the fresh
    // install card's "Customize…" link. The user chooses where in history to
    // start, whether to run the lean diff-based pass (VI Snapshots + VIDiff only —
    // the modified-file visual history) or every activity, and exactly which
    // activities to queue. Reuses dispatchCells (oldest-first, snapshots as one
    // backfill) + the same token and optimistic-queued bridge as every other
    // dispatch on the dashboard.
    var HIST = __HIST__;                        // [{sha, short, msg}] newest-first (project revisions)
    var HIST_CAPS = [                           // activity rows, in display order
      ['snapshots',   'VI Snapshots', 'Renders every changed VI (one backfill pass)'],
      ['vidiff',      'VIDiff',       'Visual diff of the VIs each revision changed'],
      ['masscompile', 'Mass Compile', 'Compiles the whole project, each revision'],
      ['vi-analyzer', 'VI Analyzer',  'Runs the VI Analyzer suite, each revision'],
      ['antidoc',     'Antidoc',      'Generates project documentation, each revision']
    ];
    var DIFF_CAPS = { snapshots:1, vidiff:1 };  // the lean "diff-based" subset
    function histModal(){ return document.getElementById('cidash-hist-modal'); }
    function cidashHistClose(){ var m=histModal(); if(m) m.style.display='none'; document.body.style.overflow=''; }
    function histStatus(html, kind){
      var s=document.getElementById('cidash-hist-status'); if(!s) return;
      var col = kind==='ok' ? '#3fb950' : (kind==='err' ? '#f85149' : (kind==='warn' ? '#d29922' : 'var(--fg-muted)'));
      s.style.color=col; s.innerHTML=html||'';
    }
    function histTokPanel(show){ var p=document.getElementById('cidash-hist-tok'); if(p) p.style.display = show ? 'block' : 'none'; }
    function histSelectedCaps(){
      var caps={};
      HIST_CAPS.forEach(function(o){ var b=document.getElementById('cidash-hist-act-'+o[0]); if(b && b.checked && !b.disabled) caps[o[0]]=1; });
      return caps;
    }
    function histScopeMode(){ var r=document.querySelector('input[name="cidash-hist-scope"]:checked'); return r ? r.value : 'all'; }
    function histIdx(sha){ for(var i=0;i<HIST.length;i++){ if(HIST[i].sha===sha) return i; } return -1; }
    function histIncludedShas(){
      // Three scopes drive which revisions are queued (HIST is newest-first):
      //   all      -> every revision
      //   range    -> Start (older bound) .. Stop (newer bound), inclusive; a blank
      //               Start = oldest and a blank Stop = newest, and a reversed pair
      //               is swapped so the range is always valid
      //   specific -> exactly the ticked revisions (one or many)
      var mode=histScopeMode(); var inc={};
      if(mode==='specific'){
        Array.prototype.forEach.call(document.querySelectorAll('input.cidash-hist-spec:checked'), function(b){ inc[b.value]=1; });
        return inc;
      }
      if(mode==='range'){
        var f=document.getElementById('cidash-hist-from'); var t=document.getElementById('cidash-hist-to');
        var iFrom = (f && f.value) ? histIdx(f.value) : HIST.length-1;   // '' = oldest
        var iTo   = (t && t.value) ? histIdx(t.value) : 0;               // '' = newest
        if(iFrom<0) iFrom=HIST.length-1; if(iTo<0) iTo=0;
        var lo=Math.min(iFrom,iTo), hi=Math.max(iFrom,iTo);
        for(var j=lo;j<=hi;j++){ if(HIST[j]) inc[HIST[j].sha]=1; }
        return inc;
      }
      HIST.forEach(function(r){ inc[r.sha]=1; });
      return inc;
    }
    function histScopeApply(){
      // Reveal only the sub-control for the chosen scope.
      var mode=histScopeMode();
      var rr=document.getElementById('cidash-hist-rangerow'); if(rr) rr.style.display = (mode==='range') ? '' : 'none';
      var sw=document.getElementById('cidash-hist-specwrap'); if(sw) sw.style.display = (mode==='specific') ? '' : 'none';
    }
    function histCells(){
      var caps=histSelectedCaps(); var inc=histIncludedShas();
      return bfCells().filter(function(x){ return caps[x.cap] && inc[x.sha] && !(x.cap==='vidiff' && !x.parent); });
    }
    function histRefresh(){
      // Live summary of what will be queued from the current selection.
      var cells=histCells();
      var shas={}; var snaps=0; var perRev=0;
      cells.forEach(function(x){ shas[x.sha]=1; if(x.cap==='snapshots') snaps=1; else perRev++; });
      var runs=perRev + snaps;   // snapshots collapse into one backfill run
      var nrev=Object.keys(shas).length;
      var sum=document.getElementById('cidash-hist-summary');
      if(sum){
        if(!HIST.length){ sum.innerHTML='No project revisions to populate yet \u2014 commit some VIs first.'; }
        else if(!runs){ sum.innerHTML='Nothing to queue \u2014 the selected revisions already have results for those activities.'; }
        else { sum.innerHTML='Will queue <b>'+runs+'</b> run'+(runs>1?'s':'')+' across <b>'+nrev+'</b> revision'+(nrev>1?'s':'')+', oldest first.'; }
      }
      var go=document.getElementById('cidash-hist-go'); if(go) go.disabled = !runs;
    }
    function histDiffApply(){
      // The diff-based toggle constrains the run to Snapshots + VIDiff: when it is
      // ON, Mass Compile + VI Analyzer are unchecked and greyed out; turning it OFF
      // re-checks + re-enables them (its label promises "uncheck to also run" them).
      // Only invoked from the toggle itself, so manually unchecking an activity
      // afterwards is never overridden by a summary refresh.
      var diff=document.getElementById('cidash-hist-diff');
      var on = !!(diff && diff.checked);
      HIST_CAPS.forEach(function(o){
        if(DIFF_CAPS[o[0]]) return;
        var b=document.getElementById('cidash-hist-act-'+o[0]);
        var row=document.getElementById('cidash-hist-actrow-'+o[0]);
        if(b){ b.disabled=on; b.checked=!on; }
        if(row) row.classList.toggle('disabled', on);
      });
    }
    function histRender(){
      var body=document.getElementById('cidash-hist-body'); if(!body) return;
      var h='';
      h += '<p style="margin:0 0 16px;color:var(--fg-muted);font-size:.86em;line-height:1.55">Queue CI for revisions that already exist so the dashboard fills in. Runs <strong>oldest \u2192 newest</strong>; only activities that haven\u2019t run yet are queued, and VI Snapshots backfills the whole history in one incremental pass.</p>';
      var optsHtml = HIST.map(function(r){ return '<option value="'+esc(r.sha)+'">'+esc((r.short||'')+(r.msg?(' \u2014 '+r.msg):''))+'</option>'; }).join('');
      h += '<div class="cidash-hist-sec"><label class="cidash-hist-lbl">Which revisions</label><div class="cidash-hist-scope">';
      h += '<label class="cidash-hist-radio"><input type="radio" name="cidash-hist-scope" value="all" checked> All '+HIST.length+' revision'+(HIST.length===1?'':'s')+' <span class="sub">\u2014 the full history</span></label>';
      h += '<label class="cidash-hist-radio"><input type="radio" name="cidash-hist-scope" value="range"> A range of history</label>';
      h += '<div class="cidash-hist-rangerow" id="cidash-hist-rangerow" style="display:none">';
      h += '<label>Start at <select id="cidash-hist-from"><option value="">Oldest (beginning)</option>'+optsHtml+'</select></label>';
      h += '<label>stop at <select id="cidash-hist-to"><option value="">Newest (latest)</option>'+optsHtml+'</select></label>';
      h += '</div>';
      h += '<label class="cidash-hist-radio"><input type="radio" name="cidash-hist-scope" value="specific"> Specific revision(s)</label>';
      h += '<div id="cidash-hist-specwrap" style="display:none">';
      h += '<div class="cidash-hist-spectools"><a href="#" id="cidash-hist-spec-all">Select all</a><a href="#" id="cidash-hist-spec-none">Clear</a></div>';
      h += '<div class="cidash-hist-speclist" id="cidash-hist-speclist">';
      HIST.forEach(function(r){ h += '<label class="cidash-hist-specitem"><input type="checkbox" class="cidash-hist-spec" value="'+esc(r.sha)+'"><span class="sh">'+esc(r.short||'')+'</span><span class="ms">'+esc(r.msg||'')+'</span></label>'; });
      h += '</div></div>';
      h += '</div></div>';
      h += '<div class="cidash-hist-sec"><label class="cidash-hist-toggle"><input type="checkbox" id="cidash-hist-diff" checked>'
        + '<span><span class="cidash-hist-tmain">Diff-based \u2014 modified files only</span>'
        + '<span class="cidash-hist-tsub">Runs just VI Snapshots and VIDiff (the visual history of what each revision changed). Uncheck to also run Mass Compile and VI Analyzer on every revision.</span></span></label></div>';
      h += '<div class="cidash-hist-sec"><label class="cidash-hist-lbl">Activities</label><div class="cidash-hist-acts">';
      HIST_CAPS.forEach(function(o){
        h += '<label class="cidash-hist-act" id="cidash-hist-actrow-'+o[0]+'"><input type="checkbox" id="cidash-hist-act-'+o[0]+'" data-cap="'+o[0]+'" checked>'
          + '<span>'+esc(o[1])+'</span><span class="cidash-hist-actsub">'+esc(o[2])+'</span></label>';
      });
      h += '</div></div>';
      h += '<div id="cidash-hist-tok" style="display:none;border:1px solid var(--border);border-radius:8px;padding:12px;background:var(--surface);margin:0 0 12px">';
      h += '<div style="font-size:.82em;color:var(--fg);font-weight:600;margin-bottom:6px">One-time setup \u2014 a token to queue runs</div>';
      h += '<ol style="font-size:.8em;color:var(--fg-muted);margin:0 0 8px;padding-left:18px;line-height:1.6">';
      h += '<li><a href="'+tokenSetupUrl()+'" target="_blank" rel="noopener" style="color:var(--link)">Create a fine-grained token \u2197</a> \u2014 opens with the name, owner, and <strong>Actions: Read and write</strong> already set.</li>';
      h += '<li><strong>Repository access</strong> \u2192 Only select repositories \u2192 add <code>'+esc(REPO)+'</code>.</li>';
      h += '<li><strong>Permissions \u2192 Repository permissions \u2192 Actions \u2192 Read and write</strong>.</li>';
      h += '<li>Generate, then paste it below.</li></ol>';
      h += '<div style="display:flex;gap:8px;flex-wrap:wrap"><input id="cidash-hist-tok-input" type="password" autocomplete="off" placeholder="github_pat_\u2026 or ghp_\u2026" style="flex:1 1 240px;min-width:180px;padding:7px 10px;background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:6px;font-family:ui-monospace,Menlo,monospace;font-size:.8em">';
      h += '<button class="cidash-btn cidash-go" id="cidash-hist-tok-save">Save &amp; queue</button></div></div>';
      h += '<div id="cidash-hist-summary" class="cidash-hist-summary"></div>';
      h += '<div id="cidash-hist-status" style="font-size:.82em;min-height:1.2em;margin:0 0 12px"></div>';
      h += '<div style="display:flex;gap:10px;flex-wrap:wrap;align-items:center">';
      h += '<button class="cidash-btn cidash-go" id="cidash-hist-go">\u25B6 Queue runs</button>';
      h += '<button class="cidash-btn cidash-ghost" id="cidash-hist-cancel">Cancel</button></div>';
      body.innerHTML=h;
      var diff=document.getElementById('cidash-hist-diff'); if(diff) diff.addEventListener('change', function(){ histDiffApply(); histRefresh(); });
      Array.prototype.forEach.call(document.querySelectorAll('input[name="cidash-hist-scope"]'), function(r){ r.addEventListener('change', function(){ histScopeApply(); histRefresh(); }); });
      var hf=document.getElementById('cidash-hist-from'); if(hf) hf.addEventListener('change', histRefresh);
      var ht=document.getElementById('cidash-hist-to'); if(ht) ht.addEventListener('change', histRefresh);
      Array.prototype.forEach.call(document.querySelectorAll('input.cidash-hist-spec'), function(b){ b.addEventListener('change', histRefresh); });
      var spa=document.getElementById('cidash-hist-spec-all'); if(spa) spa.addEventListener('click', function(e){ e.preventDefault(); Array.prototype.forEach.call(document.querySelectorAll('input.cidash-hist-spec'), function(b){ b.checked=true; }); histRefresh(); });
      var spn=document.getElementById('cidash-hist-spec-none'); if(spn) spn.addEventListener('click', function(e){ e.preventDefault(); Array.prototype.forEach.call(document.querySelectorAll('input.cidash-hist-spec'), function(b){ b.checked=false; }); histRefresh(); });
      HIST_CAPS.forEach(function(o){ var b=document.getElementById('cidash-hist-act-'+o[0]); if(b) b.addEventListener('change', histRefresh); });
      var go=document.getElementById('cidash-hist-go'); if(go) go.addEventListener('click', histRun);
      var cancel=document.getElementById('cidash-hist-cancel'); if(cancel) cancel.addEventListener('click', cidashHistClose);
      var save=document.getElementById('cidash-hist-tok-save'); if(save) save.addEventListener('click', function(){ var i=document.getElementById('cidash-hist-tok-input'); var v=(i&&i.value||'').trim(); if(!v){ if(i) i.focus(); return; } setTok(v); histTokPanel(false); histRun(); });
      var tin=document.getElementById('cidash-hist-tok-input'); if(tin) tin.addEventListener('keydown', function(e){ if(e.key==='Enter'){ e.preventDefault(); var v=(tin.value||'').trim(); if(v){ setTok(v); histTokPanel(false); histRun(); } } });
      histScopeApply(); histDiffApply(); histRefresh();
    }
    function histOpen(){
      var m=histModal(); if(!m) return;
      histRender();
      m.style.display='block'; document.body.style.overflow='hidden';
    }
    function histRun(){
      var cells=histCells();
      if(!cells.length){ histStatus('Nothing to queue \u2014 the selected revisions already have results for those activities.', 'warn'); return; }
      if(!getTok()){ histTokPanel(true); histStatus('Add a token (Actions: Read and write) to queue runs.', 'warn'); var i=document.getElementById('cidash-hist-tok-input'); if(i) i.focus(); return; }
      histTokPanel(false);
      var go=document.getElementById('cidash-hist-go'); var cancel=document.getElementById('cidash-hist-cancel');
      if(go) go.disabled=true; if(cancel) cancel.disabled=true;
      dispatchCells(cells, histStatus).then(function(res){
        if(cancel) cancel.disabled=false;
        if(res.ok && !res.err){
          histStatus('\u2713 Queued '+res.ok+' run'+(res.ok>1?'s':'')+', oldest first \u2014 results appear on the dashboard as they finish. <a href="https://github.com/'+REPO+'/actions" target="_blank" rel="noopener" style="color:var(--link)">View runs \u2197</a>', 'ok');
          bfDismiss();   // the fresh-install nudge has served its purpose
        } else if(res.ok && res.err){
          if(go) go.disabled=false;
          histStatus('Queued '+res.ok+', but '+res.err+' could not be dispatched \u2014 check the token has <strong>Actions: Read and write</strong> on this repo. <a href="https://github.com/'+REPO+'/actions" target="_blank" rel="noopener" style="color:var(--link)">View runs \u2197</a>', 'warn');
        } else {
          if(go) go.disabled=false;
          histStatus('Could not queue runs. The token needs <strong>Actions: Read and write</strong> on <code>'+esc(REPO)+'</code> (runs dispatch on <code>'+esc(BRANCH)+'</code>). <a href="'+tokenSetupUrl()+'" target="_blank" rel="noopener" style="color:var(--link)">Create or update a token \u2197</a>', 'err');
          histTokPanel(true);
        }
      });
    }
    // Exposed for the shared header's "Populate history" menu item.
    window.lvciRunHistory = histOpen;
    document.addEventListener('keydown', function(e){ if(e.key==='Escape'){ var m=histModal(); if(m && m.style.display==='block') cidashHistClose(); } });
    // Re-apply optimistic "Queued" badges once the table exists (this script runs
    // before the table is parsed), and after every auto-refresh thereafter; wire
    // the backfill card the same way.
    if(document.readyState === 'loading'){ document.addEventListener('DOMContentLoaded', function(){ applyQueued(); qSync(); bfInit(); }); }
    else { applyQueued(); qSync(); bfInit(); }
  })();
  </scr""" + """ipt>""").replace('__RUN_TARGETS__', run_targets_json).replace('__HIST__', hist_json).replace('__REPO__', repo).replace('__BRANCH__', get_default_branch())

# ── "Run CI for your whole history" card (fresh installs only) ───────────────
# A brand-new dashboard has no results, so every project cell shows a one-click
# run glyph. Rather than make the user click each one, this card offers to queue
# them ALL at once, oldest revision first. It is emitted ONLY when the page is
# output-free (no terminal results, nothing running) yet has revisions to run, so
# it never appears once CI output exists; the client controller (in run_dialog)
# also lets the user dismiss it and self-hides it once anything has been queued.
# No literal braces in the markup, so this stays a plain string (the page template
# below is an f-string; this is spliced in as {backfill_card}).
backfill_card = ''
if not any_output['on'] and not running_flag['on'] and run_count['n'] > 0:
    _cfg_repo = html.escape(repo, quote=True)
    bf_conc_html = (
        '<span class="lvci-bf-note">'
        f'This repository is currently set to run up to <b>{lvci_max_parallel}</b> '
        f'CI job{"" if lvci_max_parallel == 1 else "s"} at a time. Anything past that '
        '&mdash; or past your GitHub account&rsquo;s own concurrency limit &mdash; just '
        'waits its turn and runs in order, so it&rsquo;s safe to queue the whole history at once.'
        '</span>'
        '<details class="lvci-bf-info">'
        '<summary>&#9432; How concurrency works</summary>'
        '<div class="lvci-bf-infobody">'
        'GitHub caps how many CI jobs run at the same time <b>per account</b> &mdash; shared '
        'across every repository you own (for example 20 jobs on Free, 40 on Pro), not per repo. '
        f'This repository adds its own limit, <b>Max concurrent runners = {lvci_max_parallel}</b>, '
        'so a large history backfill paces itself instead of monopolising your account&rsquo;s '
        'runners; routine pushes and tooling updates draw from the same pool. Runs beyond the '
        'limit are queued and start automatically as earlier ones finish &mdash; nothing is lost.'
        f'<a href="#" class="lvci-bf-cfg" onclick="lvciOpen(&#39;configure.html?repo={_cfg_repo}&#39;,&#39;Configure Workers&#39;);return false;">'
        f'Change this for {html.escape(repo_name)} &rarr;</a>'
        '</div></details>'
    )
    backfill_card = (
        '<div id="lvci-backfill" class="lvci-backfill" role="region" aria-label="Run CI for existing history" style="display:none">'
        '<div class="lvci-bf-main">'
        '<div class="lvci-bf-icon" aria-hidden="true">&#9889;</div>'
        '<div class="lvci-bf-text">'
        '<strong>Populate the dashboard with your history</strong>'
        '<span>This dashboard has no results yet. Queue CI for all <b id="lvci-bf-count"></b> revisions in one click &mdash; processed <b>oldest&nbsp;&rarr;&nbsp;newest</b> so snapshots and diffs build on one another with no duplicated work. <a href="#" id="lvci-bf-custom" style="color:var(--link)">Choose activities or where to start&hellip;</a></span>'
        + bf_conc_html +
        '</div>'
        '<div class="lvci-bf-actions">'
        '<button type="button" id="lvci-bf-run" class="cidash-btn cidash-go">&#9654; Run all history</button>'
        '<button type="button" id="lvci-bf-dismiss" class="cidash-btn cidash-ghost">Dismiss</button>'
        '</div></div>'
        '<div id="lvci-bf-tok" class="lvci-bf-tok" style="display:none">'
        'Paste a token with <strong>Actions: Read and write</strong> on this repository &mdash; the same token you set the dashboard up with works here too, or <a id="lvci-bf-tok-link" target="_blank" rel="noopener" style="color:var(--link)">create one &#8599;</a>.'
        '<div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:7px">'
        '<input id="lvci-bf-tok-input" type="password" autocomplete="off" placeholder="github_pat_&hellip; or ghp_&hellip;" style="flex:1 1 240px;min-width:180px;padding:7px 10px;background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:6px;font-family:ui-monospace,Menlo,monospace;font-size:.8em">'
        '<button type="button" id="lvci-bf-tok-save" class="cidash-btn cidash-go">Save &amp; run</button>'
        '</div></div>'
        '<div id="lvci-bf-status" class="lvci-bf-status" role="status" aria-live="polite"></div>'
        '</div>'
    )

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta http-equiv="refresh" content="{refresh_secs}">
  <title>CI Dashboard — {repo_name}</title>
  <style>
    :root{{
      --bg:#0d1117;--surface:#161b22;--border:#30363d;
      --fg:#e6edf3;--fg-muted:#8b949e;--row-border:#21262d;
      --hover:#1c2128;--link:#58a6ff;
    }}
    @media(prefers-color-scheme:light){{
      :root{{
        --bg:#ffffff;--surface:#f6f8fa;--border:#d0d7de;
        --fg:#1f2328;--fg-muted:#57606a;--row-border:#eaeef2;
        --hover:#f3f4f6;--link:#0969da;
      }}
    }}
    *{{box-sizing:border-box}}
    body{{margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--fg)}}
    .lvci-main{{padding:20px}}
    .lvci-tablewrap{{width:100%;overflow-x:auto;-webkit-overflow-scrolling:touch}}
    h1{{font-size:1.4em;margin:0 0 4px}}
    .sub{{color:var(--fg-muted);font-size:.85em;margin-bottom:20px}}
    @media(max-width:820px){{.lvci-main{{padding:14px}}h1{{font-size:1.2em}}}}
    table{{border-collapse:collapse;width:100%;background:var(--surface);border:1px solid var(--border);border-radius:8px;overflow:hidden}}
    th{{text-align:left;padding:10px 8px;border-bottom:1px solid var(--border);color:var(--fg-muted);font-size:.8em;white-space:nowrap}}
    td{{border-bottom:1px solid var(--row-border);vertical-align:middle}}
    tr:last-child td{{border-bottom:none}}
    tr:hover{{background:var(--hover)}}
    a{{color:var(--link);text-decoration:none}}a:hover{{text-decoration:underline}}
    .nav{{margin-bottom:16px;font-size:.9em}}
    .nav a{{margin-right:16px;color:var(--link)}}
    .controls{{margin:0 0 12px;display:flex;align-items:center;gap:14px;flex-wrap:wrap;color:var(--fg-muted);font-size:.85em}}
    .controls input{{margin:0;accent-color:var(--link)}}
    .cidash-check{{display:inline-flex;align-items:center;gap:6px}}
    /* Column-visibility menu (standard "Columns" dropdown of checkboxes). */
    .cidash-colmenu{{position:relative;display:inline-block}}
    .cidash-colbtn{{background:var(--surface);border:1px solid var(--border);color:var(--fg);padding:5px 11px;border-radius:6px;cursor:pointer;font-size:1em;line-height:1.2;display:inline-flex;align-items:center;gap:6px}}
    .cidash-colbtn:hover{{background:var(--hover)}}
    .cidash-colpanel{{position:absolute;top:calc(100% + 6px);left:0;z-index:120;min-width:200px;background:var(--surface);border:1px solid var(--border);border-radius:8px;box-shadow:0 8px 28px rgba(0,0,0,.35);padding:6px}}
    .cidash-colpanel[hidden]{{display:none}}
    .cidash-colpanel .hd{{font-size:.72em;color:var(--fg-muted);padding:4px 8px 6px;text-transform:uppercase;letter-spacing:.05em}}
    .cidash-colopt{{display:flex;align-items:center;gap:8px;padding:6px 8px;border-radius:5px;cursor:pointer;color:var(--fg);white-space:nowrap;font-size:.95em}}
    .cidash-colopt:hover{{background:var(--hover)}}
    .cidash-colopt input{{margin:0;accent-color:var(--link)}}
    .run-badge{{display:inline-flex;align-items:center;background:#1f6feb;color:#fff;padding:2px 8px;border-radius:4px;font-size:.75em;font-weight:600}}
    .run-badge a:hover{{text-decoration:underline}}
    /* Optimistic "just queued from this browser" cue: a dashed ring distinguishes
       a client-side queued badge from a server-confirmed running one. */
    .run-badge.cidash-queued{{outline:1px dashed rgba(255,255,255,.6);outline-offset:1px}}
    /* A run confirmed FAILED on GitHub: a sticky red badge (no spinner, no dashed
       "optimistic" ring) so an error shows instead of the cell silently reverting. */
    .run-badge.cidash-failed{{background:#da3633;outline:none}}
    /* The red "bang" inside a failed badge: a bold white exclamation on the red
       field, so a failed cell reads as a clickable error at a glance. */
    .run-badge.cidash-failed .cidash-bang{{font-weight:800;font-size:1.15em;line-height:1;margin-right:5px}}
    .run-spin{{width:9px;height:9px;border:2px solid rgba(255,255,255,.45);border-top-color:#fff;border-radius:50%;display:inline-block;animation:cidash-spin .7s linear infinite}}
    /* The Queued badge places the spinner directly before its label (no flex gap),
       so give the spinner a small right margin to keep the icon off the "Q". */
    .run-badge.cidash-queued .run-spin{{margin-right:5px}}
    @keyframes cidash-spin{{to{{transform:rotate(360deg)}}}}
    {run_dialog_css}
  </style>
</head>
<body>
  <script>window.LVCI={{context:'dashboard',repo:'{repo}',pagesUrl:'{pages_url}',isSource:{'true' if lvci_is_source else 'false'}}};</script>
  <script src="lvci-header.js" defer></script>
  <div id="lvci-modal" onclick="if(event.target===this)lvciClose()" style="display:none;position:fixed;inset:0;z-index:300;background:rgba(0,0,0,.55)">
    <div style="position:absolute;inset:24px;background:var(--bg);border:1px solid var(--border);border-radius:10px;overflow:hidden;display:flex;flex-direction:column;box-shadow:0 10px 48px rgba(0,0,0,.5)">
      <div style="display:flex;align-items:center;justify-content:space-between;padding:10px 16px;border-bottom:1px solid var(--border);background:var(--surface)">
        <strong id="lvci-modal-title" style="font-size:.95em">Configure Workers</strong>
        <button onclick="lvciClose()" style="background:transparent;border:1px solid var(--border);color:var(--fg);padding:5px 12px;border-radius:6px;cursor:pointer;font-size:.82em">✕ Close</button>
      </div>
      <iframe id="lvci-frame" title="LabVIEW CI dialog" src="about:blank" style="border:0;width:100%;flex:1;min-height:0"></iframe>
    </div>
  </div>
  <script>
    function lvciOpen(src, title) {{
      document.getElementById('lvci-frame').src = src;
      document.getElementById('lvci-modal-title').textContent = title;
      document.getElementById('lvci-modal').style.display = 'block';
      document.body.style.overflow = 'hidden';
    }}
    function lvciClose() {{
      document.getElementById('lvci-modal').style.display = 'none';
      document.getElementById('lvci-frame').src = 'about:blank';
      document.body.style.overflow = '';
    }}
    document.addEventListener('keydown', function (e) {{ if (e.key === 'Escape') lvciClose(); }});
  </script>
  {run_dialog}
  <main class="lvci-main">
  <h1>CI Dashboard — {repo_name}</h1>
  <div class="sub">Last updated: {now} &nbsp;|&nbsp; {refresh_note}</div>
  <div class="nav">
    <a href="https://github.com/{repo}">GitHub</a>
    <a href="https://github.com/{repo}/actions">Actions</a>
  </div>
  {backfill_card}
  <div class="controls">
    <label class="cidash-check" for="show-nonproject">
      <input type="checkbox" id="show-nonproject">
      Include CI-only revisions
    </label>
    <div class="cidash-colmenu">
      <button type="button" id="cidash-colbtn" class="cidash-colbtn" aria-haspopup="true" aria-expanded="false">&#9783; Columns &#9662;</button>
      <div id="cidash-colpanel" class="cidash-colpanel" role="menu" hidden></div>
    </div>
  </div>
  <div class="lvci-tablewrap">
  <table id="cidash-table">
    <thead>
      <tr>
        <th>Commit</th><th>Message</th><th>Author</th><th>Date</th>
        <th style="text-align:center">Mass Compile</th>
        <th style="text-align:center">VI Analyzer</th>
        <th style="text-align:center">VIDiff</th>
        <th style="text-align:center">Snapshots</th>
        <th style="text-align:center">Unit Tests</th>
        <th style="text-align:center">Antidoc</th>
      </tr>
    </thead>
    <tbody>{rows}</tbody>
  </table>
  </div>
  <div id="empty-state" style="display:none;padding:18px;text-align:center;color:var(--fg-muted);font-size:.9em">
    No project revisions in the recent window. <a href="#" onclick="document.getElementById('show-nonproject').click();return false" style="color:var(--link)">Include CI-only revisions</a> to see CI&nbsp;/&nbsp;tooling commits.
  </div>
  </main>
  <script>
    (() => {{
      const checkbox = document.getElementById('show-nonproject');
      const rows = document.querySelectorAll('tbody tr[data-project]');
      const emptyState = document.getElementById('empty-state');
      // Honor the toggle strictly: while "Include CI-only revisions" is
      // unchecked, only project revisions show. If that hides every row,
      // reveal an inline prompt (rather than silently showing CI-only rows
      // or leaving a blank table) inviting the user to enable the toggle.
      const applyFilter = () => {{
        const showNonProject = checkbox.checked;
        let visible = 0;
        rows.forEach((row) => {{
          const isProject = row.getAttribute('data-project') === 'true';
          const show = isProject || showNonProject;
          row.style.display = show ? '' : 'none';
          if (show) visible++;
        }});
        if (emptyState) emptyState.style.display = visible ? 'none' : '';
      }};
      checkbox.addEventListener('change', applyFilter);
      applyFilter();
    }})();

    // Column-visibility menu: a standard "Columns" dropdown of checkboxes that
    // toggles each (non-identifier) column on/off, persisted per-repo in
    // localStorage so the choice survives reloads. Commit (column 0) is the row
    // identifier and is always shown.
    (() => {{
      const STORE = 'lvci_dash_cols_{repo}';
      const COLS = [
        {{key:'message',     label:'Message',      idx:1}},
        {{key:'author',      label:'Author',       idx:2}},
        {{key:'date',        label:'Date',         idx:3}},
        {{key:'masscompile', label:'Mass Compile', idx:4}},
        {{key:'vi-analyzer', label:'VI Analyzer',  idx:5}},
        {{key:'vidiff',      label:'VIDiff',       idx:6}},
        {{key:'snapshots',   label:'Snapshots',    idx:7}},
        {{key:'unit-tests',  label:'Unit Tests',   idx:8}},
        {{key:'antidoc',     label:'Antidoc',      idx:9}}
      ];
      const btn = document.getElementById('cidash-colbtn');
      const panel = document.getElementById('cidash-colpanel');
      if (!btn || !panel) return;
      const hidden = {{}};
      try {{ (JSON.parse(localStorage.getItem(STORE)) || []).forEach((k) => {{ hidden[k] = true; }}); }} catch (e) {{}}
      const persist = () => {{
        try {{ localStorage.setItem(STORE, JSON.stringify(COLS.map((c) => c.key).filter((k) => hidden[k]))); }} catch (e) {{}}
      }};
      const applyCol = (col) => {{
        const vis = !hidden[col.key];
        document.querySelectorAll('#cidash-table > thead > tr, #cidash-table > tbody > tr').forEach((tr) => {{
          const cell = tr.children[col.idx];
          if (cell) cell.style.display = vis ? '' : 'none';
        }});
      }};
      const head = document.createElement('div');
      head.className = 'hd';
      head.textContent = 'Show columns';
      panel.appendChild(head);
      COLS.forEach((col) => {{
        const lab = document.createElement('label');
        lab.className = 'cidash-colopt';
        const cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.checked = !hidden[col.key];
        cb.addEventListener('change', () => {{ hidden[col.key] = !cb.checked; applyCol(col); persist(); }});
        lab.appendChild(cb);
        lab.appendChild(document.createTextNode(' ' + col.label));
        panel.appendChild(lab);
        applyCol(col);
      }});
      const setOpen = (open) => {{ panel.hidden = !open; btn.setAttribute('aria-expanded', open ? 'true' : 'false'); }};
      btn.addEventListener('click', (e) => {{ e.stopPropagation(); setOpen(panel.hidden); }});
      document.addEventListener('click', (e) => {{ if (!panel.hidden && !panel.contains(e.target) && e.target !== btn) setOpen(false); }});
      document.addEventListener('keydown', (e) => {{ if (e.key === 'Escape') setOpen(false); }});
    }})();
  </script>
</body>
</html>"""

os.makedirs('ci-out/dashboard', exist_ok=True)
with open('ci-out/dashboard/index.html', 'w', encoding='utf-8') as f:
    # Dedent the heredoc indentation
    import textwrap
    f.write(textwrap.dedent(html))

# Ensure VI Browser route exists so dashboard commit links do not 404.
os.makedirs('ci-out/dashboard/vi-snapshots', exist_ok=True)
# Framed report viewer (chrome + back-nav) that the Mass Compile badge links to.
os.makedirs('ci-out/dashboard/report', exist_ok=True)
# Tooling pages come from PAGES_SRC (a composite action passes its own bundled
# dir so thin consumers need no copy); default to the in-repo location.
_pages_src = os.environ.get('PAGES_SRC', '.github/pages')
def _stage(src, dst):
    try:
        with open(src, 'r', encoding='utf-8') as sf, open(dst, 'w', encoding='utf-8') as df:
            df.write(sf.read())
    except FileNotFoundError:
        pass
for _name, _dst in [
    ('lvci-header.js', 'ci-out/dashboard/lvci-header.js'),
    ('vi-browser.html', 'ci-out/dashboard/vi-snapshots/index.html'),
    ('vi-interactive.html', 'ci-out/dashboard/vi-snapshots/vi-interactive.html'),
    # vi-render.js powers the in-place block-diagram renderer that vi-browser.html
    # and vi-interactive.html load; stage it beside them so the in-place view works.
    ('vi-render.js', 'ci-out/dashboard/vi-snapshots/vi-render.js'),
    ('report-viewer.html', 'ci-out/dashboard/report/index.html'),
    ('whats-new.html', 'ci-out/dashboard/whats-new.html'),
    ('configure.html', 'ci-out/dashboard/configure.html'),
    ('integrate.html', 'ci-out/dashboard/integrate.html'),
    ('unit-tests.html', 'ci-out/dashboard/unit-tests.html'),
    # Clients registry page (the header only surfaces it on the root repo, where
    # the discovery workflow publishes clients.json beside it).
    ('clients.html', 'ci-out/dashboard/clients.html'),
]:
    _stage(os.path.join(_pages_src, _name), _dst)
# Deploy a catalog.json at the Pages root so the version badge + What's New can
# read the installed version. Prefer the consumer's own catalog; else synthesize
# one from the manifest values resolved above.
_client_cat = os.environ.get('CATALOG_PATH', '.github/labview-ci/catalog.json')
if os.path.isfile(_client_cat):
    _stage(_client_cat, 'ci-out/dashboard/catalog.json')
elif lvci_version:
    with open('ci-out/dashboard/catalog.json', 'w', encoding='utf-8') as f:
        json.dump({'version': lvci_version,
                   'source': {'repo': lvci_src_repo, 'ref': lvci_src_ref}}, f, indent=2)

# The VI Browser's snapshot-independent index: every project revision plus the
# VI files present in it. Lets the browser render the file hierarchy and offer a
# "Generate snapshots" action even when nothing has been rendered yet. Deployed
# with keep_files:true, alongside (never clobbering) the snapshot workflow's
# commits.json / <sha>/manifest.json.
files_payload = {
    'repo': repo,
    'generated': __import__('datetime').datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'commits': file_commits,
}
with open('ci-out/dashboard/vi-snapshots/files.json', 'w', encoding='utf-8') as f:
    json.dump(files_payload, f, ensure_ascii=False)
print(f"Dashboard built with {len(commits_data)} commits; "
      f"files.json has {len(file_commits)} project revision(s).")
