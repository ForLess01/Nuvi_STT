#!/usr/bin/env bash
# Usage: ./scripts/install-app.sh [debug|release]
# Build a verified bundle, then install with verified rollback protection.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ "$#" -le 1 ] || { echo 'Usage: install-app.sh [debug|release]' >&2; exit 2; }
"$ROOT/scripts/build-app.sh" "${1:-release}"
exec "$ROOT/scripts/install-verified-app.sh" "$ROOT/build/Nuvi.app"
