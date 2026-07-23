#!/usr/bin/env python3
"""Promote (or un-promote) a published LabVIEW CI version to the STABLE channel.

The catalog carries two release channels:
  * ``version``        - the BETA tip: the newest published release of anything.
  * ``stableVersion``  - the newest release the owner has explicitly BLESSED as
                          production-ready. Absent until the first promotion.

Promotion never builds anything: it marks an already-published, immutable
``v<version>`` release as the stable one. This script performs the catalog edit
(set ``stableVersion``, flag the chosen release ``"stable": true``) and, because
every catalog change bumps the version, prepends a small release note recording
the promotion. release.yml then force-moves the rolling ``stable`` tag to the
blessed commit.

Run from the repo root:
    python3 .github/labview/promote-release.py --version 4.9.7
    python3 .github/labview/promote-release.py --version 4.9.7 --unpromote

Exit status is non-zero (and nothing is written) if the target version is not a
published release, so a workflow can gate on it.
"""
import argparse
import datetime
import json
import sys

CATALOG = ".github/labview-ci/catalog.json"

# Top-level key order we want to preserve/emit (any extra keys are appended in
# their existing order). stableVersion sits right after version for readability.
_TOP_ORDER = ["schemaVersion", "version", "stableVersion", "betaVersion"]


def _bump_patch(ver):
    parts = ver.split(".")
    if len(parts) != 3 or not all(p.isdigit() for p in parts):
        raise SystemExit("::error::catalog version %r is not MAJOR.MINOR.PATCH" % ver)
    parts[2] = str(int(parts[2]) + 1)
    return ".".join(parts)


def _releases(cat):
    hist = cat.get("history") or {}
    rels = hist.get("releases")
    if not isinstance(rels, list):
        raise SystemExit("::error::catalog history.releases is missing or not a list")
    return rels


def _reorder_top(cat):
    """Return a new dict with the top keys in _TOP_ORDER first, rest appended."""
    out = {}
    for k in _TOP_ORDER:
        if k in cat:
            out[k] = cat[k]
    for k, v in cat.items():
        if k not in out:
            out[k] = v
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True, help="published version to (un)mark, e.g. 4.9.7")
    ap.add_argument("--tier", choices=("beta", "stable"), default="stable",
                    help="which channel to (un)mark: stable (release) or beta (release candidate)")
    ap.add_argument("--unpromote", action="store_true", help="roll the chosen channel back off this version")
    ap.add_argument("--catalog", default=CATALOG)
    ap.add_argument("--date", default=None, help="override the release date (YYYY-MM-DD); defaults to today UTC")
    args = ap.parse_args(argv)

    target = args.version.strip().lstrip("v")
    tier = args.tier                 # "stable" | "beta"
    ptr = tier + "Version"           # "stableVersion" | "betaVersion"
    label = "release" if tier == "stable" else "beta"
    with open(args.catalog, encoding="utf-8") as fh:
        cat = json.load(fh)

    rels = _releases(cat)
    entry = next((r for r in rels if str(r.get("version")) == target), None)
    if entry is None:
        raise SystemExit(
            "::error::%s is not a published release (no history.releases entry). "
            "Promote only an already-released version." % target
        )

    top = str(cat.get("version", ""))
    new_version = _bump_patch(top)
    date = args.date or datetime.datetime.utcnow().strftime("%Y-%m-%d")

    if args.unpromote:
        entry.pop(tier, None)
        # Point the channel at the newest OTHER release still in this tier, else drop.
        prev = next((r for r in rels
                     if r.get(tier) and str(r.get("version")) != target), None)
        if prev is not None:
            cat[ptr] = str(prev["version"])
        else:
            cat.pop(ptr, None)
        note = ("Rolled the %s channel back off v%s. The %s channel now targets %s."
                % (label, target, label,
                   ("v" + cat[ptr]) if cat.get(ptr) else "the latest build until one is promoted"))
    else:
        entry[tier] = True
        cat[ptr] = target
        if tier == "stable":
            note = ("Marked v%s as the stable release. Default installs and upgrades "
                    "target it; beta and dev builds stay available behind the channel "
                    "picker." % target)
        else:
            note = ("Marked v%s as a beta (release candidate). Users on the release+beta "
                    "channel receive it; the default release channel is unaffected." % target)

    # Every catalog change bumps the version (hard rule). The promotion commit is
    # itself a normal dev build recording what was marked.
    cat["version"] = new_version
    rels.insert(0, {"version": new_version, "date": date, "notes": note})

    cat = _reorder_top(cat)

    # Invariant: top version == releases[0].version.
    assert cat["version"] == _releases(cat)[0]["version"], "version/releases[0] mismatch"

    with open(args.catalog, "w", encoding="utf-8") as fh:
        json.dump(cat, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

    action = "un-marked" if args.unpromote else "marked"
    print("%s v%s as %s; catalog version %s -> %s; stableVersion=%s betaVersion=%s"
          % (action, target, label, top, new_version,
             cat.get("stableVersion") or "(none)", cat.get("betaVersion") or "(none)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
