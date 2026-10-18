#!/usr/bin/env bash
# package-thunderstore.sh — build the Thunderstore package zip.
#
# Produces dist/Antelytics-thunderstore.zip. This is a DIFFERENT layout from
# package.sh's GitHub zip: Thunderstore wants the mod files FLAT at the zip
# root next to manifest.json, README.md and icon.png (mod managers create
# the install folder from the package name themselves). version_number in the
# manifest is derived from Antelytics.json with the `~alpha` suffix stripped,
# since Thunderstore requires plain semver.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' Antelytics.json \
  | sed -E 's/.*"version"[^"]*"([^"]+)".*/\1/')
TS_VERSION=${VERSION%%~*}
echo "Packaging Antelytics v${VERSION} for Thunderstore as ${TS_VERSION}"

STAGE="dist/thunderstore"
rm -rf "$STAGE" dist/Antelytics-thunderstore.zip
mkdir -p "$STAGE"

# Thunderstore metadata at the root. manifest.json is committed with a real
# version so it also works for a manual upload; the build re-stamps it.
sed -E "s/\"version_number\"[[:space:]]*:[[:space:]]*\"[^\"]+\"/\"version_number\": \"${TS_VERSION}\"/" \
  thunderstore/manifest.json > "$STAGE/manifest.json"
cp thunderstore/icon.png README.md CHANGELOG.md "$STAGE"/

# Runtime files, flat (same set package.sh ships).
cp main.lua Antelytics.json config.lua "$STAGE"/
cp -R lib "$STAGE"/lib
[ -f LICENSE ] && cp LICENSE "$STAGE"/ || true

( cd "$STAGE" && zip -rq ../Antelytics-thunderstore.zip . )

echo "Wrote dist/Antelytics-thunderstore.zip (${TS_VERSION})"
