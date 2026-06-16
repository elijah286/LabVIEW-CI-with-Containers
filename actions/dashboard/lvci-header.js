/*
 * lvci-header.js — the shared, site-wide navigation header for the LabVIEW CI
 * Pages site (dashboard, VI Analyzer reports, VI Browser, Configure, Apply, …).
 *
 * WHY THIS EXISTS
 *   Every page used to carry its own ad-hoc top nav, baked into action-runner
 *   output (the dashboard generator, the per-commit report generator, …). That
 *   made navigation inconsistent and meant changing a link or adding an action
 *   required regenerating reports. This file is a SINGLE shared asset deployed
 *   once to the Pages root: every page just declares a tiny `window.LVCI` config
 *   and loads this script, so the header is consistent everywhere and evolves
 *   independently of the content beneath it (reports stay immutable; the header
 *   updates the moment this file is redeployed).
 *
 * HOW A PAGE OPTS IN  (before this script, or via data-* on the script tag)
 *   <script>window.LVCI = {
 *       context: 'vi-analyzer-report',     // which page this is (see CONTEXTS)
 *       repo:    'owner/name',             // GitHub repo (for links + dispatch)
 *       pagesUrl:'https://o.github.io/n',  // Pages base (absolute; optional —
 *                                          //   derived from this script's src)
 *       sha:     '<40-hex>',  short:'<7>', // commit under view (report pages)
 *       platform:'windows',                // 'windows' | 'linux' (report pages)
 *       rawUrl:  'raw.html'                // native report (report pages)
 *   };</script>
 *   <script src="<pagesUrl>/lvci-header.js" defer></script>
 *
 * The script derives the Pages base from `pagesUrl` or, failing that, from its
 * own <script src>, so cross-depth links (root vs /vi-analyzer/<sha>/) all work.
 * It injects its own styles + DOM at the top of <body>; no placeholder needed.
 * It suppresses itself inside an iframe (the dashboard opens Configure/Apply in
 * a modal that already has its own chrome).
 */
(function () {
  'use strict';

  // Never render inside the dashboard's iframe modal — that overlay has its own
  // title bar + close button, and a second header would be redundant/confusing.
  try { if (window.top !== window.self) return; } catch (e) { return; }

  var cfg = window.LVCI || {};

  // ── Resolve this script element + the Pages base URL ──────────────────────
  var me = document.currentScript;
  if (!me) {
    var ss = document.getElementsByTagName('script');
    for (var i = ss.length - 1; i >= 0; i--) {
      if ((ss[i].src || '').indexOf('lvci-header.js') >= 0) { me = ss[i]; break; }
    }
  }
  // data-* on the script tag are a fallback for pages that prefer not to set a
  // global (e.g. data-context, data-repo, data-sha, data-platform, data-raw).
  if (me && me.dataset) {
    ['context', 'repo', 'pagesUrl', 'sha', 'short', 'platform', 'rawUrl'].forEach(function (k) {
      var dk = k === 'pagesUrl' ? 'pages' : (k === 'rawUrl' ? 'raw' : k);
      if (cfg[k] == null && me.dataset[dk] != null) cfg[k] = me.dataset[dk];
    });
  }

  function trimSlash(s) { return String(s || '').replace(/\/+$/, ''); }
  // Prefer the Pages base derived from THIS script's own (resolved, absolute)
  // src — it is always same-origin, so nav links work whether the site is served
  // from production Pages or a local preview. cfg.pagesUrl is only a fallback for
  // the rare case where the script element can't be found.
  var base = '';
  if (me && me.src) base = trimSlash(me.src.replace(/\/[^\/]*$/, '')); // dir of the script
  if (!base) base = trimSlash(cfg.pagesUrl);
  if (!base) base = '.';
  var repo = cfg.repo || '';
  // Static pages (Configure, VI Browser, …) don't know the repo at build time;
  // derive it from a GitHub Pages PROJECT URL (https://<owner>.github.io/<repo>/…).
  if (!repo) {
    try {
      var hm = location.hostname.match(/^([^.]+)\.github\.io$/i);
      var seg = location.pathname.split('/').filter(Boolean)[0];
      if (hm && seg && seg.indexOf('.') < 0) repo = hm[1] + '/' + seg;
    } catch (e) {}
  }
  var ctx = cfg.context || 'page';

  // ── Design tokens + styles (match the GitHub-style dark/light tokens the
  //    rest of the site uses, so the header blends into every page). ─────────
  var CSS = [
    ':root{--lvh-h:54px}',
    '.lvci-hdr,.lvci-hdr *{box-sizing:border-box}',
    // flex-shrink:0 keeps the bar full-height when <body> is itself a flex
    // column (see the mount logic for full-height flex/grid pages).
    '.lvci-hdr{position:sticky;top:0;z-index:200;flex-shrink:0;display:flex;align-items:center;gap:14px;',
      'height:var(--lvh-h);padding:0 16px;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;',
      'background:rgba(22,27,34,.86);-webkit-backdrop-filter:saturate(160%) blur(10px);backdrop-filter:saturate(160%) blur(10px);',
      'border-bottom:1px solid #30363d;color:#e6edf3}',
    '@media(prefers-color-scheme:light){.lvci-hdr{background:rgba(255,255,255,.86);border-bottom-color:#d0d7de;color:#1f2328}}',
    // Brand
    '.lvci-brand{display:inline-flex;align-items:center;gap:9px;font-weight:700;font-size:15px;color:inherit;text-decoration:none;white-space:nowrap;flex:0 0 auto}',
    '.lvci-brand:hover{text-decoration:none}',
    '.lvci-brand svg{display:block;width:22px;height:22px;flex:0 0 auto}',
    '.lvci-brand .lvci-sub{font-weight:500;font-size:11px;color:#8b949e;border:1px solid #30363d;border-radius:999px;padding:1px 7px;margin-left:2px}',
    '@media(prefers-color-scheme:light){.lvci-brand .lvci-sub{color:#57606a;border-color:#d0d7de}}',
    // Primary nav
    '.lvci-nav{display:flex;align-items:center;gap:2px;flex:1 1 auto;min-width:0}',
    '.lvci-nav a{display:inline-flex;align-items:center;gap:6px;color:#8b949e;text-decoration:none;font-size:13.5px;font-weight:500;',
      'padding:6px 10px;border-radius:7px;white-space:nowrap}',
    '.lvci-nav a:hover{color:#e6edf3;background:rgba(177,186,196,.12)}',
    '.lvci-nav a.on{color:#e6edf3;background:rgba(177,186,196,.16)}',
    '.lvci-nav a.on::after{content:"";position:absolute}',
    '@media(prefers-color-scheme:light){.lvci-nav a:hover,.lvci-nav a.on{color:#1f2328;background:rgba(80,90,100,.10)}}',
    '.lvci-nav a .lvci-soon{font-size:9.5px;font-weight:600;color:#8b949e;border:1px solid #30363d;border-radius:999px;padding:0 5px;text-transform:uppercase;letter-spacing:.04em}',
    // Actions cluster (right)
    '.lvci-actions{display:flex;align-items:center;gap:8px;flex:0 0 auto}',
    '.lvci-btn{display:inline-flex;align-items:center;gap:6px;font-size:12.5px;font-weight:600;line-height:1;cursor:pointer;',
      'border-radius:7px;padding:7px 12px;border:1px solid #30363d;background:transparent;color:inherit;text-decoration:none;white-space:nowrap}',
    '.lvci-btn:hover{background:rgba(177,186,196,.12);text-decoration:none}',
    '@media(prefers-color-scheme:light){.lvci-btn{border-color:#d0d7de}.lvci-btn:hover{background:rgba(80,90,100,.08)}}',
    '.lvci-btn.primary{background:#238636;border-color:#238636;color:#fff}',
    '.lvci-btn.primary:hover{background:#2ea043}',
    '.lvci-btn.accent{background:#1f6feb;border-color:#1f6feb;color:#fff}',
    '.lvci-btn.accent:hover{background:#388bfd}',
    '.lvci-btn[disabled]{opacity:.55;cursor:default}',
    '.lvci-btn .lvci-spin{width:11px;height:11px;border:2px solid rgba(255,255,255,.5);border-top-color:#fff;border-radius:50%;display:inline-block;animation:lvci-spin .7s linear infinite}',
    '@keyframes lvci-spin{to{transform:rotate(360deg)}}',
    // Version badge
    '.lvci-ver{display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:600;color:#8b949e;text-decoration:none;',
      'border:1px solid #30363d;border-radius:999px;padding:4px 10px;white-space:nowrap}',
    '.lvci-ver:hover{color:#e6edf3;border-color:#8b949e;text-decoration:none}',
    '@media(prefers-color-scheme:light){.lvci-ver{color:#57606a;border-color:#d0d7de}.lvci-ver:hover{color:#1f2328;border-color:#57606a}}',
    '.lvci-ver .lvci-dot{width:7px;height:7px;border-radius:50%;background:#d29922;box-shadow:0 0 0 0 rgba(210,153,34,.5);animation:lvci-pulse 1.8s infinite;display:none}',
    '.lvci-ver.behind .lvci-dot{display:inline-block}',
    '@keyframes lvci-pulse{0%{box-shadow:0 0 0 0 rgba(210,153,34,.5)}70%{box-shadow:0 0 0 6px rgba(210,153,34,0)}100%{box-shadow:0 0 0 0 rgba(210,153,34,0)}}',
    // Hamburger (mobile)
    '.lvci-burger{display:none;align-items:center;justify-content:center;width:38px;height:34px;border:1px solid #30363d;border-radius:7px;background:transparent;color:inherit;cursor:pointer;flex:0 0 auto}',
    '@media(prefers-color-scheme:light){.lvci-burger{border-color:#d0d7de}}',
    '.lvci-burger svg{width:18px;height:18px;display:block}',
    // Status line (re-run feedback) sits just under the bar, full width
    '.lvci-status{display:none;align-items:center;gap:8px;font-size:12.5px;padding:7px 16px;border-bottom:1px solid #30363d;',
      'background:rgba(22,27,34,.96);color:#8b949e}',
    '.lvci-status.show{display:flex}',
    '.lvci-status a{color:#58a6ff;text-decoration:none}.lvci-status a:hover{text-decoration:underline}',
    '@media(prefers-color-scheme:light){.lvci-status{background:#f6f8fa;border-bottom-color:#d0d7de;color:#57606a}}',
    // Token panel (re-run needs a PAT once)
    '.lvci-tok{display:none;flex-direction:column;gap:8px;max-width:680px;margin:10px 16px;padding:12px 14px;font-size:13px;line-height:1.5;',
      'background:#161b22;border:1px solid #30363d;border-radius:10px;color:#e6edf3}',
    '.lvci-tok.show{display:flex}',
    '.lvci-tok code{background:#0d1117;padding:1px 5px;border-radius:4px}',
    '.lvci-tok input{padding:7px 9px;border-radius:7px;border:1px solid #30363d;background:#0d1117;color:#e6edf3;font-family:ui-monospace,Menlo,monospace}',
    '@media(prefers-color-scheme:light){.lvci-tok{background:#fff;border-color:#d0d7de;color:#1f2328}.lvci-tok code{background:#eef2f6}.lvci-tok input{background:#fff;border-color:#d0d7de;color:#1f2328}}',
    // ── Mobile menu ───────────────────────────────────────────────────────
    '.lvci-menu{display:none}',
    '@media(max-width:820px){',
      '.lvci-nav,.lvci-actions{display:none}',
      '.lvci-burger{display:inline-flex}',
      '.lvci-brand{flex:1 1 auto}',
      '.lvci-menu.open{display:block;position:sticky;top:var(--lvh-h);z-index:199;',
        'background:rgba(22,27,34,.98);border-bottom:1px solid #30363d;padding:8px}',
      '.lvci-menu a,.lvci-menu button.lvci-m{display:flex;width:100%;align-items:center;gap:9px;text-align:left;',
        'color:#e6edf3;background:transparent;border:0;font-size:15px;font-weight:500;padding:11px 12px;border-radius:8px;text-decoration:none;cursor:pointer}',
      '.lvci-menu a:hover,.lvci-menu button.lvci-m:hover{background:rgba(177,186,196,.12)}',
      '.lvci-menu .lvci-sep{height:1px;background:#30363d;margin:6px 4px}',
      '@media(prefers-color-scheme:light){.lvci-menu.open{background:#fff;border-bottom-color:#d0d7de}.lvci-menu a,.lvci-menu button.lvci-m{color:#1f2328}.lvci-menu .lvci-sep{background:#d0d7de}}',
    '}',
    // Give the page a little breathing room below the sticky bar on small screens
    '@media(max-width:820px){body{overflow-x:hidden}}'
  ].join('\n');

  // ── Inline brand mark (a flow/analysis glyph) ─────────────────────────────
  var BRAND_SVG =
    '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true">' +
      '<rect x="2.5" y="2.5" width="19" height="19" rx="5" stroke="#1f6feb" stroke-width="1.7"/>' +
      '<circle cx="8" cy="8" r="1.9" fill="#1f6feb"/>' +
      '<circle cx="16" cy="8" r="1.9" fill="#2ea043"/>' +
      '<circle cx="12" cy="16" r="1.9" fill="#d29922"/>' +
      '<path d="M8 8.6v3.2a1.6 1.6 0 0 0 1.6 1.6h4.8A1.6 1.6 0 0 0 16 11.8V8.6" stroke="#8b949e" stroke-width="1.5" stroke-linecap="round"/>' +
      '<path d="M12 13.4v1.1" stroke="#8b949e" stroke-width="1.5" stroke-linecap="round"/>' +
    '</svg>';
  var ICON = {
    burger: '<svg viewBox="0 0 24 24" fill="none"><path d="M4 7h16M4 12h16M4 17h16" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>'
  };

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  // ── Primary navigation (the durable site sections). Data-driven so future
  //    capabilities — Builds, Documentation, Unit Tests — are a one-line add. ─
  var NAV = [
    { key: 'dashboard',  label: 'Dashboard',  href: base + '/' },
    { key: 'vi-browser', label: 'VI Browser', href: base + '/vi-snapshots/' }
    // Future (uncomment / extend as capabilities land):
    // { key: 'builds', label: 'Builds', href: base + '/builds/', soon: true },
    // { key: 'docs',   label: 'Docs',   href: base + '/docs/',   soon: true },
    // { key: 'tests',  label: 'Tests',  href: base + '/tests/',  soon: true }
  ];
  // Which nav item is "current" for each context (drives the active pill).
  var NAV_ACTIVE = {
    'dashboard': 'dashboard',
    'vi-browser': 'vi-browser',
    'vi-analyzer-report': 'dashboard',
    'masscompile-report': 'dashboard',
    'report-viewer': 'dashboard',
    'configure': 'dashboard',
    'integrate': 'dashboard',
    'whats-new': 'dashboard'
  };

  // ── Context actions (surfaced on the right; collapse into the mobile menu).
  //    Each action: {label, kind|href, primary|accent, newTab}. `kind` triggers
  //    behavior owned by this header (configure/integrate modal-or-navigate,
  //    rerun dispatch); `href` is a plain link. ──────────────────────────────
  function buildActions() {
    var commitUrl = (repo && cfg.sha) ? ('https://github.com/' + repo + '/commit/' + cfg.sha) : '';
    var A = {
      'dashboard': [
        { label: 'Configure Workers', icon: '\u2699', kind: 'configure', accent: true },
        { label: 'Apply to New Repo', icon: '\u2795', kind: 'integrate', primary: true }
      ],
      'vi-analyzer-report': [
        { label: 'Re-run analysis', icon: '\u21bb', kind: 'rerun', accent: true },
        cfg.rawUrl ? { label: 'Native report', icon: '\u2197', href: cfg.rawUrl, newTab: true } : null,
        commitUrl ? { label: 'This commit', icon: '\u2197', href: commitUrl, newTab: true } : null
      ],
      'masscompile-report': [
        commitUrl ? { label: 'This commit', icon: '\u2197', href: commitUrl, newTab: true } : null
      ],
      'vi-browser': [],
      'report-viewer': [],
      'configure': [],
      'integrate': [],
      'whats-new': []
    };
    return (A[ctx] || []).filter(Boolean);
  }

  // ── Configure / Apply: open the dashboard's modal when present, else navigate
  //    to the standalone page (kept identical content). ──────────────────────
  function openPage(kind) {
    var map = {
      configure: { src: 'configure.html' + (repo ? ('?repo=' + encodeURIComponent(repo)) : ''), title: 'Configure Workers' },
      integrate: { src: 'integrate.html', title: 'Apply to New Repo' }
    };
    var t = map[kind]; if (!t) return;
    if (typeof window.lvciOpen === 'function') { window.lvciOpen(t.src, t.title); return; }
    window.location.href = base + '/' + t.src;
  }

  // ── Re-run analysis: dispatch a fresh run for THIS commit, reusing the
  //    dashboard's token + optimistic queued bridge (so the dashboard cell shows
  //    a spinner immediately). Owned here so it's one implementation everywhere.
  var TOK_KEY = 'lvci_dispatch_token';
  var QKEY = 'lvci_queued_runs';
  function tok() { try { return localStorage.getItem(TOK_KEY) || ''; } catch (e) { return ''; } }
  function rerunWorkflow() {
    return cfg.platform === 'linux' ? 'run-vi-analyzer-linux-container.yml'
                                    : 'run-vi-analyzer-windows-container.yml';
  }
  function setStatus(html, kind) {
    var el = document.getElementById('lvci-status'); if (!el) return;
    el.innerHTML = html || '';
    el.className = 'lvci-status' + (html ? ' show' : '');
    el.style.color = kind === 'ok' ? '#3fb950' : (kind === 'err' ? '#f85149' : '');
  }
  function markQueued() {
    try {
      var o = JSON.parse(localStorage.getItem(QKEY) || '{}') || {};
      o['vi-analyzer|' + cfg.sha] = { ts: Date.now(), plats: [cfg.platform === 'linux' ? 'linux' : 'windows'],
                                      parent: '', short: (cfg.sha || '').slice(0, 7), runs: [] };
      localStorage.setItem(QKEY, JSON.stringify(o));
    } catch (e) {}
  }
  function showTokenPanel() {
    var p = document.getElementById('lvci-tok'); if (!p) return;
    var owner = (repo.split('/')[0]) || '';
    var url = 'https://github.com/settings/personal-access-tokens/new'
      + '?name=' + encodeURIComponent('LabVIEW CI dispatch')
      + '&description=' + encodeURIComponent('Dispatch CI runs for ' + repo)
      + '&target_name=' + encodeURIComponent(owner) + '&actions=write';
    p.innerHTML =
      '<div>Re-running needs a fine-grained token with <strong>Actions: Read and write</strong> on '
      + '<code>' + esc(repo) + '</code>. <a href="' + url + '" target="_blank" rel="noopener" style="color:#58a6ff">Create one \u2197</a> '
      + '(stored only in this browser; shared with the dashboard\u2019s Run now).</div>'
      + '<input id="lvci-tok-in" type="password" placeholder="github_pat_\u2026" autocomplete="off" spellcheck="false">'
      + '<div><button class="lvci-btn primary" id="lvci-tok-save">Save &amp; re-run</button></div>';
    p.className = 'lvci-tok show';
    var inp = document.getElementById('lvci-tok-in');
    if (inp) inp.focus();
    var save = document.getElementById('lvci-tok-save');
    if (save) save.addEventListener('click', function () {
      var v = (inp && inp.value || '').trim(); if (!v) { if (inp) inp.focus(); return; }
      try { localStorage.setItem(TOK_KEY, v); } catch (e) {}
      p.className = 'lvci-tok'; p.innerHTML = '';
      doDispatch();
    });
    if (inp) inp.addEventListener('keydown', function (e) { if (e.key === 'Enter' && save) save.click(); });
  }
  function doDispatch() {
    var btn = document.getElementById('lvci-rerun');
    var wf = rerunWorkflow();
    if (btn) { btn.disabled = true; btn.innerHTML = '<span class="lvci-spin"></span>Queuing\u2026'; }
    setStatus('Queuing a fresh VI Analyzer run\u2026', null);
    fetch('https://api.github.com/repos/' + repo + '/actions/workflows/' + encodeURIComponent(wf) + '/dispatches', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + tok(), 'Accept': 'application/vnd.github+json',
                 'X-GitHub-Api-Version': '2022-11-28', 'Content-Type': 'application/json' },
      body: JSON.stringify({ ref: 'main', inputs: { commit_sha: cfg.sha } })
    }).then(function (r) {
      if (btn) { btn.disabled = false; btn.innerHTML = '\u21bb Re-run analysis'; }
      if (r.status === 204) {
        markQueued();
        setStatus('\u2713 Queued a fresh run \u2014 the <a href="' + base + '/">dashboard</a> cell shows it working now; this report updates when the run finishes. '
          + '<a href="https://github.com/' + repo + '/actions/workflows/' + wf + '" target="_blank" rel="noopener">View runs \u2197</a>', 'ok');
        return;
      }
      if (r.status === 401) { try { localStorage.removeItem(TOK_KEY); } catch (e) {} setStatus('That token was rejected (401). Paste a valid one.', 'err'); showTokenPanel(); return; }
      if (r.status === 403) { setStatus('<strong>403</strong>: the token is missing <strong>Actions: Read and write</strong> on this repository.', 'err'); showTokenPanel(); return; }
      if (r.status === 404) { setStatus('<strong>404</strong>: the token cannot see <code>' + esc(repo) + '</code>. Grant it access + Actions: Read and write.', 'err'); showTokenPanel(); return; }
      setStatus('Dispatch failed (HTTP ' + r.status + ').', 'err');
    }).catch(function (e) {
      if (btn) { btn.disabled = false; btn.innerHTML = '\u21bb Re-run analysis'; }
      setStatus('Network error: ' + esc(String(e && e.message || e)), 'err');
    });
  }
  function rerun() {
    if (!repo || !cfg.sha) { setStatus('Re-run needs a repository and commit.', 'err'); return; }
    if (!tok()) { showTokenPanel(); setStatus('Paste a token to dispatch the run.', null); return; }
    doDispatch();
  }

  // ── Action button factory ─────────────────────────────────────────────────
  function actionEl(a, mobile) {
    var el;
    if (a.href) {
      el = document.createElement('a');
      el.href = a.href;
      if (a.newTab) { el.target = '_blank'; el.rel = 'noopener'; }
    } else {
      el = document.createElement('button');
      el.type = 'button';
    }
    el.className = mobile ? 'lvci-m' : ('lvci-btn' + (a.primary ? ' primary' : (a.accent ? ' accent' : '')));
    if (a.kind === 'rerun' && !mobile) el.id = 'lvci-rerun';
    el.innerHTML = (a.icon ? esc(a.icon) + ' ' : '') + esc(a.label);
    if (!a.href) {
      el.addEventListener('click', function () {
        if (a.kind === 'configure' || a.kind === 'integrate') openPage(a.kind);
        else if (a.kind === 'rerun') rerun();
      });
    }
    return el;
  }

  // ── Build the header DOM ──────────────────────────────────────────────────
  function build() {
    var style = document.createElement('style');
    style.setAttribute('data-lvci-header', '');
    style.textContent = CSS;
    document.head.appendChild(style);

    var hdr = document.createElement('header');
    hdr.className = 'lvci-hdr';

    // Brand
    var brand = document.createElement('a');
    brand.className = 'lvci-brand';
    brand.href = base + '/';
    brand.innerHTML = BRAND_SVG + '<span>LabVIEW CI</span>';
    hdr.appendChild(brand);

    // Primary nav
    var nav = document.createElement('nav');
    nav.className = 'lvci-nav';
    var activeKey = NAV_ACTIVE[ctx] || '';
    NAV.forEach(function (n) {
      var a = document.createElement('a');
      a.href = n.href;
      a.style.position = 'relative';
      if (n.key === activeKey) a.className = 'on';
      a.innerHTML = esc(n.label) + (n.soon ? ' <span class="lvci-soon">soon</span>' : '');
      nav.appendChild(a);
    });
    hdr.appendChild(nav);

    // Actions
    var actions = document.createElement('div');
    actions.className = 'lvci-actions';
    buildActions().forEach(function (a) { actions.appendChild(actionEl(a, false)); });
    // Version badge (always present)
    var ver = document.createElement('a');
    ver.className = 'lvci-ver';
    ver.id = 'lvci-ver';
    ver.href = base + '/whats-new.html';
    ver.innerHTML = '<span class="lvci-dot"></span><span id="lvci-ver-txt">LabVIEW CI</span>';
    actions.appendChild(ver);
    hdr.appendChild(actions);

    // Hamburger
    var burger = document.createElement('button');
    burger.className = 'lvci-burger';
    burger.setAttribute('aria-label', 'Menu');
    burger.innerHTML = ICON.burger;
    hdr.appendChild(burger);

    // Mobile menu
    var menu = document.createElement('div');
    menu.className = 'lvci-menu';
    NAV.forEach(function (n) {
      var a = document.createElement('a');
      a.href = n.href;
      a.innerHTML = esc(n.label) + (n.soon ? ' <span class="lvci-soon">soon</span>' : '');
      menu.appendChild(a);
    });
    var acts = buildActions();
    if (acts.length) {
      var sep = document.createElement('div'); sep.className = 'lvci-sep'; menu.appendChild(sep);
      acts.forEach(function (a) { menu.appendChild(actionEl(a, true)); });
    }
    var sep2 = document.createElement('div'); sep2.className = 'lvci-sep'; menu.appendChild(sep2);
    var wn = document.createElement('a'); wn.href = base + '/whats-new.html'; wn.id = 'lvci-ver-m';
    wn.textContent = "What\u2019s new"; menu.appendChild(wn);
    burger.addEventListener('click', function () { menu.classList.toggle('open'); });

    // Status + token panel (used by re-run)
    var status = document.createElement('div'); status.id = 'lvci-status'; status.className = 'lvci-status';
    var tokp = document.createElement('div'); tokp.id = 'lvci-tok'; tokp.className = 'lvci-tok';

    // ── Mount at the very top of <body> ──────────────────────────────────────
    // Some pages use <body> ITSELF as a full-height flex/grid layout container
    // (e.g. the VI Browser: `body{display:flex;height:100vh}` for a sidebar +
    // main pane). Inserting the header as a plain sibling would make it a flex/
    // grid ITEM laid out *beside* that content instead of above it. Detect that
    // and move the page's content into a wrapper that inherits the original
    // layout, so <body> becomes a vertical stack (header on top, content below).
    var cs = getComputedStyle(document.body);
    if (cs.display.indexOf('flex') >= 0 || cs.display.indexOf('grid') >= 0) {
      var wrap = document.createElement('div');
      wrap.className = 'lvci-content';
      // Re-home the page's own layout onto the wrapper (copy BEFORE mutating
      // <body>, since `cs` is a live computed-style reference).
      ['display', 'flexDirection', 'flexWrap', 'gap', 'rowGap', 'columnGap',
       'alignItems', 'alignContent', 'justifyContent', 'justifyItems',
       'gridTemplateColumns', 'gridTemplateRows', 'gridTemplateAreas',
       'gridAutoFlow', 'gridAutoRows', 'gridAutoColumns',
       'overflowX', 'overflowY'
      ].forEach(function (p) { wrap.style[p] = cs[p]; });
      wrap.style.flex = '1 1 auto';
      wrap.style.minHeight = '0';
      wrap.style.minWidth = '0';
      while (document.body.firstChild) wrap.appendChild(document.body.firstChild);
      document.body.appendChild(wrap);
      document.body.style.display = 'flex';
      document.body.style.flexDirection = 'column';
    }

    var first = document.body.firstChild;
    document.body.insertBefore(tokp, first);
    document.body.insertBefore(status, tokp);
    document.body.insertBefore(menu, status);
    document.body.insertBefore(hdr, menu);
  }

  // ── Version badge: read same-origin catalog.json for the installed version,
  //    and (on consumer repos) compare to the source repo to flag an update. ─
  function loadVersion() {
    // Optimistic "Updating…" paint survives a page refresh: when an update was
    // just dispatched (whats-new.html calls window.lvciMarkUpdating), show it
    // until the deployed catalog catches up. Mirrors the dashboard's old badge.
    var upd = updGet();
    fetch(base + '/catalog.json', { cache: 'no-cache' }).then(function (r) { return r.ok ? r.json() : null; })
      .then(function (cat) {
        if (!cat) return;
        var v = cat.version || '';
        var txt = document.getElementById('lvci-ver-txt');
        if (txt && v) txt.textContent = 'v' + v;
        if (upd && cmpVer(v, upd.v) >= 0) { updClear(); upd = null; }       // deployed caught up
        if (upd) { paintUpdating(upd.v); return; }                         // still updating
        var src = (cat.source && cat.source.repo) || '';
        var isConsumer = src && repo && src.toLowerCase() !== repo.toLowerCase();
        if (!isConsumer) return;
        var ref = (cat.source && cat.source.ref) || 'main';
        fetch('https://raw.githubusercontent.com/' + src + '/' + ref + '/.github/labview-ci/catalog.json', { cache: 'no-cache' })
          .then(function (r) { return r.ok ? r.json() : null; })
          .then(function (s) {
            if (!s || !s.version) return;
            if (cmpVer(s.version, v) > 0) {
              var badge = document.getElementById('lvci-ver');
              if (badge) { badge.classList.add('behind'); badge.title = 'Update available: v' + v + ' \u2192 v' + s.version; }
            }
          }).catch(function () {});
      }).catch(function () {});
  }
  function cmpVer(a, b) {
    var pa = String(a).split('.').map(Number), pb = String(b).split('.').map(Number);
    for (var i = 0; i < 3; i++) { var d = (pa[i] || 0) - (pb[i] || 0); if (d) return d > 0 ? 1 : -1; }
    return 0;
  }
  // In-flight update paint (preserves the dashboard's "Updating…" UX). The
  // What's New dialog dispatches the update then calls window.lvciMarkUpdating
  // (directly when standalone, or via window.parent from the dashboard modal).
  var UPD_KEY = 'lvci_updating', UPD_TTL = 30 * 60 * 1000;
  function updGet() {
    try { var o = JSON.parse(localStorage.getItem(UPD_KEY) || 'null'); if (o && (Date.now() - (o.ts || 0)) < UPD_TTL && o.v) return o; } catch (e) {}
    return null;
  }
  function updClear() { try { localStorage.removeItem(UPD_KEY); } catch (e) {} }
  function paintUpdating(v) {
    var badge = document.getElementById('lvci-ver'), txt = document.getElementById('lvci-ver-txt');
    if (txt) txt.textContent = 'Updating to v' + v + '\u2026';
    if (badge) { badge.classList.add('behind'); badge.title = 'An update to v' + v + ' is in progress (merge the update PR to finish).'; }
  }
  window.lvciMarkUpdating = function (v) {
    if (!v) return;
    try { localStorage.setItem(UPD_KEY, JSON.stringify({ v: v, ts: Date.now() })); } catch (e) {}
    paintUpdating(v);
  };

  function init() { build(); loadVersion(); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
