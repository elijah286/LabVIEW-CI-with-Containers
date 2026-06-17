#!/usr/bin/env python3
import json, os, re, sys, urllib.request, urllib.error
from urllib.parse import quote

token    = os.environ['GH_TOKEN']
repo     = os.environ['REPO']
pages_url = os.environ['PAGES_URL']

_default_branch = None

def get_default_branch():
    """Query the repo's default branch from GitHub. Cached to avoid repeated calls."""
    global _default_branch
    if _default_branch is not None:
        return _default_branch
    repo_info = gh_get('')
    _default_branch = repo_info.get('default_branch', 'main') if repo_info else 'main'
    return _default_branch

def gh_get(path):
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

# ── Fetch a JSON file straight from the deployed Pages site ─────
# Used to read each commit's per-platform VIDiff changes.json so the
# Snapshots column can report how many VIs were rendered on Windows vs
# Linux. Returns None on any error (missing file, propagation lag, etc.).
def http_json(url):
    req = urllib.request.Request(url, headers={'Accept': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.load(r)
    except Exception:
        return None

_snap_cache = {}
def snapshot_counts(sha):
    # Map platform -> number of VIs whose snapshots/diffs were rendered for
    # this revision, sourced from vidiff/push-<sha>/<platform>/vidiff/changes.json.
    if sha in _snap_cache:
        return _snap_cache[sha]
    counts = {}
    for plat in ('windows', 'linux'):
        data = http_json(f"{pages_url}/vidiff/push-{sha}/{plat}/vidiff/changes.json")
        if data and isinstance(data.get('files'), list):
            counts[plat] = len(data['files'])
    _snap_cache[sha] = counts
    return counts

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
        'all': {'wf': 'vi-snapshots.yml', 'inputs': {'mode': 'head'}}}},
}
import json as _json
run_targets_json = _json.dumps(RUN_TARGETS)

# ── Framed per-revision reports ─────────────────────────────────────────────────────
# Per-revision reports (Mass Compile, VI Analyzer) open INSIDE the dashboard
# chrome via report-viewer.html (deployed at report/index.html), which frames
# the report under the shared site header — same nav, a revision picker, and a
# Regenerate / Re-run button. So the header no longer "goes away" when a report
# is opened, and reports that predate the header (or carry none of their own)
# still appear inside the chrome. Diff/Snapshots already open the VI Browser (its
# own headered page), so only these two doctypes are wrapped here.
DOC_LABELS = {'vi-analyzer-report': 'VI Analyzer', 'masscompile-report': 'Mass Compile'}

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

    def worker_cell(*contexts):
        # Worker-version column: the version string the worker status posted
        # (e.g. win-abc123def456) linked to its published manifest. EMPTY_CELL
        # for non-project revisions or before the analyzer reported a worker.
        if not is_project:
            return EMPTY_CELL
        s = pick_status(*contexts)
        if not s:
            return EMPTY_CELL
        desc = (s.get('description') or '').strip()
        m = re.search(r'(?:win|linux)-[0-9a-f]{6,}', desc)
        ver = m.group(0) if m else (desc or 'manifest')
        url = s.get('target_url', '')
        inner = f'<a href="{url}" style="color:inherit">{ver}</a>' if url else ver
        return ('<td style="text-align:center"><span style="font-family:monospace;'
                f'font-size:.72em;color:var(--fg-muted)">{inner}</span></td>')

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
    # Snapshots column: per-platform count of VIs rendered for this revision
    # (from each container's VIDiff changes.json), each a deep link into the VI
    # Browser with that platform preselected and the view filtered to changes.
    if not is_project:
        snap_badge = '<td style="text-align:center;color:var(--fg-muted);font-size:.75em">—</td>'
    else:
        _snap_run = fresh_pending('CI / VI Snapshots')
        _counts = snapshot_counts(sha)
        if _snap_run is not None:
            snap_badge = running_cell('snapshots', _snap_run.get('target_url', ''))
        elif not _counts:
            snap_badge = run_cell('snapshots')
        else:
            _links = []
            for _plat, _label in (('windows', 'Win'), ('linux', 'Linux')):
                _n = _counts.get(_plat)
                if _n is None:
                    _links.append(f'<span style="color:var(--fg-muted)">{_label}(–)</span>')
                else:
                    _href = f'{pages_url}/vi-snapshots/index.html?sha={sha}&plat={_plat}&changed=1'
                    _links.append(f'<a href="{_href}" style="color:var(--link)">{_label}({_n})</a>')
            snap_badge = f'<td style="text-align:center;font-size:.78em;white-space:nowrap">{" / ".join(_links)}</td>'

    # Worker columns: which CI worker image analyzed this revision, each
    # linking to that worker's published manifest (what's installed + VIPC).
    win_worker   = worker_cell('CI / Worker (windows)')
    linux_worker = worker_cell('CI / Worker (linux)')

    rows_html.append(f"""
    <tr data-project="{proj_flag}">
      <td style="padding:8px;font-family:monospace;font-size:.85em">
        <a href="{pages_url}/vi-snapshots/index.html?sha={sha}" style="color:var(--link)" title="Browse this commit's VIs in the VI Browser">{short}</a>
      </td>
      <td style="padding:8px;font-size:.85em;max-width:320px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="{msg}"><a href="{pages_url}/vi-snapshots/index.html?sha={sha}" style="color:var(--fg)">{msg}</a></td>
      <td style="padding:8px;font-size:.82em;color:var(--fg-muted)">{author}</td>
      <td style="padding:8px;font-size:.75em;color:var(--fg-muted)">{date[:10]}</td>
      {mc_badge}
      {via_badge}
      {diff_badge}
      {snap_badge}
      {win_worker}
      {linux_worker}
    </tr>""")

rows = '\n'.join(rows_html)
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
        'if(C.isSource||!C.sourceRepo)return;'
        'fetch("https://raw.githubusercontent.com/"+C.sourceRepo+"/"+C.sourceRef+"/.github/labview-ci/catalog.json",{cache:"no-store"})'
        '.then(function(r){return r.ok?r.json():null;}).then(function(cat){'
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
    function getTok(){ try{ return localStorage.getItem(TOK_KEY)||''; }catch(e){ return ''; } }
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
    var QTTL = 20*60*1000;   // forget an unconfirmed entry after 20 min
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
    function qArmReload(){
      // While a queued run is still unconfirmed, reload sooner than the lazy
      // meta-refresh so the real status surfaces promptly (mirrors the server's
      // own faster cadence while CI is live).
      if(qReloadArmed) return; qReloadArmed = true;
      setTimeout(function(){ location.reload(); }, QFAST);
    }
    function qLiveEntries(o){
      // The non-expired queued entries, oldest first — this IS the queue order.
      var now = Date.now();
      return Object.keys(o)
        .filter(function(k){ var e=o[k]; return e && (now-(e.ts||0))<=QTTL; })
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
    function applyQueued(){
      // Re-apply remembered queued badges after each (auto-)reload. An entry is
      // dropped once the server renders a real status for that cell (its run glyph
      // is gone) or once it ages out — so the overlay is a short, self-clearing
      // bridge, never a permanent fake.
      var o = qLoad(); var now = Date.now(); var changed = false; var live = 0;
      Object.keys(o).forEach(function(key){
        var e = o[key]; var i = key.indexOf('|'); var c = key.slice(0,i); var sha = key.slice(i+1);
        if(!e || (now - (e.ts||0)) > QTTL){ delete o[key]; changed = true; return; }
        var painted = document.querySelector('td.cidash-queued-cell[data-qcap="'+c+'"][data-qsha="'+sha+'"]');
        var a = document.querySelector('a.cidash-run[data-cap="'+c+'"][data-sha="'+sha+'"]');
        if(painted){ live++; }
        else if(a){ qPaint(a.closest('td'), c, sha); live++; }
        else {
          // The cell may already hold a RESULT (re-run from the report, not an
          // empty cell). Overlay "Queued" on it until a NEWER result lands. A
          // server-side running spinner has no data-cap, so it falls through to
          // the delete branch below (the server has taken over).
          var rc = document.querySelector('td.cidash-cap-cell[data-cap="'+c+'"][data-sha="'+sha+'"]');
          if(rc){
            var rts = Date.parse(rc.getAttribute('data-ts')||'') || 0;
            if(rts && rts > (e.ts||0)){ delete o[key]; changed = true; }   // re-run finished
            else { if(!e.orig){ e.orig = rc.innerHTML; changed = true; } qPaint(rc, c, sha); live++; }
          }
          else { delete o[key]; changed = true; }   // real status / spinner took over
        }
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
      var plats = (entry.plats||[]).map(cap).join(', ');
      var short = entry.short || sha.slice(0,7);
      var live = qLiveEntries(o); var pos = 0;
      live.forEach(function(en, idx){ if(en.key===c+'|'+sha) pos = idx+1; });
      var h = '';
      h += '<p style="margin:0 0 12px;color:var(--fg-muted);font-size:.85em"><strong>'+esc(def.label)+'</strong> for commit <code style="font-family:monospace">'+esc(short)+'</code>'+(plats?' \u00b7 '+esc(plats):'')+'.</p>';
      if(live.length>1 && pos){ h += '<p style="margin:0 0 12px;font-size:.85em">Place in queue: <strong>#'+pos+'</strong> <span style="color:var(--fg-muted)">of '+live.length+' queued from this browser (oldest first).</span></p>'; }
      h += '<div id="cidash-q-status" style="font-size:.82em;min-height:1.2em;margin:0 0 12px"></div>';
      h += '<div style="display:flex;gap:10px;flex-wrap:wrap;align-items:center">';
      h += qViewLinks(c, entry);
      h += '<button class="cidash-btn cidash-danger" id="cidash-q-cancel">\u2715 Cancel run</button>';
      h += '</div>';
      h += '<p style="color:var(--fg-muted);font-size:.76em;margin:12px 0 0"><strong>Cancel run</strong> stops it on GitHub Actions (uses the same token you queued it with). <strong>View</strong> opens it on GitHub, where you can watch it or stop it manually.</p>';
      $("cidash-q-body").innerHTML = h;
      var cb=$("cidash-q-cancel"); if(cb) cb.addEventListener('click', function(){ cancelQueued(c, sha); });
    }
    function openQ(c, sha){
      if(!RT[c]) return;
      qState = { cap:c, sha:sha };
      var entry = qLoad()[c+'|'+sha];
      $("cidash-q-title").textContent = "Queued: " + RT[c].label;
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
    // Re-apply optimistic "Queued" badges once the table exists (this script runs
    // before the table is parsed), and after every auto-refresh thereafter.
    if(document.readyState === 'loading'){ document.addEventListener('DOMContentLoaded', applyQueued); }
    else { applyQueued(); }
  })();
  </scr""" + """ipt>""").replace('__RUN_TARGETS__', run_targets_json).replace('__REPO__', repo).replace('__BRANCH__', 'main')

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
    .controls{{margin:0 0 12px;display:flex;align-items:center;gap:8px;color:var(--fg-muted);font-size:.85em}}
    .controls input{{margin:0;accent-color:var(--link)}}
    .run-badge{{display:inline-flex;align-items:center;background:#1f6feb;color:#fff;padding:2px 8px;border-radius:4px;font-size:.75em;font-weight:600}}
    .run-badge a:hover{{text-decoration:underline}}
    /* Optimistic "just queued from this browser" cue: a dashed ring distinguishes
       a client-side queued badge from a server-confirmed running one. */
    .run-badge.cidash-queued{{outline:1px dashed rgba(255,255,255,.6);outline-offset:1px}}
    .run-spin{{width:9px;height:9px;border:2px solid rgba(255,255,255,.45);border-top-color:#fff;border-radius:50%;display:inline-block;animation:cidash-spin .7s linear infinite}}
    @keyframes cidash-spin{{to{{transform:rotate(360deg)}}}}
    {run_dialog_css}
  </style>
</head>
<body>
  <script>window.LVCI={{context:'dashboard',repo:'{repo}',pagesUrl:'{pages_url}'}};</script>
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
  <label class="controls" for="show-nonproject">
    <input type="checkbox" id="show-nonproject">
    Include CI-only revisions
  </label>
  <div class="lvci-tablewrap">
  <table>
    <thead>
      <tr>
        <th>Commit</th><th>Message</th><th>Author</th><th>Date</th>
        <th style="text-align:center">Mass Compile</th>
        <th style="text-align:center">VI Analyzer</th>
        <th style="text-align:center">VIDiff</th>
        <th style="text-align:center">Snapshots</th>
        <th style="text-align:center">Win Worker</th>
        <th style="text-align:center">Linux Worker</th>
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
    ('report-viewer.html', 'ci-out/dashboard/report/index.html'),
    ('whats-new.html', 'ci-out/dashboard/whats-new.html'),
    ('configure.html', 'ci-out/dashboard/configure.html'),
    ('integrate.html', 'ci-out/dashboard/integrate.html'),
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
