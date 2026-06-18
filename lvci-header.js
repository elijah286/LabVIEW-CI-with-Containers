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
    // Brand — shows the repository this dashboard belongs to (always visible),
    // with a small product kicker above it. The repo name truncates with an
    // ellipsis so the brand always fits, down to a narrow phone. Falls back to
    // the product name when the repo can't be derived (e.g. a preview build).
    '.lvci-brand{display:inline-flex;align-items:center;gap:10px;color:inherit;text-decoration:none;white-space:nowrap;flex:0 1 auto;min-width:0}',
    '.lvci-brand:hover{text-decoration:none}',
    '.lvci-brand:hover .lvci-name{text-decoration:underline}',
    '.lvci-brand svg{display:block;width:24px;height:24px;flex:0 0 auto}',
    '.lvci-brand .lvci-repo{display:flex;flex-direction:column;justify-content:center;min-width:0;overflow:hidden}',
    '.lvci-brand .lvci-kicker{font-weight:600;font-size:9px;letter-spacing:.07em;text-transform:uppercase;color:#8b949e;line-height:1.3}',
    '.lvci-brand .lvci-name{font-weight:700;font-size:15px;line-height:1.2;color:inherit;min-width:0;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}',
    '@media(prefers-color-scheme:light){.lvci-brand .lvci-kicker{color:#57606a}}',
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
    // Count pill beside a nav item (e.g. Clients), filled in once the registry loads.
    '.lvci-nav a .lvci-ncount{font-size:10px;font-weight:700;color:#8b949e;background:rgba(177,186,196,.16);border-radius:999px;padding:1px 6px;min-width:16px;text-align:center;line-height:1.4}',
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
    // Live CI activity chip — shown in the actions cluster ONLY while one or more
    // workflow runs are in flight; idle leaves the bar clean. It is its own
    // surface (no longer fused onto the version), so activity and version never
    // compete for one pill.
    '.lvci-run-chip{display:none;align-items:center;gap:7px;font-size:12px;font-weight:600;color:#1f6feb;text-decoration:none;',
      'border:1px solid #1f6feb;border-radius:999px;padding:4px 11px;white-space:nowrap}',
    '.lvci-run-chip.show{display:inline-flex}',
    '.lvci-run-chip:hover{background:rgba(31,111,235,.12);text-decoration:none}',
    '.lvci-run-chip .lvci-run-spin{width:9px;height:9px;border:2px solid currentColor;border-right-color:transparent;border-radius:50%;animation:lvci-spin .7s linear infinite}',
    '@media(prefers-color-scheme:light){.lvci-run-chip{color:#0969da;border-color:#0969da}.lvci-run-chip:hover{background:rgba(9,105,218,.08)}}',
    // Update-available cue: a single amber dot on the menu trigger (the More
    // button on desktop, the hamburger on mobile). The version + update action
    // live inside that menu, so this dot is the at-a-glance "you can update" hint.
    '.lvci-mdot{display:none;position:absolute;top:5px;right:5px;width:7px;height:7px;border-radius:50%;background:#d29922;',
      'box-shadow:0 0 0 0 rgba(210,153,34,.5);animation:lvci-pulse 1.8s infinite}',
    '.has-update .lvci-mdot{display:block}',
    '@keyframes lvci-pulse{0%{box-shadow:0 0 0 0 rgba(210,153,34,.5)}70%{box-shadow:0 0 0 5px rgba(210,153,34,0)}100%{box-shadow:0 0 0 0 rgba(210,153,34,0)}}',
    // Version / update entry inside the menu(s): shows the installed version and
    // opens What's New; turns amber + reads "Update available" when behind.
    '.lvci-ddver .lvci-ddver-label{flex:0 1 auto;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}',
    '.lvci-ddver .lvci-ddver-tag{margin-left:auto;padding-left:10px;font-size:11px;font-weight:600;color:#8b949e;white-space:nowrap;font-variant-numeric:tabular-nums}',
    '.lvci-ddver.behind .lvci-ddver-tag,.lvci-ddver.behind .lvci-ic{color:#d29922}',
    '@media(prefers-color-scheme:light){.lvci-ddver .lvci-ddver-tag{color:#57606a}.lvci-ddver.behind .lvci-ddver-tag,.lvci-ddver.behind .lvci-ic{color:#bf8700}}',
    // Revision picker (per-revision reports: switch which revision you're viewing)
    '.lvci-rev{display:inline-flex;align-items:center;gap:7px;flex:0 1 auto;min-width:0}',
    '.lvci-rev .lvci-revlbl{font-size:11px;font-weight:600;color:#8b949e;white-space:nowrap;text-transform:uppercase;letter-spacing:.04em}',
    '.lvci-rev select{font:inherit;font-size:12.5px;font-weight:500;max-width:260px;text-overflow:ellipsis;color:#e6edf3;',
      'background:rgba(177,186,196,.10);border:1px solid #30363d;border-radius:7px;padding:6px 8px;cursor:pointer;color-scheme:dark}',
    '.lvci-rev select:hover{border-color:#8b949e}',
    '@media(prefers-color-scheme:light){.lvci-rev .lvci-revlbl{color:#57606a}.lvci-rev select{color:#1f2328;background:#fff;border-color:#d0d7de;color-scheme:light}}',
    // Hamburger (mobile)
    '.lvci-burger{position:relative;display:none;align-items:center;justify-content:center;width:38px;height:34px;border:1px solid #30363d;border-radius:7px;background:transparent;color:inherit;cursor:pointer;flex:0 0 auto}',
    '@media(prefers-color-scheme:light){.lvci-burger{border-color:#d0d7de}}',
    '.lvci-burger svg{width:18px;height:18px;display:block}',
    // Inline glyph wrapper — sizes the SVG and lets it inherit color (currentColor)
    '.lvci-ic{display:inline-flex;align-items:center;justify-content:center;flex:0 0 auto}',
    '.lvci-ic svg{width:100%;height:100%;display:block}',
    '.lvci-btn .lvci-ic{width:15px;height:15px}',
    // ── Secondary actions: "More" button → popover (Configure / Update / About / theme)
    '.lvci-dropdown{position:relative;display:inline-flex;align-items:center}',
    '.lvci-more{position:relative;display:inline-flex;align-items:center;justify-content:center;width:34px;height:34px;border:1px solid #30363d;background:transparent;color:#8b949e;border-radius:7px;cursor:pointer}',
    '.lvci-more svg{width:18px;height:18px;display:block}',
    '.lvci-more:hover{background:rgba(177,186,196,.12);color:#e6edf3}',
    '.lvci-more.open{background:rgba(177,186,196,.16);color:#e6edf3;border-color:#8b949e}',
    '@media(prefers-color-scheme:light){.lvci-more{border-color:#d0d7de;color:#57606a}.lvci-more:hover,.lvci-more.open{background:rgba(80,90,100,.08);color:#1f2328}}',
    '.lvci-dropdown-menu{display:none;position:absolute;top:100%;right:0;z-index:200;background:rgba(22,27,34,.98);border:1px solid #30363d;border-radius:10px;margin-top:8px;min-width:214px;padding:6px;',
      'box-shadow:0 8px 28px rgba(1,4,9,.5);-webkit-backdrop-filter:saturate(160%) blur(8px);backdrop-filter:saturate(160%) blur(8px)}',
    '.lvci-dropdown-menu.open{display:block;animation:lvci-pop .12s ease-out}',
    '@keyframes lvci-pop{from{opacity:0;transform:translateY(-4px)}to{opacity:1;transform:none}}',
    '.lvci-dropdown-menu>a,.lvci-dropdown-menu>button{display:flex;width:100%;align-items:center;gap:10px;padding:9px 10px;background:transparent;border:0;border-radius:7px;color:#e6edf3;text-decoration:none;font-size:13px;font-weight:500;cursor:pointer;text-align:left}',
    '.lvci-dropdown-menu>a:hover,.lvci-dropdown-menu>button:hover{background:rgba(177,186,196,.12)}',
    '.lvci-dropdown-menu .lvci-ic{width:17px;height:17px;color:#8b949e}',
    '.lvci-dropdown-menu .lvci-sep{height:1px;background:#30363d;margin:5px 4px}',
    '@media(prefers-color-scheme:light){.lvci-dropdown-menu{background:rgba(255,255,255,.98);border-color:#d0d7de;box-shadow:0 8px 28px rgba(140,149,159,.32)}.lvci-dropdown-menu>a,.lvci-dropdown-menu>button{color:#1f2328}.lvci-dropdown-menu>a:hover,.lvci-dropdown-menu>button:hover{background:rgba(80,90,100,.08)}.lvci-dropdown-menu .lvci-ic{color:#57606a}.lvci-dropdown-menu .lvci-sep{background:#d0d7de}}',
    // Appearance (theme) segmented control — lives in the popover and mobile menu
    '.lvci-theme{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:7px 8px 8px 10px}',
    '.lvci-theme-lbl{font-size:11px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;color:#8b949e}',
    '.lvci-seg{display:inline-flex;border:1px solid #30363d;border-radius:8px;overflow:hidden;background:rgba(177,186,196,.06)}',
    '.lvci-seg-btn{display:inline-flex;align-items:center;justify-content:center;width:33px;height:27px;border:0;background:transparent;color:#8b949e;cursor:pointer;padding:0}',
    '.lvci-seg-btn+.lvci-seg-btn{border-left:1px solid #30363d}',
    '.lvci-seg-btn svg{width:15px;height:15px;display:block}',
    '.lvci-seg-btn:hover{color:#e6edf3;background:rgba(177,186,196,.12)}',
    '.lvci-seg-btn.on{background:#1f6feb;color:#fff}',
    '@media(prefers-color-scheme:light){.lvci-theme-lbl{color:#57606a}.lvci-seg{border-color:#d0d7de;background:rgba(80,90,100,.04)}.lvci-seg-btn{color:#57606a}.lvci-seg-btn+.lvci-seg-btn{border-left-color:#d0d7de}.lvci-seg-btn:hover{color:#1f2328;background:rgba(80,90,100,.08)}.lvci-seg-btn.on{background:#0969da;color:#fff}}',
    '@media(max-width:820px){.lvci-dropdown,.lvci-more{display:none}}',
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
    // Rebuild banner (dashboard) — shown while the workflow that regenerates this
    // page (or the Pages publish that follows) is in flight; links to that run.
    '.lvci-rebuild{display:none;align-items:flex-start;gap:10px;padding:10px 16px;border-bottom:1px solid #30363d;background:rgba(31,111,235,.12);color:#e6edf3;font-size:12.5px;line-height:1.5}',
    '.lvci-rebuild.show{display:flex}',
    '.lvci-rebuild .lvci-rb-spin{flex:0 0 auto;width:14px;height:14px;margin-top:3px;border:2px solid rgba(31,111,235,.35);border-top-color:#1f6feb;border-radius:50%;animation:lvci-spin .7s linear infinite}',
    '.lvci-rebuild .lvci-rb-txt{min-width:0}',
    '.lvci-rebuild .lvci-rb-sub{color:#8b949e}',
    '.lvci-rebuild a{color:#58a6ff;text-decoration:none;font-weight:600;white-space:nowrap}',
    '.lvci-rebuild a:hover{text-decoration:underline}',
    '@media(prefers-color-scheme:light){.lvci-rebuild{background:rgba(9,105,218,.09);border-bottom-color:#d0d7de;color:#1f2328}.lvci-rebuild .lvci-rb-sub{color:#57606a}.lvci-rebuild a{color:#0969da}}',
    // ── Mobile menu ───────────────────────────────────────────────────────
    '.lvci-menu{display:none}',
    '@media(max-width:820px){',
      '.lvci-nav,.lvci-actions,.lvci-hdr>.lvci-rev{display:none}',
      '.lvci-burger{display:inline-flex}',
      '.lvci-brand{flex:1 1 auto}',
      '.lvci-menu.open{display:block;position:sticky;top:var(--lvh-h);z-index:199;',
        'background:rgba(22,27,34,.98);border-bottom:1px solid #30363d;padding:8px}',
      '.lvci-menu a,.lvci-menu button.lvci-m{display:flex;width:100%;align-items:center;gap:9px;text-align:left;',
        'color:#e6edf3;background:transparent;border:0;font-size:15px;font-weight:500;padding:11px 12px;border-radius:8px;text-decoration:none;cursor:pointer}',
      '.lvci-menu a:hover,.lvci-menu button.lvci-m:hover{background:rgba(177,186,196,.12)}',
      '.lvci-menu .lvci-ic{width:19px;height:19px;color:#8b949e}',
      '.lvci-menu .lvci-theme{padding:9px 12px}',
      '.lvci-menu .lvci-rev{display:flex;flex-direction:column;align-items:stretch;gap:4px;padding:8px 12px 4px}',
      '.lvci-menu .lvci-rev select{max-width:none;width:100%;font-size:15px;padding:10px}',
      '.lvci-menu .lvci-sep{height:1px;background:#30363d;margin:6px 4px}',
      '@media(prefers-color-scheme:light){.lvci-menu.open{background:#fff;border-bottom-color:#d0d7de}.lvci-menu a,.lvci-menu button.lvci-m{color:#1f2328}.lvci-menu .lvci-sep{background:#d0d7de}}',
    '}',
    // Give the page a little breathing room below the sticky bar on small screens
    '@media(max-width:820px){body{overflow-x:hidden}}',
    // ── Manual appearance override (Appearance control in the menu) ───────────
    // "System" keeps the prefers-color-scheme rules above. Forcing light/dark
    // sets data-lvci-theme on <html>; these rules re-assert the matching tokens
    // and header surfaces at higher specificity, so the choice wins over the OS
    // setting for both the shared header AND the CSS variables every CI page uses.
    ':root[data-lvci-theme=light]{--bg:#ffffff;--surface:#f6f8fa;--border:#d0d7de;--fg:#1f2328;--fg-muted:#57606a;--link:#0969da;--hover:#f3f4f6;--row-border:#eaeef2;--accent:#1f883d;--accent-fg:#fff;--chip:#eaeef2;--code:#f6f8fa;--warn:#9a6700}',
    ':root[data-lvci-theme=dark]{--bg:#0d1117;--surface:#161b22;--border:#30363d;--fg:#e6edf3;--fg-muted:#8b949e;--link:#58a6ff;--hover:#1c2128;--row-border:#21262d;--accent:#238636;--accent-fg:#fff;--chip:#21262d;--code:#010409;--warn:#9a6700}',
    // Forced LIGHT — header surfaces
    ':root[data-lvci-theme=light] .lvci-hdr{background:rgba(255,255,255,.86);border-bottom-color:#d0d7de;color:#1f2328}',
    ':root[data-lvci-theme=light] .lvci-brand .lvci-kicker,:root[data-lvci-theme=light] .lvci-brand .lvci-sub{color:#57606a}',
    ':root[data-lvci-theme=light] .lvci-brand .lvci-sub{border-color:#d0d7de}',
    ':root[data-lvci-theme=light] .lvci-nav a:hover,:root[data-lvci-theme=light] .lvci-nav a.on{color:#1f2328;background:rgba(80,90,100,.10)}',
    ':root[data-lvci-theme=light] .lvci-btn{border-color:#d0d7de}',
    ':root[data-lvci-theme=light] .lvci-btn:hover{background:rgba(80,90,100,.08)}',
    ':root[data-lvci-theme=light] .lvci-run-chip{color:#0969da;border-color:#0969da}',
    ':root[data-lvci-theme=light] .lvci-run-chip:hover{background:rgba(9,105,218,.08)}',
    ':root[data-lvci-theme=light] .lvci-ddver .lvci-ddver-tag{color:#57606a}',
    ':root[data-lvci-theme=light] .lvci-ddver.behind .lvci-ddver-tag,:root[data-lvci-theme=light] .lvci-ddver.behind .lvci-ic{color:#bf8700}',
    ':root[data-lvci-theme=light] .lvci-burger{border-color:#d0d7de}',
    ':root[data-lvci-theme=light] .lvci-more{border-color:#d0d7de;color:#57606a}',
    ':root[data-lvci-theme=light] .lvci-more:hover,:root[data-lvci-theme=light] .lvci-more.open{background:rgba(80,90,100,.08);color:#1f2328}',
    ':root[data-lvci-theme=light] .lvci-dropdown-menu{background:rgba(255,255,255,.98);border-color:#d0d7de;box-shadow:0 8px 28px rgba(140,149,159,.32)}',
    ':root[data-lvci-theme=light] .lvci-dropdown-menu>a,:root[data-lvci-theme=light] .lvci-dropdown-menu>button{color:#1f2328}',
    ':root[data-lvci-theme=light] .lvci-dropdown-menu>a:hover,:root[data-lvci-theme=light] .lvci-dropdown-menu>button:hover{background:rgba(80,90,100,.08)}',
    ':root[data-lvci-theme=light] .lvci-dropdown-menu .lvci-ic{color:#57606a}',
    ':root[data-lvci-theme=light] .lvci-dropdown-menu .lvci-sep,:root[data-lvci-theme=light] .lvci-menu .lvci-sep{background:#d0d7de}',
    ':root[data-lvci-theme=light] .lvci-theme-lbl{color:#57606a}',
    ':root[data-lvci-theme=light] .lvci-seg{border-color:#d0d7de;background:rgba(80,90,100,.04)}',
    ':root[data-lvci-theme=light] .lvci-seg-btn{color:#57606a}',
    ':root[data-lvci-theme=light] .lvci-seg-btn+.lvci-seg-btn{border-left-color:#d0d7de}',
    ':root[data-lvci-theme=light] .lvci-seg-btn:hover{color:#1f2328;background:rgba(80,90,100,.08)}',
    ':root[data-lvci-theme=light] .lvci-seg-btn.on{background:#0969da;color:#fff}',
    ':root[data-lvci-theme=light] .lvci-menu .lvci-ic{color:#57606a}',
    ':root[data-lvci-theme=light] .lvci-rev .lvci-revlbl{color:#57606a}',
    ':root[data-lvci-theme=light] .lvci-rev select{color:#1f2328;background:#fff;border-color:#d0d7de;color-scheme:light}',
    ':root[data-lvci-theme=light] .lvci-status{background:#f6f8fa;border-bottom-color:#d0d7de;color:#57606a}',
    ':root[data-lvci-theme=light] .lvci-tok{background:#fff;border-color:#d0d7de;color:#1f2328}',
    ':root[data-lvci-theme=light] .lvci-tok code{background:#eef2f6}',
    ':root[data-lvci-theme=light] .lvci-tok input{background:#fff;border-color:#d0d7de;color:#1f2328}',
    ':root[data-lvci-theme=light] .lvci-menu.open{background:#fff;border-bottom-color:#d0d7de}',
    ':root[data-lvci-theme=light] .lvci-menu a,:root[data-lvci-theme=light] .lvci-menu button.lvci-m{color:#1f2328}',
    ':root[data-lvci-theme=light] .lvci-rebuild{background:rgba(9,105,218,.09);border-bottom-color:#d0d7de;color:#1f2328}',
    ':root[data-lvci-theme=light] .lvci-rebuild .lvci-rb-sub{color:#57606a}',
    ':root[data-lvci-theme=light] .lvci-rebuild a{color:#0969da}',
    // Forced DARK — counteract an OS light preference
    ':root[data-lvci-theme=dark] .lvci-hdr{background:rgba(22,27,34,.86);border-bottom-color:#30363d;color:#e6edf3}',
    ':root[data-lvci-theme=dark] .lvci-brand .lvci-kicker,:root[data-lvci-theme=dark] .lvci-brand .lvci-sub{color:#8b949e}',
    ':root[data-lvci-theme=dark] .lvci-brand .lvci-sub{border-color:#30363d}',
    ':root[data-lvci-theme=dark] .lvci-nav a:hover,:root[data-lvci-theme=dark] .lvci-nav a.on{color:#e6edf3;background:rgba(177,186,196,.16)}',
    ':root[data-lvci-theme=dark] .lvci-btn{border-color:#30363d}',
    ':root[data-lvci-theme=dark] .lvci-btn:hover{background:rgba(177,186,196,.12)}',
    ':root[data-lvci-theme=dark] .lvci-run-chip{color:#1f6feb;border-color:#1f6feb}',
    ':root[data-lvci-theme=dark] .lvci-run-chip:hover{background:rgba(31,111,235,.12)}',
    ':root[data-lvci-theme=dark] .lvci-ddver .lvci-ddver-tag{color:#8b949e}',
    ':root[data-lvci-theme=dark] .lvci-ddver.behind .lvci-ddver-tag,:root[data-lvci-theme=dark] .lvci-ddver.behind .lvci-ic{color:#d29922}',
    ':root[data-lvci-theme=dark] .lvci-burger{border-color:#30363d}',
    ':root[data-lvci-theme=dark] .lvci-more{border-color:#30363d;color:#8b949e}',
    ':root[data-lvci-theme=dark] .lvci-more:hover,:root[data-lvci-theme=dark] .lvci-more.open{background:rgba(177,186,196,.12);color:#e6edf3}',
    ':root[data-lvci-theme=dark] .lvci-dropdown-menu{background:rgba(22,27,34,.98);border-color:#30363d;box-shadow:0 8px 28px rgba(1,4,9,.5)}',
    ':root[data-lvci-theme=dark] .lvci-dropdown-menu>a,:root[data-lvci-theme=dark] .lvci-dropdown-menu>button{color:#e6edf3}',
    ':root[data-lvci-theme=dark] .lvci-dropdown-menu>a:hover,:root[data-lvci-theme=dark] .lvci-dropdown-menu>button:hover{background:rgba(177,186,196,.12)}',
    ':root[data-lvci-theme=dark] .lvci-dropdown-menu .lvci-ic{color:#8b949e}',
    ':root[data-lvci-theme=dark] .lvci-dropdown-menu .lvci-sep,:root[data-lvci-theme=dark] .lvci-menu .lvci-sep{background:#30363d}',
    ':root[data-lvci-theme=dark] .lvci-theme-lbl{color:#8b949e}',
    ':root[data-lvci-theme=dark] .lvci-seg{border-color:#30363d;background:rgba(177,186,196,.06)}',
    ':root[data-lvci-theme=dark] .lvci-seg-btn{color:#8b949e}',
    ':root[data-lvci-theme=dark] .lvci-seg-btn+.lvci-seg-btn{border-left-color:#30363d}',
    ':root[data-lvci-theme=dark] .lvci-seg-btn:hover{color:#e6edf3;background:rgba(177,186,196,.12)}',
    ':root[data-lvci-theme=dark] .lvci-seg-btn.on{background:#1f6feb;color:#fff}',
    ':root[data-lvci-theme=dark] .lvci-menu .lvci-ic{color:#8b949e}',
    ':root[data-lvci-theme=dark] .lvci-rev .lvci-revlbl{color:#8b949e}',
    ':root[data-lvci-theme=dark] .lvci-rev select{color:#e6edf3;background:rgba(177,186,196,.10);border-color:#30363d;color-scheme:dark}',
    ':root[data-lvci-theme=dark] .lvci-status{background:rgba(22,27,34,.96);border-bottom-color:#30363d;color:#8b949e}',
    ':root[data-lvci-theme=dark] .lvci-tok{background:#161b22;border-color:#30363d;color:#e6edf3}',
    ':root[data-lvci-theme=dark] .lvci-tok code{background:#0d1117}',
    ':root[data-lvci-theme=dark] .lvci-tok input{background:#0d1117;border-color:#30363d;color:#e6edf3}',
    ':root[data-lvci-theme=dark] .lvci-menu.open{background:rgba(22,27,34,.98);border-bottom-color:#30363d}',
    ':root[data-lvci-theme=dark] .lvci-rebuild{background:rgba(31,111,235,.12);border-bottom-color:#30363d;color:#e6edf3}',
    ':root[data-lvci-theme=dark] .lvci-rebuild .lvci-rb-sub{color:#8b949e}',
    ':root[data-lvci-theme=dark] .lvci-rebuild a{color:#58a6ff}',
    ':root[data-lvci-theme=dark] .lvci-menu a,:root[data-lvci-theme=dark] .lvci-menu button.lvci-m{color:#e6edf3}'
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
  // Crisp, stroke-based glyphs (Lucide-style). Sized via CSS; inherit color via
  // currentColor so they adapt to dark/light and hover states automatically.
  var ICON = {
    burger: '<svg viewBox="0 0 24 24" fill="none"><path d="M4 7h16M4 12h16M4 17h16" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
    more: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="5" r="1.3"/><circle cx="12" cy="12" r="1.3"/><circle cx="12" cy="19" r="1.3"/></svg>',
    integrate: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9.5"/><line x1="12" y1="8" x2="12" y2="16"/><line x1="8" y1="12" x2="16" y2="12"/></svg>',
    configure: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/><line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/><line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/><line x1="1.5" y1="14" x2="6.5" y2="14"/><line x1="9.5" y1="8" x2="14.5" y2="8"/><line x1="17.5" y1="16" x2="22.5" y2="16"/></svg>',
    update: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="M7 10l5 5 5-5"/><line x1="12" y1="15" x2="12" y2="3"/></svg>',
    about: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9.5"/><line x1="12" y1="16" x2="12" y2="11.5"/><line x1="12" y1="8" x2="12.01" y2="8"/></svg>',
    news: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="none"><path d="M11.5 3l1.8 5.2 5.2 1.8-5.2 1.8L11.5 17l-1.8-5.2L4.5 10l5.2-1.8z"/><path d="M18 14l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z"/></svg>',
    history: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3v5h5"/><path d="M3.05 13A9 9 0 1 0 6 5.3L3 8"/><path d="M12 7v5l4 2"/></svg>',
    tests: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 3h6"/><path d="M10 3v6L5.4 17.5A1.5 1.5 0 0 0 6.7 20h10.6a1.5 1.5 0 0 0 1.3-2.5L14 9V3"/><line x1="7.5" y1="14" x2="16.5" y2="14"/></svg>',
    sun: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 1.8v2.4M12 19.8v2.4M4.2 4.2l1.7 1.7M18.1 18.1l1.7 1.7M1.8 12h2.4M19.8 12h2.4M4.2 19.8l1.7-1.7M18.1 5.9l1.7-1.7"/></svg>',
    moon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>',
    system: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="3.5" width="19" height="13" rx="2"/><line x1="8.5" y1="20.5" x2="15.5" y2="20.5"/><line x1="12" y1="16.5" x2="12" y2="20.5"/></svg>'
  };

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  // Leading glyph for an action: a sized SVG wrapper (a.svg) or, as a fallback,
  // an escaped text/emoji glyph (a.icon). SVG strings are our own trusted markup.
  function iconHtml(a) {
    if (a.svg) return '<span class="lvci-ic">' + a.svg + '</span>';
    return a.icon ? esc(a.icon) + ' ' : '';
  }

  // ── Appearance: dark / light / system ─────────────────────────────────────
  // Persisted per browser. "system" (the default) follows prefers-color-scheme;
  // light/dark set data-lvci-theme on <html> so our overrides win over the OS
  // setting for the shared header AND every CI page's standard CSS tokens.
  var THEME_KEY = 'lvci-theme';
  function getTheme() {
    try { var t = localStorage.getItem(THEME_KEY); return (t === 'light' || t === 'dark') ? t : 'system'; }
    catch (e) { return 'system'; }
  }
  function applyTheme(t) {
    var r = document.documentElement;
    if (t === 'light' || t === 'dark') { r.setAttribute('data-lvci-theme', t); r.style.colorScheme = t; }
    else { r.removeAttribute('data-lvci-theme'); r.style.colorScheme = 'light dark'; }
  }
  function markThemeControls(t) {
    var btns = document.querySelectorAll('.lvci-seg-btn');
    for (var i = 0; i < btns.length; i++) btns[i].classList.toggle('on', btns[i].getAttribute('data-theme') === t);
  }
  function setTheme(t) {
    try { localStorage.setItem(THEME_KEY, t); } catch (e) {}
    applyTheme(t);
    markThemeControls(t);
  }
  // A compact segmented control (Light / Dark / System) for the menus.
  function themeControl() {
    var wrap = document.createElement('div'); wrap.className = 'lvci-theme';
    var lbl = document.createElement('span'); lbl.className = 'lvci-theme-lbl'; lbl.textContent = 'Appearance';
    var seg = document.createElement('div'); seg.className = 'lvci-seg';
    seg.setAttribute('role', 'group'); seg.setAttribute('aria-label', 'Appearance');
    var cur = getTheme();
    [['light', ICON.sun, 'Light'], ['dark', ICON.moon, 'Dark'], ['system', ICON.system, 'System']].forEach(function (o) {
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'lvci-seg-btn' + (o[0] === cur ? ' on' : '');
      b.setAttribute('data-theme', o[0]);
      b.title = o[2]; b.setAttribute('aria-label', o[2] + ' appearance');
      b.innerHTML = o[1];
      b.addEventListener('click', function (e) { e.stopPropagation(); setTheme(o[0]); });
      seg.appendChild(b);
    });
    wrap.appendChild(lbl); wrap.appendChild(seg);
    return wrap;
  }
  // Honour the saved choice as early as the script runs (minimises any flash).
  applyTheme(getTheme());

  // ── Primary navigation (the durable site sections). Data-driven so future
  //    capabilities — Builds, Documentation, Unit Tests — are a one-line add. ─
  var NAV = [
    { key: 'dashboard',   label: 'Dashboard',    href: base + '/' },
    { key: 'vi-browser',  label: 'VI Browser',   href: base + '/vi-snapshots/' },
    // Clients: the registry of repos running this tooling. Root/source repo ONLY
    // - hidden by default and revealed by loadClients() wherever clients.json
    // (which only the root publishes) is served, so it never shows on a consumer.
    { key: 'clients',     label: 'Clients',      href: base + '/clients.html', source: true }
    // Future (uncomment / extend as capabilities land):
    // { key: 'builds', label: 'Builds', href: base + '/builds/', soon: true },
    // { key: 'docs',   label: 'Docs',   href: base + '/docs/',   soon: true }
  ];
  // Which nav item is "current" for each context (drives the active pill).
  var NAV_ACTIVE = {
    'dashboard': 'dashboard',
    'vi-browser': 'vi-browser',
    'vi-analyzer-report': 'dashboard',
    'masscompile-report': 'dashboard',
    'unit-tests-report': 'dashboard',
    'antidoc-report': 'dashboard',
    'unit-tests-config': 'dashboard',
    'worker-manifest': 'dashboard',
    'report-viewer': 'dashboard',
    'configure': 'dashboard',
    'integrate': 'dashboard',
    'whats-new': 'dashboard',
    'faq': 'dashboard',
    'clients': 'clients'
  };

  // ── Per-revision DOCUMENT types ───────────────────────────────────────────
  // Every report that is produced for a specific commit is described here once.
  // This drives, for that context: the "Regenerate … for this revision" action
  // (dispatches `workflow[platform]` with inputs.commit_sha), the revision
  // <select> in the header (a page lives at `<prefix>/<sha>/index.html`, and a
  // report is "available" when `<prefix>/<sha>/summary.json` exists), the
  // dashboard's optimistic queued bridge key (`cap|sha`), and the status text.
  // Adding a FUTURE document type is a single entry here + emitting the same
  // window.LVCI config from its generator — no other change to this file.
  var DOCTYPES = {
    'vi-analyzer-report': {
      prefix: 'vi-analyzer', cap: 'vi-analyzer', label: 'VI Analyzer',
      regenLabel: 'Re-run analysis', rawLabel: 'Native report', rawName: 'raw.html',
      workflow: { windows: 'run-vi-analyzer-windows-container.yml',
                  linux:   'run-vi-analyzer-linux-container.yml' }
    },
    'masscompile-report': {
      prefix: 'masscompile', cap: 'masscompile', label: 'Mass Compile',
      regenLabel: 'Regenerate report', rawLabel: 'Raw log', rawName: 'masscompile.log',
      workflow: { windows: 'masscompile-windows-container.yml',
                  linux:   'masscompile-linux-container.yml' }
    },
    'unit-tests-report': {
      prefix: 'unit-tests', cap: 'unit-tests', label: 'Unit Tests',
      regenLabel: 'Re-run tests', rawLabel: 'Test results (JSON)', rawName: 'results.json',
      workflow: { windows: 'unit-tests-windows-container.yml',
                  linux:   'unit-tests-linux-container.yml' }
    },
    'antidoc-report': {
      prefix: 'antidoc', cap: 'antidoc', label: 'Antidoc',
      regenLabel: 'Regenerate docs', rawLabel: 'Run log', rawName: 'antidoc.log',
      workflow: { windows: 'run-antidoc-windows-container.yml' }
    }
  };
  var DOC = DOCTYPES[ctx] || null;   // non-null only on a per-revision report

  // ── Context actions (surfaced on the right; collapse into the mobile menu).
  //    Each action: {label, kind|href, primary|accent, newTab}. `kind` triggers
  //    behavior owned by this header (configure/integrate modal-or-navigate,
  //    rerun dispatch); `href` is a plain link. ──────────────────────────────
  function buildActions() {
    var commitUrl = (repo && cfg.sha) ? ('https://github.com/' + repo + '/commit/' + cfg.sha) : '';
    // Per-revision reports (VI Analyzer, Mass Compile, …) share one action set,
    // driven by the DOCTYPES entry: Regenerate (dispatch this revision's run),
    // the native artifact (raw report / raw log), and the commit on GitHub.
    if (DOC) {
      // The native artifact (raw report / log) sits beside the report's own
      // index.html. When this header is the framed viewer chrome, derive that
      // path from the embedded source so it resolves regardless of platform or
      // depth; otherwise fall back to the report's own rawUrl (set by its
      // generator on the bare report page).
      var rawHref = cfg.rawUrl;
      if (cfg.embedded && cfg.framedSrc && DOC.rawName) rawHref = cfg.framedSrc.replace(/[^\/]*$/, DOC.rawName);
      return [
        { label: DOC.regenLabel, icon: '\u21bb', kind: 'rerun', accent: true },
        rawHref ? { label: DOC.rawLabel, icon: '\u2197', href: rawHref, newTab: true } : null,
        commitUrl ? { label: 'This commit', icon: '\u2197', href: commitUrl, newTab: true } : null
      ].filter(Boolean);
    }
    var A = {
      'dashboard': [
        { label: 'Apply to New Repo', svg: ICON.integrate, kind: 'integrate', primary: true }
      ],
      'worker-manifest': [],
      'vi-browser': [],
      'report-viewer': [],
      'configure': [],
      'integrate': [],
      'whats-new': [],
      'faq': []
    };
    return (A[ctx] || []).filter(Boolean);
  }
  function buildSecondaryActions() {
    var A = {
      'dashboard': [
        { label: 'Populate history', svg: ICON.history, kind: 'runhistory' },
        { label: 'Configure Workers', svg: ICON.configure, kind: 'configure' },
        { label: 'Unit Testing', svg: ICON.tests, kind: 'unittests' },
        { label: 'About', svg: ICON.about, href: base + '/faq.html' }
      ],
      'worker-manifest': [],
      'vi-browser': [
        { label: 'About', svg: ICON.about, href: base + '/faq.html' }
      ],
      'report-viewer': [],
      'configure': [],
      'integrate': [],
      'whats-new': [],
      'faq': []
    };
    return (A[ctx] || []).filter(Boolean);
  }

  // ── Configure / Apply: open the dashboard's modal when present, else navigate
  //    to the standalone page (kept identical content). ──────────────────────
  function openPage(kind) {
    var map = {
      configure: { src: 'configure.html' + (repo ? ('?repo=' + encodeURIComponent(repo)) : ''), title: 'Configure Workers' },
      unittests: { src: 'unit-tests.html' + (repo ? ('?repo=' + encodeURIComponent(repo)) : ''), title: 'Unit Testing' },
      integrate: { src: 'integrate.html', title: 'Apply to New Repo' }
    };
    var t = map[kind]; if (!t) return;
    if (typeof window.lvciOpen === 'function') { window.lvciOpen(t.src, t.title); return; }
    window.location.href = base + '/' + t.src;
  }

  // ── Populate history: open the dashboard's "Populate dashboard history" dialog
  //    (queue CI for existing revisions). The dialog itself lives in the dashboard
  //    generator, which exposes window.lvciRunHistory; this menu item is only
  //    offered on the dashboard context, where that hook is present. The guard
  //    keeps it inert anywhere the hook is absent (e.g. an older dashboard). ────
  function runHistory() {
    if (typeof window.lvciRunHistory === 'function') window.lvciRunHistory();
    else window.location.href = base + '/';   // fall back to the dashboard
  }

  // ── Regenerate this revision's report: dispatch a fresh run for THIS commit,
  //    reusing the dashboard's token + optimistic queued bridge (so the
  //    dashboard cell shows a spinner immediately). Owned here so it's one
  //    implementation for every per-revision document type (see DOCTYPES). ────
  var TOK_KEY = 'lvci_dispatch_token';
  var QKEY = 'lvci_queued_runs';
  function tok() { try { return localStorage.getItem(TOK_KEY) || ''; } catch (e) { return ''; } }
  function rerunWorkflow() {
    var wf = (DOC && DOC.workflow) || {};
    return cfg.platform === 'linux' ? (wf.linux || wf.windows) : (wf.windows || wf.linux);
  }
  function setStatus(html, kind) {
    var el = document.getElementById('lvci-status'); if (!el) return;
    el.innerHTML = html || '';
    el.className = 'lvci-status' + (html ? ' show' : '');
    el.style.color = kind === 'ok' ? '#3fb950' : (kind === 'err' ? '#f85149' : '');
  }
  function markQueued() {
    if (!DOC) return;
    try {
      var o = JSON.parse(localStorage.getItem(QKEY) || '{}') || {};
      o[DOC.cap + '|' + cfg.sha] = { ts: Date.now(), plats: [cfg.platform === 'linux' ? 'linux' : 'windows'],
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
      '<div>Regenerating needs a fine-grained token with <strong>Actions: Read and write</strong> on '
      + '<code>' + esc(repo) + '</code>. <a href="' + url + '" target="_blank" rel="noopener" style="color:#58a6ff">Create one \u2197</a> '
      + '(stored only in this browser; shared with the dashboard\u2019s Run now).</div>'
      + '<input id="lvci-tok-in" type="password" placeholder="github_pat_\u2026" autocomplete="off" spellcheck="false">'
      + '<div><button class="lvci-btn primary" id="lvci-tok-save">Save &amp; regenerate</button></div>';
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
    var label = (DOC && DOC.regenLabel) || 'Regenerate report';
    var docLabel = (DOC && DOC.label) || 'report';
    if (btn) { btn.disabled = true; btn.innerHTML = '<span class="lvci-spin"></span>Queuing\u2026'; }
    setStatus('Queuing a fresh ' + esc(docLabel) + ' run\u2026', null);
    fetch('https://api.github.com/repos/' + repo + '/actions/workflows/' + encodeURIComponent(wf) + '/dispatches', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + tok(), 'Accept': 'application/vnd.github+json',
                 'X-GitHub-Api-Version': '2022-11-28', 'Content-Type': 'application/json' },
      body: JSON.stringify({ ref: 'main', inputs: { commit_sha: cfg.sha } })
    }).then(function (r) {
      if (btn) { btn.disabled = false; btn.innerHTML = '\u21bb ' + esc(label); }
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
      if (btn) { btn.disabled = false; btn.innerHTML = '\u21bb ' + esc(label); }
      setStatus('Network error: ' + esc(String(e && e.message || e)), 'err');
    });
  }
  function rerun() {
    if (!repo || !cfg.sha) { setStatus('Regenerating needs a repository and commit.', 'err'); return; }
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
    el.innerHTML = iconHtml(a) + esc(a.label);
    if (!a.href) {
      el.addEventListener('click', function () {
        if (a.kind === 'configure' || a.kind === 'integrate' || a.kind === 'unittests') openPage(a.kind);
        else if (a.kind === 'rerun') rerun();
        else if (a.kind === 'runhistory') runHistory();
      });
    }
    return el;
  }

  // ── Revision picker (per-revision reports only) ───────────────────────────
  // Reuses the VI Browser's "pick a commit" metaphor: a <select> of revisions
  // that, when changed, opens the SAME document type for that revision
  // (`<prefix>/<sha>/index.html`). The revision list comes from the SAME source
  // the VI Browser uses — vi-snapshots/{files.json,commits.json} — and is
  // filtered to revisions that actually have a report of this type (probed via
  // `<prefix>/<sha>/summary.json`), so it never lands on a 404. The revision
  // being viewed is always present + selected, even while the probe runs.
  // Where "view another revision" lands. Normally the bare per-revision report;
  // but when this header is the framed VIEWER chrome (report-viewer.html embeds
  // the report in an iframe), re-frame the viewer onto the new revision so the
  // chrome — and its Regenerate button — stays put instead of dropping the user
  // onto a bare (and, for older revisions, possibly header-less) report page.
  function docDest(sha) {
    if (!DOC || !sha) return base + '/';
    if (cfg.embedded && cfg.framedSrc) {
      var src = cfg.sha ? cfg.framedSrc.split(cfg.sha).join(sha) : cfg.framedSrc;
      var title = DOC.label + ' \u00b7 ' + sha.slice(0, 7);
      return base + '/report/index.html?type=' + encodeURIComponent(ctx)
           + '&sha=' + encodeURIComponent(sha)
           + (cfg.platform ? '&platform=' + encodeURIComponent(cfg.platform) : '')
           + '&src=' + encodeURIComponent(src)
           + '&title=' + encodeURIComponent(title);
    }
    return base + '/' + DOC.prefix + '/' + sha + '/index.html';
  }
  function makeRevPicker() {
    var wrap = document.createElement('label'); wrap.className = 'lvci-rev';
    var lbl = document.createElement('span'); lbl.className = 'lvci-revlbl'; lbl.textContent = 'Revision';
    var sel = document.createElement('select');
    sel.setAttribute('aria-label', 'View another revision\u2019s ' + (DOC ? DOC.label : '') + ' report');
    var cur = document.createElement('option');
    cur.value = cfg.sha || '';
    cur.textContent = (cfg.short || (cfg.sha || '').slice(0, 7)) || 'this revision';
    sel.appendChild(cur);
    sel.value = cfg.sha || '';
    sel.addEventListener('change', function () {
      var v = sel.value;
      if (v && v !== cfg.sha) window.location.href = docDest(v);
    });
    wrap.appendChild(lbl); wrap.appendChild(sel);
    return { wrap: wrap, sel: sel };
  }
  function optionLabel(c) {
    var msg = (c.message || '').split('\n')[0];
    return (c.short || (c.sha || '').slice(0, 7)) + (msg ? (' \u2014 ' + msg.slice(0, 42)) : '')
         + (c.sha === cfg.sha ? '  \u00b7 current' : '');
  }
  function loadRevisions(selects) {
    if (!DOC || !selects.length) return;
    var jget = function (u) { return fetch(u, { cache: 'no-cache' }).then(function (r) { return r.ok ? r.json() : null; }).catch(function () { return null; }); };
    Promise.all([jget(base + '/vi-snapshots/files.json'), jget(base + '/vi-snapshots/commits.json')]).then(function (res) {
      var filesDoc = res[0], snap = res[1];
      var fileCommits = (filesDoc && Array.isArray(filesDoc.commits)) ? filesDoc.commits : [];
      var fileShas = {}; fileCommits.forEach(function (c) { fileShas[c.sha] = 1; });
      var order = [], bySha = {};
      var put = function (c) { if (!c || !c.sha) return; var p = bySha[c.sha] || {}; for (var k in c) if (c[k] != null) p[k] = c[k]; bySha[c.sha] = p; if (order.indexOf(c.sha) < 0) order.push(c.sha); };
      (Array.isArray(snap) ? snap : []).forEach(function (c) { if (!fileShas[c.sha]) put(c); });
      fileCommits.forEach(function (c) { put({ sha: c.sha, short: c.short, message: c.message, author: c.author, date: c.date }); });
      var list = order.map(function (s) { return bySha[s]; });
      if (cfg.sha && !bySha[cfg.sha]) list.unshift({ sha: cfg.sha, short: cfg.short || cfg.sha.slice(0, 7), message: '' });

      // Probe which revisions actually have a report of THIS type; the current
      // revision is known-present (it's the page we're on).
      var toCheck = list.filter(function (c) { return c.sha && c.sha !== cfg.sha; });
      var avail = {}; if (cfg.sha) avail[cfg.sha] = true;
      function fill() {
        var final = list.filter(function (c) { return c.sha === cfg.sha || avail[c.sha]; });
        if (!final.length) return;
        selects.forEach(function (sel) {
          sel.innerHTML = '';
          final.forEach(function (c) {
            var o = document.createElement('option'); o.value = c.sha; o.textContent = optionLabel(c);
            sel.appendChild(o);
          });
          sel.value = cfg.sha || final[0].sha;
        });
      }
      if (!toCheck.length) { fill(); return; }
      var idx = 0, done = 0, total = toCheck.length, CAP = 8;
      function next() {
        if (idx >= total) return;
        var c = toCheck[idx++];
        fetch(base + '/' + DOC.prefix + '/' + c.sha + '/summary.json', { method: 'HEAD', cache: 'no-cache' })
          .then(function (r) { avail[c.sha] = r.ok; }).catch(function () { avail[c.sha] = false; })
          .then(function () { done++; if (done === total) fill(); else next(); });
      }
      for (var k = 0; k < Math.min(CAP, total); k++) next();
    }).catch(function () {});
  }

  // ── Version / update menu entry ───────────────────────────────────────────
  // A single home for the installed version + the update affordance (it replaces
  // the old always-on version pill). Used in the More popover and the mobile
  // menu; renderBadge() fills its label/tag/icon and toggles the amber "behind"
  // state. Always links to What's New (release notes / the update flow).
  function makeVerItem() {
    var a = document.createElement('a');
    a.className = 'lvci-ddver';
    a.href = base + '/whats-new.html';
    a.innerHTML = '<span class="lvci-ic">' + ICON.news + '</span>'
      + '<span class="lvci-ddver-label">What\u2019s new</span>'
      + '<span class="lvci-ddver-tag"></span>';
    return a;
  }

  // ── Build the header DOM ──────────────────────────────────────────────────
  function build() {
    var style = document.createElement('style');
    style.setAttribute('data-lvci-header', '');
    style.textContent = CSS;
    document.head.appendChild(style);

    var hdr = document.createElement('header');
    hdr.className = 'lvci-hdr';

    // Brand — the repository this site is for, always visible, with a small
    // "LabVIEW CI" kicker so the product identity is kept. Falls back to the
    // product name when no repo can be derived. The whole mark links home.
    var brand = document.createElement('a');
    brand.className = 'lvci-brand';
    brand.href = base + '/';
    if (repo) {
      var rname = repo.split('/').pop();
      brand.title = repo;                                      // full owner/name on hover
      brand.setAttribute('aria-label', 'LabVIEW CI \u2014 ' + repo);
      brand.innerHTML = BRAND_SVG +
        '<span class="lvci-repo">' +
          '<span class="lvci-kicker">LabVIEW CI</span>' +
          '<span class="lvci-name">' + esc(rname) + '</span>' +
        '</span>';
    } else {
      brand.setAttribute('aria-label', 'LabVIEW CI');
      brand.innerHTML = BRAND_SVG + '<span class="lvci-repo"><span class="lvci-name">LabVIEW CI</span></span>';
    }
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
      a.innerHTML = esc(n.label) + (n.soon ? ' <span class="lvci-soon">soon</span>' : '')
        + (n.source ? ' <span class="lvci-ncount" hidden></span>' : '');
      if (n.source) { a.style.display = 'none'; clientsEls.push(a); }
      nav.appendChild(a);
    });
    hdr.appendChild(nav);

    // Revision picker (per-revision report contexts only) — sits just left of
    // the actions cluster so "which revision" + "Regenerate" read together.
    var revBar = null, revMenu = null;
    if (DOC) { revBar = makeRevPicker(); hdr.appendChild(revBar.wrap); }

    // Actions
    var actions = document.createElement('div');
    actions.className = 'lvci-actions';
    // Live CI activity chip (transient) leads the cluster so the stable
    // [primary action][More] pairing keeps its position when nothing is running.
    var runChip = document.createElement('a');
    runChip.className = 'lvci-run-chip';
    runChip.id = 'lvci-runchip';
    if (repo) { runChip.href = 'https://github.com/' + repo + '/actions'; runChip.target = '_blank'; runChip.rel = 'noopener'; }
    runChip.innerHTML = '<span class="lvci-run-spin" aria-hidden="true"></span><span id="lvci-runchip-txt">running</span>';
    actions.appendChild(runChip);
    buildActions().forEach(function (a) { actions.appendChild(actionEl(a, false)); });
    // "More" popover — always present so the Appearance control is available
    // site-wide; it also hosts any context-specific secondary actions
    // (Configure Workers / Update / About on the dashboard and VI Browser).
    var secActions = buildSecondaryActions();
    {
      var dropdown = document.createElement('div');
      dropdown.className = 'lvci-dropdown';
      var moreBtn = document.createElement('button');
      moreBtn.className = 'lvci-more';
      moreBtn.id = 'lvci-more';
      moreBtn.setAttribute('aria-label', 'More options');
      moreBtn.setAttribute('aria-haspopup', 'true');
      moreBtn.setAttribute('aria-expanded', 'false');
      moreBtn.innerHTML = ICON.more + '<span class="lvci-mdot" aria-hidden="true"></span>';
      dropdown.appendChild(moreBtn);
      var ddMenu = document.createElement('div');
      ddMenu.className = 'lvci-dropdown-menu';
      var closeDD = function () { ddMenu.classList.remove('open'); moreBtn.classList.remove('open'); moreBtn.setAttribute('aria-expanded', 'false'); };
      secActions.forEach(function (a) {
        var el;
        if (a.href) {
          el = document.createElement('a');
          el.href = a.href;
          if (a.newTab) { el.target = '_blank'; el.rel = 'noopener'; }
          el.addEventListener('click', closeDD);
        } else {
          el = document.createElement('button');
          el.type = 'button';
          el.addEventListener('click', function () {
            if (a.kind === 'configure' || a.kind === 'integrate' || a.kind === 'unittests') openPage(a.kind);
            else if (a.kind === 'runhistory') runHistory();
            closeDD();
          });
        }
        el.innerHTML = iconHtml(a) + esc(a.label);
        ddMenu.appendChild(el);
      });
      // Version / update entry — the single home for the installed version and
      // the update affordance (replaces the standalone badge); links to What's New.
      if (ddMenu.children.length) { var vsep = document.createElement('div'); vsep.className = 'lvci-sep'; ddMenu.appendChild(vsep); }
      var ddVer = makeVerItem(); ddVer.addEventListener('click', closeDD); ddMenu.appendChild(ddVer); verEls.push(ddVer);
      // Appearance (theme) control — divided below.
      var dsep = document.createElement('div'); dsep.className = 'lvci-sep'; ddMenu.appendChild(dsep);
      ddMenu.appendChild(themeControl());
      dropdown.appendChild(ddMenu);
      moreBtn.addEventListener('click', function (e) {
        e.stopPropagation();
        var open = ddMenu.classList.toggle('open');
        moreBtn.classList.toggle('open', open);
        moreBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
      });
      // Clicks inside the popover (e.g. the Appearance buttons) keep it open.
      ddMenu.addEventListener('click', function (e) { e.stopPropagation(); });
      document.addEventListener('click', closeDD);
      document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeDD(); });
      actions.appendChild(dropdown);
    }
    hdr.appendChild(actions);

    // Hamburger
    var burger = document.createElement('button');
    burger.className = 'lvci-burger';
    burger.id = 'lvci-burger';
    burger.setAttribute('aria-label', 'Menu');
    burger.innerHTML = ICON.burger + '<span class="lvci-mdot" aria-hidden="true"></span>';
    hdr.appendChild(burger);

    // Mobile menu
    var menu = document.createElement('div');
    menu.className = 'lvci-menu';
    if (DOC) { revMenu = makeRevPicker(); menu.appendChild(revMenu.wrap); var sep0 = document.createElement('div'); sep0.className = 'lvci-sep'; menu.appendChild(sep0); }
    NAV.forEach(function (n) {
      var a = document.createElement('a');
      a.href = n.href;
      a.innerHTML = esc(n.label) + (n.soon ? ' <span class="lvci-soon">soon</span>' : '')
        + (n.source ? ' <span class="lvci-ncount" hidden></span>' : '');
      if (n.source) { a.style.display = 'none'; clientsEls.push(a); }
      menu.appendChild(a);
    });
    var acts = buildActions();
    if (acts.length) {
      var sep = document.createElement('div'); sep.className = 'lvci-sep'; menu.appendChild(sep);
      acts.forEach(function (a) { menu.appendChild(actionEl(a, true)); });
    }
    var secActs = buildSecondaryActions();
    if (secActs.length) {
      var sep = document.createElement('div'); sep.className = 'lvci-sep'; menu.appendChild(sep);
      secActs.forEach(function (a) { menu.appendChild(actionEl(a, true)); });
    }
    // Version / update entry (mobile) — same single home as the dropdown.
    var sepV = document.createElement('div'); sepV.className = 'lvci-sep'; menu.appendChild(sepV);
    var mVer = makeVerItem(); menu.appendChild(mVer); verEls.push(mVer);
    // Appearance (theme) control in the mobile menu
    var sepT = document.createElement('div'); sepT.className = 'lvci-sep'; menu.appendChild(sepT);
    menu.appendChild(themeControl());
    burger.addEventListener('click', function () { menu.classList.toggle('open'); });

    // Populate the revision picker(s) once mounted (async; filters to revisions
    // that actually have a report of this type).
    if (DOC) {
      var sels = [];
      if (revBar) sels.push(revBar.sel);
      if (revMenu) sels.push(revMenu.sel);
      loadRevisions(sels);
    }

    // Status + token panel (used by re-run)
    var status = document.createElement('div'); status.id = 'lvci-status'; status.className = 'lvci-status';
    var tokp = document.createElement('div'); tokp.id = 'lvci-tok'; tokp.className = 'lvci-tok';

    // Rebuild banner (dashboard only) — hidden until the activity poll detects
    // the page-rebuild/publish run, then shown with a live link to it.
    var rebuild = null;
    if (REBUILD_ON) {
      rebuild = document.createElement('div');
      rebuild.id = 'lvci-rebuild';
      rebuild.className = 'lvci-rebuild';
      rebuild.setAttribute('role', 'status');
      rebuild.setAttribute('aria-live', 'polite');
      rebuild.innerHTML =
        '<span class="lvci-rb-spin" aria-hidden="true"></span>' +
        '<span class="lvci-rb-txt"><strong>Updating this dashboard\u2026 </strong>' +
        '<span class="lvci-rb-sub">A new version is being compiled by </span>' +
        '<a target="_blank" rel="noopener" href="https://github.com/' + repo + '/actions">the build workflow \u2197</a>' +
        '<span class="lvci-rb-sub">. This page refreshes automatically when it\u2019s done.</span></span>';
    }

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
    if (rebuild) document.body.insertBefore(rebuild, menu);   // directly under the bar

    renderBadge();   // initial paint (idle, or the persisted "Updating" flag)
  }

  // ── Badge state ───────────────────────────────────────────────────────────
  // Header status surfaces (all fed by the same poll + version check, so they
  // never fight over one element):
  //   - run chip   : a transient "N running" pill in the bar, only while CI runs
  //   - menu entry : the installed version + What's New / Update affordance
  //                  (amber "Update available" when behind; "Updating to vX..."
  //                  while a dispatched update is in flight)
  //   - menu dot   : one amber dot on the More button / hamburger whenever an
  //                  update is available or in progress
  var verState = { v: '', behind: false, to: '' };
  var runState = { active: 0, names: [] };
  var verEls = [];
  var clientsEls = [];
  // Page-rebuild banner: only the dashboard shows it (there "this page is being
  // regenerated" is literally true). buildWas remembers the prior poll so we can
  // auto-refresh exactly once when an in-flight rebuild finishes.
  var REBUILD_ON = (ctx === 'dashboard');
  var buildWas = false;

  // ── Version badge: read same-origin catalog.json for the installed version,
  //    and (on consumer repos) compare to the source repo to flag an update. ─
  function loadVersion() {
    fetch(base + '/catalog.json', { cache: 'no-cache' }).then(function (r) { return r.ok ? r.json() : null; })
      .then(function (cat) {
        if (!cat) return;
        var v = cat.version || '';
        verState.v = v;
        var upd = updGet();
        if (upd && cmpVer(v, upd.v) >= 0) updClear();                        // deployed caught up
        renderBadge();
        var src = (cat.source && cat.source.repo) || '';
        var isConsumer = src && repo && src.toLowerCase() !== repo.toLowerCase();
        if (!isConsumer) { revealClients(); return; }   // root repo: surface Clients even before a scan has published clients.json
        var ref = (cat.source && cat.source.ref) || 'main';
        fetch('https://raw.githubusercontent.com/' + src + '/' + ref + '/.github/labview-ci/catalog.json', { cache: 'no-cache' })
          .then(function (r) { return r.ok ? r.json() : null; })
          .then(function (s) {
            if (!s || !s.version) return;
            if (cmpVer(s.version, v) > 0) { verState.behind = true; verState.to = s.version; renderBadge(); }
          }).catch(function () {});
      }).catch(function () {});
  }
  // ── Clients registry (root/source repo only) ────────────────────────────
  // The Clients nav entry belongs to the ROOT repo that originates this tooling.
  // It is revealed when this repo is the source (no upstream — see loadVersion)
  // or once the published clients.json is read (then it also shows a count). It
  // stays hidden on consumer sites.
  function revealClients(count) {
    clientsEls.forEach(function (a) {
      a.style.display = '';
      if (count) { var c = a.querySelector('.lvci-ncount'); if (c) { c.textContent = count; c.hidden = false; } }
    });
  }
  function loadClients() {
    if (!clientsEls.length) return;
    fetch(base + '/clients.json', { cache: 'no-cache' }).then(function (r) { return r.ok ? r.json() : null; })
      .then(function (data) { if (data) revealClients((data.clients && data.clients.length) || data.count || 0); })
      .catch(function () {});
  }
  function cmpVer(a, b) {
    var pa = String(a).split('.').map(Number), pb = String(b).split('.').map(Number);
    for (var i = 0; i < 3; i++) { var d = (pa[i] || 0) - (pb[i] || 0); if (d) return d > 0 ? 1 : -1; }
    return 0;
  }

  // ── Page-rebuild banner (dashboard) ──────────────────────────────
  // While the workflow that regenerates THIS dashboard (dashboard-pages.yml) —
  // or the GitHub Pages publish that follows it — is in flight, the page on
  // screen is stale. Surface a banner naming + linking the run, and refresh once
  // it finishes so the freshly built version appears without a manual reload.
  function isDashGen(w) { return (w.path || '').toLowerCase().indexOf('dashboard-pages.yml') >= 0; }
  function isPagesPub(w) { return (w.name || '').toLowerCase() === 'pages build and deployment'; }
  function pickRebuild(runs) {
    var gen = null, pub = null;
    for (var i = 0; i < runs.length; i++) {
      if (isDashGen(runs[i])) { if (!gen) gen = runs[i]; }
      else if (isPagesPub(runs[i])) { if (!pub) pub = runs[i]; }
    }
    return gen || pub;                          // prefer the generator over the bare publish
  }
  function renderRebuild(run) {
    var card = document.getElementById('lvci-rebuild');
    if (!card) return;
    if (!run) { card.classList.remove('show'); return; }
    var a = card.querySelector('a');
    if (a) {
      a.href = run.html_url || ('https://github.com/' + repo + '/actions');
      a.textContent = (run.name || 'the build workflow') + ' \u2197';
    }
    card.classList.add('show');
  }
  var RELOAD_KEY = 'lvci_rebuild_reload';
  function anyModalOpen() {
    var ids = ['lvci-modal', 'cidash-run-modal', 'cidash-q-modal'];
    for (var i = 0; i < ids.length; i++) {
      var m = document.getElementById(ids[i]);
      if (m && m.style && m.style.display && m.style.display !== 'none') return true;
    }
    return false;
  }
  function autoRefresh() {
    // Don't reload out from under an open dialog; throttle so back-to-back
    // builds can't spin the page (at most one auto-reload per 12 s).
    if (anyModalOpen()) return;
    var last = 0;
    try { last = parseInt(sessionStorage.getItem(RELOAD_KEY) || '0', 10) || 0; } catch (e) {}
    if (Date.now() - last < 12000) return;
    try { sessionStorage.setItem(RELOAD_KEY, String(Date.now())); } catch (e) {}
    // brief settle for the Pages CDN edge to serve the new deploy
    setTimeout(function () { if (!anyModalOpen()) location.reload(); }, 4000);
  }

  // ── CI activity: poll the Actions API for in-flight runs. While any are
  //    queued/running, the badge above shows "N running" (with a spinner) in
  //    place of the version — so the dashboard visibly reflects work in
  //    progress (e.g. a deploy you're waiting on) instead of looking stale.
  //    Public repos work unauthenticated; private repos reuse the dashboard's
  //    dispatch token. Conditional (ETag) requests keep it within the
  //    unauthenticated rate budget — a 304 doesn't count and we poll only while
  //    the tab is visible. ──────────────────────────────────────────────────
  var ACT_MS = 60000, actEtag = '', actTimer = null;
  function ghHeaders() {
    var h = { 'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' };
    var t = tok(); if (t) h['Authorization'] = 'Bearer ' + t;
    if (actEtag) h['If-None-Match'] = actEtag;
    return h;
  }
  var ACTIVE = { in_progress: 1, queued: 1, waiting: 1, pending: 1, requested: 1 };
  function loadActivity() {
    if (!repo) return;
    fetch('https://api.github.com/repos/' + repo + '/actions/runs?per_page=20', { cache: 'no-cache', headers: ghHeaders() })
      .then(function (r) {
        if (r.status === 304) return null;                                  // unchanged (free — no rate cost)
        var et = r.headers.get('ETag'); if (et) actEtag = et;
        return r.ok ? r.json() : { workflow_runs: [] };                     // 403/404/etc → treat as idle
      })
      .then(function (d) {
        if (!d) return;                                                     // 304: keep current badge
        var act = (d.workflow_runs || []).filter(function (w) { return ACTIVE[w.status]; });
        runState.active = act.length;
        runState.names = [];
        act.slice(0, 6).forEach(function (w) {
          var n = w.name || w.display_title || 'workflow run';
          if (runState.names.indexOf(n) < 0) runState.names.push(n);
        });
        renderBadge();
        if (REBUILD_ON) {
          var rb = pickRebuild(act);
          renderRebuild(rb);
          if (buildWas && !rb) autoRefresh();   // a rebuild we were showing just finished
          buildWas = !!rb;
        }
      }).catch(function () { /* network blip: keep prior badge state */ });
  }
  function startActivity() {
    if (!repo) return;
    loadActivity();
    function arm() { if (!actTimer) actTimer = setInterval(function () { if (!document.hidden) loadActivity(); }, ACT_MS); }
    function disarm() { if (actTimer) { clearInterval(actTimer); actTimer = null; } }
    arm();
    document.addEventListener('visibilitychange', function () {
      if (document.hidden) disarm(); else { loadActivity(); arm(); }
    });
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
  // Paint all three surfaces from the current verState/runState (+ the optimistic
  // update flag). Safe to call repeatedly; each surface no-ops when not on the page.
  function renderBadge() {
    var upd = updGet();
    var updating = !!(upd && (!verState.v || cmpVer(verState.v, upd.v) < 0));
    var behind = !updating && verState.behind;
    var hasUpdate = updating || behind;

    // 1) Live CI activity chip — present only while runs are in flight.
    var chip = document.getElementById('lvci-runchip');
    var chipTxt = document.getElementById('lvci-runchip-txt');
    if (chip && chipTxt) {
      if (runState.active > 0) {
        chipTxt.textContent = (runState.active === 1 ? '1 running' : runState.active + ' running');
        chip.title = 'CI in progress: ' + (runState.names.join(', ') || 'workflow run')
          + '\nThe dashboard updates when it finishes.';
        chip.classList.add('show');
      } else {
        chip.classList.remove('show');
      }
    }

    // 2) Update-available dot on the menu trigger(s).
    ['lvci-more', 'lvci-burger'].forEach(function (id) {
      var el = document.getElementById(id);
      if (el) el.classList.toggle('has-update', hasUpdate);
    });

    // 3) Version / update entry inside the menu(s).
    verEls.forEach(function (a) {
      var ic = a.querySelector('.lvci-ic'),
          lbl = a.querySelector('.lvci-ddver-label'),
          tag = a.querySelector('.lvci-ddver-tag');
      a.classList.toggle('behind', hasUpdate);
      if (updating) {
        if (ic) ic.innerHTML = ICON.update;
        if (lbl) lbl.textContent = 'Updating to v' + upd.v + '\u2026';
        if (tag) tag.textContent = verState.v ? ('v' + verState.v + ' \u2192 v' + upd.v) : ('v' + upd.v);
        a.title = 'An update to v' + upd.v + ' is in progress (merge the update PR to finish).';
      } else if (behind) {
        if (ic) ic.innerHTML = ICON.update;
        if (lbl) lbl.textContent = 'Update available';
        if (tag) tag.textContent = 'v' + verState.v + ' \u2192 v' + verState.to;
        a.title = 'Update available: v' + verState.v + ' \u2192 v' + verState.to;
      } else {
        if (ic) ic.innerHTML = ICON.news;
        if (lbl) lbl.textContent = 'What\u2019s new';
        if (tag) tag.textContent = verState.v ? ('v' + verState.v) : '';
        a.title = verState.v ? ('LabVIEW CI v' + verState.v) : 'LabVIEW CI';
      }
    });
  }

  // The What's New dialog dispatches the update then calls window.lvciMarkUpdating
  // (directly when standalone, or via window.parent from the dashboard modal), so
  // the menu version entry flips to "Updating to vX..." immediately and persists.
  window.lvciMarkUpdating = function (v) {
    if (!v) return;
    try { localStorage.setItem(UPD_KEY, JSON.stringify({ v: v, ts: Date.now(), repo: repo })); } catch (e) {}
    renderBadge();
  };

  function init() { build(); if (cfg.isSource) revealClients(); loadVersion(); loadClients(); startActivity(); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
