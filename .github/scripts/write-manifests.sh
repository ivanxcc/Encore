#!/usr/bin/env bash
# Writes the files that point devices at a release:
#   encore-update.json    the Mac updater's manifest (version, build, zip URL, SHA-256)
#   altstore-source.json  AltStore / SideStore source for the iPhone and iPad app
#   install-mac.sh        the one-line Mac installer, for this channel
#   icon.png              the icon the AltStore source shows
# Usage: write-manifests.sh <dist> <tag> <version> <build> <channel: stable|beta> <notes file>
set -euo pipefail
DIST="$1"; TAG="$2"; VERSION="$3"; BUILD="$4"; CHANNEL="$5"; NOTES_FILE="$6"
REPO="${GITHUB_REPOSITORY:?}"
BASE="https://github.com/${REPO}/releases/download/${TAG}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

ZIP="Encore-macOS-${VERSION}.zip"
IPA="Encore-iOS-${VERSION}.ipa"
SHA=$(sha256sum "${DIST}/${ZIP}" | cut -d' ' -f1)
NOTES=$(head -c 4000 "$NOTES_FILE")

jq -n --arg version "$VERSION" --argjson build "$BUILD" --arg url "${BASE}/${ZIP}" --arg sha "$SHA" \
  --arg notes "$NOTES" --arg page "https://github.com/${REPO}/releases/tag/${TAG}" --arg channel "$CHANNEL" \
  '{version: $version, build: $build, url: $url, sha256: $sha, notes: $notes, releasePage: $page,
    minimumSystemVersion: "15.0", channel: $channel}' > "${DIST}/encore-update.json"

cp "${ROOT}/Encore/App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" "${DIST}/icon.png"
SIZE=$(stat -c %s "${DIST}/${IPA}")
NAME="Encore"; SOURCE_ID="com.ivanxcc.encore.source"
if [ "$CHANNEL" = "beta" ]; then NAME="Encore Beta"; SOURCE_ID="com.ivanxcc.encore.source.beta"; fi
jq -n \
  --arg name "$NAME" --arg version "$VERSION" --arg build "$BUILD" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg url "${BASE}/${IPA}" --argjson size "$SIZE" --arg icon "${BASE}/icon.png" \
  --arg site "https://github.com/${REPO}" --arg id "$SOURCE_ID" \
  '{
    name: $name, identifier: $id, website: $site,
    subtitle: "An Apple TV-style home for your Stremio add-ons.", iconURL: $icon, tintColor: "4C5BD4",
    apps: [{
      name: "Encore", bundleIdentifier: "com.ivanxcc.encore", developerName: "ivanxcc",
      subtitle: "Stream beautifully on iPhone and iPad.",
      localizedDescription: "Encore is a native client for the Stremio add-on ecosystem, designed after the Apple TV app, with households, profiles, and libmpv playback.",
      iconURL: $icon, tintColor: "4C5BD4", category: "entertainment",
      versions: [{ version: $version, buildVersion: $build, date: $date, downloadURL: $url, size: $size, minOSVersion: "18.0" }],
      appPermissions: { entitlements: [], privacy: {} }
    }],
    news: []
  }' > "${DIST}/altstore-source.json"

sed -e "s#__REPOSITORY__#${REPO}#" -e "s#__CHANNEL__#${CHANNEL}#" "${ROOT}/Encore/Scripts/install-mac.sh" > "${DIST}/install-mac.sh"
chmod +x "${DIST}/install-mac.sh"
cat "${DIST}/encore-update.json"
