#!/usr/bin/env bash
# Mirror a published LabVIEW CI release to the configured GitLab distribution.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if [ -z "${GITLAB_MIRROR_TOKEN:-}" ]; then
  echo "ERROR: GITLAB_MIRROR_TOKEN is required to update the GitLab distribution." >&2
  exit 1
fi

pointer=".github/labview-ci/source.json"
mirror_config="$(python3 - "$pointer" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    entry = (json.load(stream).get("distributions") or {}).get("gitlab") or {}
repo = entry.get("repo") or ""
url = entry.get("url") or ""
if not repo or not url:
    raise SystemExit("source.json must define distributions.gitlab.repo and distributions.gitlab.url")
print(f"{url}|{repo}")
PY
)"
IFS='|' read -r configured_url configured_repo <<EOF
$mirror_config
EOF
mirror_url="${GITLAB_MIRROR_URL:-$configured_url}"
mirror_repo="${GITLAB_MIRROR_REPO:-$configured_repo}"
mirror_user="${GITLAB_MIRROR_USERNAME:-oauth2}"

release_ref="${GITLAB_MIRROR_REF:-}"
if [ -z "$release_ref" ]; then
  release_ref="v$(python3 -c 'import json; print(json.load(open(".github/labview-ci/catalog.json", encoding="utf-8"))["version"])')"
fi
if ! [[ "$release_ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: GITLAB_MIRROR_REF must be an immutable vMAJOR.MINOR.PATCH tag." >&2
  exit 1
fi
if ! git rev-parse --verify --quiet "refs/tags/$release_ref" >/dev/null; then
  echo "ERROR: release tag $release_ref does not exist locally." >&2
  exit 1
fi
release_sha="$(git rev-parse "${release_ref}^{commit}")"

umask 077
askpass="$(mktemp)"
trap 'rm -f "$askpass"' EXIT
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "$1" in' \
  '  *Username*) printf "%s\n" "${GITLAB_MIRROR_USERNAME:-oauth2}" ;;' \
  '  *) printf "%s\n" "$GITLAB_MIRROR_TOKEN" ;;' \
  'esac' > "$askpass"
chmod 700 "$askpass"

run_git() {
  GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 git "$@"
}

remote="${mirror_url%/}/${mirror_repo}.git"
immutable_refs=()
rolling_refs=()
while IFS= read -r tag; do
  [ -n "$tag" ] || continue
  if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    # Immutable release tags fail rather than silently replacing a divergent tag.
    immutable_refs+=("refs/tags/$tag:refs/tags/$tag")
  elif [[ "$tag" =~ ^v[0-9]+$ || "$tag" =~ ^v[0-9]+\.[0-9]+$ || "$tag" == stable || "$tag" == beta || "$tag" == dev ]]; then
    rolling_refs+=("refs/tags/$tag:refs/tags/$tag")
  fi
done < <(git for-each-ref --format='%(refname:strip=2)' refs/tags | sort)
if [ "${#immutable_refs[@]}" -gt 0 ]; then
  run_git push "$remote" "${immutable_refs[@]}"
fi
run_git push --force "$remote" "${release_sha}:refs/heads/main"
if [ "${#rolling_refs[@]}" -gt 0 ]; then
  run_git push --force "$remote" "${rolling_refs[@]}"
fi

echo "Mirrored $release_ref ($release_sha) to $mirror_url/$mirror_repo."
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## GitLab distribution synchronized"
    echo ""
    echo "- Release: \`$release_ref\`"
    echo "- Mirror: \`$mirror_url/$mirror_repo\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi