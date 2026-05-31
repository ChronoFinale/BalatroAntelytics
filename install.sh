#!/usr/bin/env bash
# install.sh — copy the Antelytics mod source into the Balatro Mods directory.
#
# Usage:
#   bash install.sh
#
# COPY-ONLY: never uses symlinks. See README for why.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODS_DIR="$HOME/Library/Application Support/Balatro/Mods/Antelytics"

echo "Source : $REPO_DIR"
echo "Target : $MODS_DIR"
echo ""

# Copy runtime files, excluding dev cruft. --delete keeps the install in sync,
# but log/, session.log and config.lua are excluded so the --delete pass never
# removes captured runs, the runtime log, or the user's settings.
rsync -a --no-links --delete \
    --exclude='.git/' \
    --exclude='spec/' \
    --exclude='log/' \
    --exclude='session.log' \
    --exclude='config.lua' \
    --exclude='.kiro/' \
    --exclude='.DS_Store' \
    --exclude='install.sh' \
    --exclude='install.ps1' \
    "$REPO_DIR/" \
    "$MODS_DIR/"

# Seed config.lua only when the user doesn't already have one (preserves
# player_id / enabled across reinstalls).
if [ ! -f "$MODS_DIR/config.lua" ]; then
    cp "$REPO_DIR/config.lua" "$MODS_DIR/config.lua"
fi

echo "Done. Mod installed to: $MODS_DIR"
echo ""
echo "Restart Balatro to pick up the changes."
