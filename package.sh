#!/usr/bin/env bash
# package.sh — build the distributable mod zip.
#
# Produces dist/Antelytics.zip containing a single top-level `Antelytics/`
# folder with only the runtime files — so a user just extracts it into their
# Balatro Mods directory. Dev cruft (spec, install scripts, git, logs) is
# excluded.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' Antelytics.json \
  | sed -E 's/.*"version"[^"]*"([^"]+)".*/\1/')
echo "Packaging Antelytics v${VERSION}"

STAGE="dist/Antelytics"
rm -rf dist
mkdir -p "$STAGE"

# Runtime files only.
cp main.lua Antelytics.json config.lua README.md "$STAGE"/
cp -R lib "$STAGE"/lib
[ -f LICENSE ] && cp LICENSE "$STAGE"/ || true

# Zip with a top-level Antelytics/ folder (so extraction yields
# Mods/Antelytics/main.lua).
( cd dist && zip -rq Antelytics.zip Antelytics )

echo "Wrote dist/Antelytics.zip (v${VERSION})"
