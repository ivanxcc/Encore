#!/usr/bin/env bash
# Short, user-facing release notes for a commit: the bullet points of the pull request it merged
# (the "what changed" list), never "Merge pull request #… from …" or commit trailers.
# Usage: release-notes.sh <sha>   (needs GH_TOKEN and REPO)
set -euo pipefail
SHA="$1"

clean() {
  # Bullets only, without markdown emphasis, code ticks, links, or trailers; at most 10.
  grep -E '^\s*[-*] ' | sed -E 's/^\s*[-*] +//; s/\*\*//g; s/`//g; s/\[([^]]*)\]\([^)]*\)/\1/g' \
    | grep -viE '^(co-authored-by|claude-session|generated with)' | head -10 | sed 's/^/- /'
}

BODY=$(gh api "repos/${REPO}/commits/${SHA}/pulls" --jq '.[0].body // ""' 2>/dev/null || true)
TITLE=$(gh api "repos/${REPO}/commits/${SHA}/pulls" --jq '.[0].title // ""' 2>/dev/null || true)
# A "What's new" section, when the pull request has one, is the release notes; else all its bullets.
NEW=$(printf '%s\n' "$BODY" | awk '/^#+ / { on = (tolower($0) ~ /what.?s new/); next } on')
[ -n "$(printf '%s' "$NEW" | tr -d '[:space:]')" ] && BODY="$NEW"
NOTES=$(printf '%s\n' "$BODY" | clean || true)
if [ -z "$NOTES" ] && [ -n "$TITLE" ]; then NOTES="- ${TITLE}"; fi
if [ -z "$NOTES" ]; then
  # No pull request: the commit's own subject (or, for a merge, the line after the merge subject).
  NOTES=$(git log -1 --pretty=%B "$SHA" | grep -vE '^(Merge (pull request|branch)|Co-Authored-By|Claude-Session)' \
    | sed '/^\s*$/d' | head -1 | sed 's/^/- /')
fi
printf '%s\n' "$NOTES"
