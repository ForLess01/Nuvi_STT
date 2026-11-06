#!/usr/bin/env bash
# Usage: ./scripts/build-app.sh [debug|release]
# Build and sign once, verify, then replace the local build. Never installs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
[ "$#" -le 1 ] && [[ "$CONFIG" = debug || "$CONFIG" = release ]] || { echo 'Usage: build-app.sh [debug|release]' >&2; exit 2; }
# Resolve a unique certificate fingerprint; no ad-hoc or entitlement-free fallback.
IDENTITIES="$(security find-identity -v -p codesigning)"
REQUESTED="${NUVI_SIGN_IDENTITY:-}"
SIGN_ID=""
while IFS= read -r line; do
    if [[ "$line" =~ ([A-Fa-f0-9]{40})\ \"((Apple\ Development|Developer\ ID\ Application):[^\"]+)\" ]]; then
        fingerprint="${BASH_REMATCH[1]}"; name="${BASH_REMATCH[2]}"
        if [ -z "$REQUESTED" ] || [ "$REQUESTED" = "$fingerprint" ] || [ "$REQUESTED" = "$name" ]; then
            [ -z "$SIGN_ID" ] || { echo 'Multiple signing identities match; set NUVI_SIGN_IDENTITY to the exact SHA-1 fingerprint.' >&2; exit 1; }
            SIGN_ID="$fingerprint"
        fi
    fi
done <<< "$IDENTITIES"
[ -n "$SIGN_ID" ] || { echo 'A stable Apple signing identity is required. Set NUVI_SIGN_IDENTITY; ad-hoc signing is not supported.' >&2; exit 1; }
echo "==> Building Nuvi ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN_PATH="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"
mkdir -p "$ROOT/build"
STAGE="$(mktemp -d "$ROOT/build/.Nuvi-build.XXXXXX")"
LOCK="$ROOT/build/.Nuvi-build.lock"
APP="$STAGE/Nuvi.app"; FINAL="$ROOT/build/Nuvi.app"; OLD="$STAGE/previous-Nuvi.app"
restore() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        if [ -d "$OLD" ] && [ ! -e "$FINAL" ]; then mv "$OLD" "$FINAL" || echo "Restore manually from $OLD" >&2; fi
        echo "Build failed; staging retained at $STAGE" >&2
    else rm -rf "$STAGE"; fi
    [ "$LOCKED" = 0 ] || rmdir "$LOCK"
}
LOCKED=0
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$LOCK" || { echo "Another packaging process may be active: $LOCK" >&2; exit 1; }
LOCKED=1
if [ -e "$FINAL" ] && { [ ! -d "$FINAL" ] || [ -L "$FINAL" ]; }; then
    echo "Existing build output is not a real app directory: $FINAL" >&2; exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/Nuvi" "$APP/Contents/MacOS/Nuvi"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/Nuvi.icns" ]; then cp "$ROOT/Resources/Nuvi.icns" "$APP/Contents/Resources/Nuvi.icns"; fi
for bundle in "$BIN_PATH"/*.bundle; do [ ! -e "$bundle" ] || ditto --rsrc --extattr --acl "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"; done
cp "$ROOT/Sources/Nuvi/Infrastructure/Settings/ModelsCatalog.json" "$APP/Contents/Resources/ModelsCatalog.json"
echo "==> Signing with identity: $SIGN_ID"
codesign --force --options runtime --deep --sign "$SIGN_ID" --entitlements "$ROOT/Resources/Nuvi.entitlements" "$APP"
"$ROOT/scripts/verify-app.sh" "$APP" --identity "$SIGN_ID" \
    --version "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")" \
    --build "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")"
[ ! -e "$FINAL" ] || mv "$FINAL" "$OLD"
mv "$APP" "$FINAL"
echo "==> Done. Built: $FINAL"
echo "Launch with: open \"$FINAL\" (not the inner binary)."
echo "Install with: ./scripts/install-app.sh $CONFIG"
