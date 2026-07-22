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
_TOP_ORDER = ["schemaVersion", "version", "stableVersion"]


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
    ap.add_argument("--version", required=True, help="published version to (un)promote, e.g. 4.9.7")
    ap.add_argument("--unpromote", action="store_true", help="roll the stable channel back off this version")
    ap.add_argument("--catalog", default=CATALOG)
    ap.add_argument("--date", default=None, help="override the release date (YYYY-MM-DD); defaults to today UTC")
    args = ap.parse_args(argv)

    target = args.version.strip().lstrip("v")
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
        entry.pop("stable", None)
        # Point stable at the newest OTHER still-stable release, else drop the key.
        prev = next((r for r in rels
                     if r.get("stable") and str(r.get("version")) != target), None)
        if prev is not None:
            cat["stableVersion"] = str(prev["version"])
        else:
            cat.pop("stableVersion", None)
        note = ("Rolled the stable release channel back off v%s. "
                "Default installs and upgrades now target %s."
                % (target, ("v" + cat["stableVersion"]) if cat.get("stableVersion")
                   else "the latest release until a new one is promoted"))
    else:
        entry["stable"] = True
        cat["stableVersion"] = target
        note = ("Marked v%s as the stable release. Default installs and upgrades "
                "now target it; pre-release (beta) builds stay available behind an "
                "opt-in toggle." % target)

    # Every catalog change bumps the version (hard rule). The promotion commit is
    # itself a normal beta release recording what was blessed.
    cat["version"] = new_version
    rels.insert(0, {"version": new_version, "date": date, "notes": note})

    cat = _reorder_top(cat)

    # Invariant: top version == releases[0].version.
    assert cat["version"] == _releases(cat)[0]["version"], "version/releases[0] mismatch"

    with open(args.catalog, "w", encoding="utf-8") as fh:
        json.dump(cat, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

    action = "unpromoted" if args.unpromote else "promoted"
    stable = cat.get("stableVersion") or "(none)"
    print("%s v%s; catalog version %s -> %s; stableVersion=%s"
          % (action, target, top, new_version, stable))
    return 0


if __name__ == "__main__":
    sys.exit(main())
