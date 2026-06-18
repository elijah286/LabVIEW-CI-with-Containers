#!/usr/bin/env python3
"""discover-clients.py - find repositories that installed this LabVIEW CI stack.

LCWC-internal automation (run by .github/workflows/discover-clients.yml). It is
NOT distributed to client repos; the install manifest never copies it.

WHAT IT DOES
  Instead of asking every client to "phone home" (which would need a write
  endpoint + a shared secret in the public bootstrap), the ROOT repo discovers
  its clients by querying GitHub's own code-search index for the marker every
  install necessarily carries: this repo's slug, appearing in a consumer's
    * .github/labview-ci/catalog.json   (its `source.repo`), and/or
    * .github/workflows/*               (a `uses: <slug>/...` reference).
  Each candidate is then verified (public, not a fork, and - when a catalog is
  present - its source.repo actually points back here) and enriched with a
  little metadata, and the result is written to clients.json for the dashboard's
  Clients page to render.

PRIVACY
  Code search only indexes PUBLIC repositories, and candidates are additionally
  checked to be non-private. Private clients are therefore never discovered or
  listed - a deliberate property, since the dashboard that renders this list is
  itself public.

AUTH
  GitHub's code-search REST API requires authentication and is rate-limited. The
  ephemeral Actions GITHUB_TOKEN can be unreliable for cross-repo code search, so
  the workflow prefers a DISCOVERY_TOKEN secret (a classic/fine-grained PAT with
  public-repo read) when available and falls back to GITHUB_TOKEN. If every
  search query fails to execute (bad/again missing token), the script exits
  non-zero so the workflow does NOT publish an empty list over a good one.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"
SOURCE_REPO = (os.environ.get("SOURCE_REPO") or "").strip()
TOKEN = (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or "").strip()
OUT = os.environ.get("CLIENTS_OUT", "ci-out/clients/clients.json")
# Repository topic that clients carry (set on the client repo at install time).
# Repository search indexes topics as structured metadata, so it is far more
# complete and prompt than the code-search text index - it surfaces public
# clients that code search silently omits. Blank disables the topic pass.
CLIENT_TOPIC = (os.environ.get("CLIENT_TOPIC", "labview-ci") or "").strip()

# Cap pagination so a runaway query can't spin forever (100 results/page).
MAX_PAGES = 10


def _get(url, auth=True):
    """GET a URL, returning parsed JSON (or None). Retries on rate limit / 5xx.

    Returns None for 404/422 (treated as "not found / empty") and after the
    retry budget is exhausted. Raising is avoided so one bad repo can't abort
    the whole scan.
    """
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "lvci-discover-clients",
    }
    if auth and TOKEN:
        headers["Authorization"] = "Bearer " + TOKEN
    for _ in range(5):
        try:
            with urllib.request.urlopen(
                urllib.request.Request(url, headers=headers), timeout=30
            ) as resp:
                body = resp.read().decode("utf-8")
                return json.loads(body) if body else None
        except urllib.error.HTTPError as e:
            if e.code in (403, 429):  # primary or secondary rate limit
                retry = e.headers.get("Retry-After")
                if retry and retry.isdigit():
                    wait = int(retry)
                else:
                    reset = e.headers.get("X-RateLimit-Reset")
                    wait = (int(reset) - int(time.time())) if (reset and reset.isdigit()) else 5
                time.sleep(max(1, min(wait, 90)))
                continue
            if e.code in (404, 422):
                return None
            if 500 <= e.code < 600:
                time.sleep(3)
                continue
            return None
        except (urllib.error.URLError, TimeoutError, ValueError):
            time.sleep(3)
            continue
    return None


def search_repos(query):
    """Return (set_of_repo_full_names, ran_ok) for a code-search query."""
    repos = set()
    ran_ok = False
    page = 1
    while page <= MAX_PAGES:
        qs = urllib.parse.urlencode({"q": query, "per_page": 100, "page": page})
        data = _get(API + "/search/code?" + qs)
        if data is None:
            break
        ran_ok = True
        items = data.get("items") or []
        for it in items:
            full = (it.get("repository") or {}).get("full_name")
            if full:
                repos.add(full)
        if len(items) < 100:
            break
        page += 1
        time.sleep(2)  # code-search secondary rate limits are strict
    return repos, ran_ok


def raw_catalog(repo):
    """Fetch a candidate's catalog.json from its default branch (unauthenticated)."""
    url = "https://raw.githubusercontent.com/%s/HEAD/.github/labview-ci/catalog.json" % repo
    return _get(url, auth=False)


def search_repos_by_topic(topic):
    """Return (set_of_repo_full_names, ran_ok) for public repos carrying a topic.

    Uses the repository-search API, whose topic index is structured metadata and
    far more complete/prompt than the code-search text index - so it surfaces
    clients that code search silently omits. Each hit is still verified by the
    caller (its catalog must point back to this source).
    """
    repos = set()
    ran_ok = False
    page = 1
    while page <= MAX_PAGES:
        qs = urllib.parse.urlencode({"q": "topic:%s" % topic, "per_page": 100, "page": page})
        data = _get(API + "/search/repositories?" + qs)
        if data is None:
            break
        ran_ok = True
        items = data.get("items") or []
        for it in items:
            full = it.get("full_name")
            if full:
                repos.add(full)
        if len(items) < 100:
            break
        page += 1
        time.sleep(2)
    return repos, ran_ok


def main():
    if not SOURCE_REPO:
        print("SOURCE_REPO is not set", file=sys.stderr)
        return 2

    slug = SOURCE_REPO
    queries = [
        ("catalog", '"%s" in:file filename:catalog.json' % slug),
        ("workflow", '"%s" in:file path:.github/workflows' % slug),
    ]

    candidates = {}  # repo -> set(via)
    any_ok = False
    for via, q in queries:
        repos, ran_ok = search_repos(q)
        any_ok = any_ok or ran_ok
        for repo in repos:
            if repo.lower() == slug.lower():
                continue  # never list the root itself
            candidates.setdefault(repo, set()).add(via)
        time.sleep(2)

    # Reliable pass: repos that carry the client topic. Topic search is complete
    # where code search is not, so this is the primary signal - but every hit is
    # still verified below (its catalog source must point back to this repo),
    # which filters unrelated repos that happen to share the generic topic.
    if CLIENT_TOPIC:
        repos, ran_ok = search_repos_by_topic(CLIENT_TOPIC)
        any_ok = any_ok or ran_ok
        for repo in repos:
            if repo.lower() == slug.lower():
                continue
            candidates.setdefault(repo, set()).add("topic")
        time.sleep(2)

    if not any_ok:
        print("no search query executed (token/permission?)", file=sys.stderr)
        return 1

    clients = []
    for repo in sorted(candidates):
        meta = _get(API + "/repos/" + repo) or {}
        if meta.get("private") or meta.get("fork"):
            continue
        cat = raw_catalog(repo)
        confirmed = bool(
            cat and ((cat.get("source") or {}).get("repo", "").lower() == slug.lower())
        )
        via = sorted(candidates[repo])
        # Keep a candidate only on a positive signal: a catalog that points back
        # here, or a workflow that references this stack. Drops coincidental
        # string matches in unrelated catalog.json files.
        if not confirmed and "workflow" not in via:
            continue
        owner, _, name = repo.partition("/")
        clients.append({
            "repo": repo,
            "owner": owner,
            "name": name,
            "url": meta.get("html_url") or ("https://github.com/" + repo),
            "dashboard": "https://%s.github.io/%s/" % (owner, name),
            "version": (cat or {}).get("version", "") if confirmed else "",
            "updated": meta.get("pushed_at", ""),
            "via": via,
            "confirmed": confirmed,
        })
        time.sleep(0.2)

    payload = {
        "source": slug,
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "count": len(clients),
        "clients": clients,
    }
    out_dir = os.path.dirname(OUT)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("Discovered %d client repo(s); wrote %s" % (len(clients), OUT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
