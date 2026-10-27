#!/usr/bin/env bash
# Ship a tested beta to everyone: republish its exact files as the latest (stable) release, point the
# stable manifests at them, and move `main` to the commit the beta was built from.
# Usage: promote.sh [beta tag]   (default: the newest beta pre-release)
set -euo pipefail
REPO="${GITHUB_REPOSITORY:?}"
BETA="${1:-}"
if [ -z "$BETA" ]; then
  BETA=$(gh release list -R "$REPO" --limit 100 --json tagName,isPrerelease,createdAt \
    --jq '[.[] | select(.isPrerelease and (.tagName | test("-beta\\.")))] | sort_by(.createdAt) | last | .tagName // ""')
fi
[ -n "$BETA" ] || { echo "::error::There is no beta release to promote."; exit 1; }

WORK="$(mktemp -d)"
gh release download "$BETA" -R "$REPO" -D "$WORK/beta" -p 'Encore-*' -p 'encore-update.json'
VERSION=$(jq -r .version "$WORK/beta/encore-update.json")
BUILD=$(jq -r .build "$WORK/beta/encore-update.json")
TAG="v${VERSION}-build.${BUILD}"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "::error::${BETA} was already promoted as ${TAG}."; exit 1
fi
git fetch --tags --force origin >/dev/null 2>&1 || true
SHA=$(git rev-list -n 1 "$BETA")

# Same binaries, stable manifests.
mkdir -p "$WORK/dist"
cp "$WORK"/beta/Encore-* "$WORK/dist/"
if [ -n "${NOTES:-}" ]; then
  # Notes given when promoting (a summary of every beta since the last stable): one change per line.
  printf '%s\n' "$NOTES" | sed '/^\s*$/d; /^- /!s/^/- /' > "$WORK/notes.txt"
else
  gh release view "$BETA" -R "$REPO" --json body --jq .body | sed -n '/^### Changes/,$p' | sed '1d' > "$WORK/notes.txt"
fi
[ -s "$WORK/notes.txt" ] || git log -1 --pretty=%B "$SHA" > "$WORK/notes.txt"
"$(dirname "$0")/write-manifests.sh" "$WORK/dist" "$TAG" "$VERSION" "$BUILD" stable "$WORK/notes.txt"

{ echo "Tested as beta [${BETA}](https://github.com/${REPO}/releases/tag/${BETA})."; echo; cat "$WORK/notes.txt"; } > "$WORK/body.md"
gh release create "$TAG" "$WORK"/dist/* -R "$REPO" --target "$SHA" \
  --title "Encore ${VERSION} (build ${BUILD})" --notes-file "$WORK/body.md" --latest
echo "::notice::Promoted ${BETA} to stable as ${TAG}."

# main follows what shipped. A push made with the workflow token starts no other workflows.
if git push origin "${SHA}:refs/heads/main"; then
  echo "::notice::main is now at ${SHA}."
else
  echo "::warning::Released ${TAG}, but main could not be fast-forwarded to ${SHA} (it has commits the beta does not). Merge beta into main."
fi

OLD_BODY=$(gh release view "$BETA" -R "$REPO" --json body --jq .body)
gh release edit "$BETA" -R "$REPO" --notes "$(printf '**Promoted to stable as [%s](https://github.com/%s/releases/tag/%s).**\n\n%s' "$TAG" "$REPO" "$TAG" "$OLD_BODY")" >/dev/null
