#!/usr/bin/env bash
# Bump the foundryvtt package to the latest stable felddy/foundryvtt release.
#
# While the app is not yet in getumbrel/umbrel-apps, the new version is pushed
# to the add-foundryvtt branch of this fork (the open "Add Foundry VTT" PR).
# Once it is merged upstream, a new branch is created from upstream master and
# a draft "Update Foundry VTT" PR is opened, to be tested on Umbrel before it is
# marked ready for review.
#
# Env: GH_TOKEN (push to this fork, open PRs upstream), VERSION (optional
# felddy release such as 14.369.0), DRY_RUN=true to stop before pushing.
set -euo pipefail

UPSTREAM_REPO="getumbrel/umbrel-apps"
FORK_REPO="${GITHUB_REPOSITORY:?}"
FORK_OWNER="${FORK_REPO%%/*}"
IMAGE="felddy/foundryvtt"
APP_DIR="foundryvtt"

release="${VERSION:-$(gh release view --repo felddy/foundryvtt-docker --json tagName --jq .tagName)}"
image_tag="${release#v}"                        # 14.369.0
foundry_version="${image_tag%.*}"               # 14.369
if [[ ! "${image_tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Unexpected felddy release tag: ${release}" >&2
  exit 1
fi
echo "Latest felddy release: ${image_tag} (Foundry ${foundry_version})"

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "https://github.com/${UPSTREAM_REPO}.git"
git fetch --quiet upstream master
git fetch --quiet origin

if git cat-file -e "upstream/master:${APP_DIR}/umbrel-app.yml" 2>/dev/null; then
  mode="update-pr"
  base="upstream/master"
  branch="update-foundryvtt-${foundry_version}"
else
  mode="add-pr"
  base="origin/add-foundryvtt"
  branch="add-foundryvtt"
fi

current_tag="$(git show "${base}:${APP_DIR}/docker-compose.yml" | sed -n "s|.*image: ${IMAGE}:\([0-9.]*\)@sha256:.*|\1|p" | head -n 1)"
echo "Packaged in ${base}: ${current_tag}"
if [[ "${current_tag}" == "${image_tag}" ]]; then
  echo "Already up to date."
  exit 0
fi
if [[ "$(printf '%s\n%s\n' "${current_tag}" "${image_tag}" | sort -V | tail -n 1)" != "${image_tag}" ]]; then
  echo "${image_tag} is older than the packaged ${current_tag}; nothing to do."
  exit 0
fi
if [[ "${mode}" == "update-pr" ]] && git ls-remote --exit-code --heads origin "${branch}" >/dev/null 2>&1; then
  echo "Branch ${branch} already exists in ${FORK_REPO}; skipping."
  exit 0
fi

# Multi-arch index digest, and both Umbrel architectures must be present.
raw="$(docker buildx imagetools inspect --raw "${IMAGE}:${image_tag}")"
for platform in amd64 arm64; do
  if ! jq -e --arg a "${platform}" '[.manifests[]?.platform | select(.os == "linux" and .architecture == $a)] | length > 0' <<<"${raw}" >/dev/null; then
    echo "${IMAGE}:${image_tag} has no linux/${platform} image; not updating." >&2
    exit 1
  fi
done
digest="$(docker buildx imagetools inspect "${IMAGE}:${image_tag}" --format '{{json .Manifest}}' | jq -r .digest)"
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "Could not read the index digest" >&2; exit 1; }
echo "Index digest: ${digest}"

git checkout --quiet -B "${branch}" "${base}"
sed -i -E "s|(image: ${IMAGE}:)[0-9.]+@sha256:[0-9a-f]+|\1${image_tag}@${digest}|" "${APP_DIR}/docker-compose.yml"

python3 - "${APP_DIR}/umbrel-app.yml" "${foundry_version}" "${image_tag}" "${mode}" <<'EOF'
import re, sys
path, foundry_version, image_tag, mode = sys.argv[1:]
text = open(path).read()
text, n = re.subn(r'^version: ".*"$', f'version: "{foundry_version}"', text, count=1, flags=re.M)
assert n == 1, "version line not found"
if mode == "update-pr":
    notes = (
        "releaseNotes: >-\n"
        f"  This update brings Foundry Virtual Tabletop {foundry_version}.\n\n\n"
        "  Foundry is downloaded again from your foundryvtt.com account when the app starts. "
        "Keep FOUNDRY_USERNAME and FOUNDRY_PASSWORD set in the app settings, or enter them again if Foundry asks for them after updating. "
        "Your worlds, systems, modules and settings are kept.\n\n\n"
        f"  Full release notes can be found at https://foundryvtt.com/releases/{foundry_version}\n"
    )
    text, n = re.subn(r'^releaseNotes:.*?(?=^\S)', notes, text, count=1, flags=re.M | re.S)
    assert n == 1, "releaseNotes not found"
open(path, "w").write(text)
EOF

git --no-pager diff --stat
git --no-pager diff

npm ci --silent
npm run lint:apps -- "${APP_DIR}" --check-images
git diff --check

if [[ "${DRY_RUN:-false}" == "true" ]]; then
  echo "Dry run: not committing or pushing."
  exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git commit --quiet -am "Update Foundry VTT to ${foundry_version}"
git push --quiet origin "${branch}"

if [[ "${mode}" == "update-pr" ]]; then
  body="$(cat <<BODY
## Type

App update

## App

App ID: \`foundryvtt\`
Upstream project: https://foundryvtt.com (Docker image: https://github.com/felddy/foundryvtt-docker)
Version: ${current_tag%.*} → ${foundry_version}

## Summary

Updates \`${IMAGE}\` from \`${current_tag}\` to \`${image_tag}\` (multi-arch index digest, linux/amd64 and linux/arm64 checked), following the felddy release https://github.com/felddy/foundryvtt-docker/releases/tag/v${image_tag}.

Foundry release notes: https://foundryvtt.com/releases/${foundry_version}

## Verification

This PR was prepared automatically and is a draft until it has been tested through Umbrel.

- \`npm run lint:apps -- foundryvtt --check-images\`: no issues

Environment tested:
- [ ] Umbrel device
- [ ] Local umbrelOS test environment
- [x] Not runtime tested

Architecture tested:
- [ ] amd64
- [ ] arm64

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
  gh pr create --repo "${UPSTREAM_REPO}" --base master --head "${FORK_OWNER}:${branch}" --draft \
    --title "Update Foundry VTT to ${foundry_version}" --body "${body}"
else
  pr="$(gh pr list --repo "${UPSTREAM_REPO}" --head "${branch}" --author "${FORK_OWNER}" --state open --json number --jq '.[0].number // empty')"
  if [[ -n "${pr}" ]]; then
    gh pr comment "${pr}" --repo "${UPSTREAM_REPO}" --body "Updated the package to felddy/foundryvtt ${image_tag} (Foundry ${foundry_version}): https://github.com/felddy/foundryvtt-docker/releases/tag/v${image_tag}. Needs a new test through Umbrel."
  fi
fi
