#!/bin/bash
# Install or update Encore for Mac without the "unidentified developer" detour.
#
#   curl -fsSL https://github.com/ivanxcc/Encore/releases/latest/download/install-mac.sh | bash
#   curl -fsSL https://github.com/ivanxcc/Encore/releases/latest/download/install-mac.sh | ENCORE_CHANNEL=beta bash
#
# Files fetched with curl are not quarantined by macOS, so Gatekeeper does not stop the app on first
# launch. The download is verified against the SHA-256 published with the release before anything is
# installed, exactly like the in-app updater.
set -euo pipefail

REPO="${ENCORE_REPO:-__REPOSITORY__}"
DEST="${ENCORE_DEST:-/Applications}"
# stable: the latest release. beta: the newest build waiting for approval (ENCORE_CHANNEL=beta).
CHANNEL="${ENCORE_CHANNEL:-__CHANNEL__}"
case "$CHANNEL" in
  beta) manifest_url="https://github.com/${REPO}/releases/download/beta-channel/encore-update.json" ;;
  *)    manifest_url="https://github.com/${REPO}/releases/latest/download/encore-update.json" ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Encore: checking the latest ${CHANNEL} release…"
curl -fsSL "$manifest_url" -o "$work/update.json"
# plutil reads JSON on every supported macOS (python3 would prompt to install developer tools).
read_json() { /usr/bin/plutil -extract "$1" raw -o - "$work/update.json"; }
version="$(read_json version)"; build="$(read_json build)"; url="$(read_json url)"; sha="$(read_json sha256)"

echo "Encore: downloading ${version} (build ${build})…"
curl -fL --progress-bar "$url" -o "$work/Encore.zip"
echo "${sha}  $work/Encore.zip" | shasum -a 256 -c - >/dev/null || { echo "Encore: checksum mismatch, nothing installed." >&2; exit 1; }

/usr/bin/ditto -x -k "$work/Encore.zip" "$work/unpacked"
test -d "$work/unpacked/Encore.app" || { echo "Encore: the download did not contain Encore.app." >&2; exit 1; }

if pgrep -x Encore >/dev/null; then
  echo "Encore: quitting the running app…"
  osascript -e 'quit app "Encore"' >/dev/null 2>&1 || true
  sleep 2
fi

target="$DEST/Encore.app"
if [ -w "$DEST" ]; then
  rm -rf "$target" && /usr/bin/ditto "$work/unpacked/Encore.app" "$target"
else
  echo "Encore: $DEST needs your password to install."
  sudo rm -rf "$target" && sudo /usr/bin/ditto "$work/unpacked/Encore.app" "$target"
fi
/usr/bin/xattr -cr "$target" 2>/dev/null || true

echo "Encore ${version} is installed in ${DEST}. Opening…"
open "$target"
