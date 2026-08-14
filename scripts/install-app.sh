#!/usr/bin/env bash
# Builds Nuvi and installs the resulting bundle into /Applications.
# Usage: ./scripts/install-app.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Nuvi.app"
INSTALLED="/Applications/Nuvi.app"

"$ROOT/scripts/build-app.sh" "$CONFIG"

echo "==> Installing Nuvi to $INSTALLED"
rm -rf "$INSTALLED"
cp -R "$APP" "$INSTALLED"

echo "==> Installed: $INSTALLED"
echo "    Launch: open \"$INSTALLED\" (or: open -a Nuvi)"
