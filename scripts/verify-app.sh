#!/usr/bin/env bash
# Verify a signed Nuvi bundle; optionally require signer, version, build or exact copy.
# Usage: verify-app.sh APP [--identity SHA1] [--version VERSION] [--build BUILD] [--compare APP]
set -euo pipefail
fail() { echo "Verification failed: $*" >&2; exit 1; }
[ "$#" -ge 1 ] || fail "missing app path"
APP="$1"; shift
IDENTITY=""; VERSION=""; BUILD=""; COMPARE=""
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || fail "missing option value"
    case "$1" in
        --identity) IDENTITY="$2";; --version) VERSION="$2";; --build) BUILD="$2";; --compare) COMPARE="$2";;
        *) fail "unknown option: $1";;
    esac
    shift 2
done
[ -d "$APP" ] && [ ! -L "$APP" ] || fail "app must be a real directory"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nuvi-verify.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
[ "$(plist CFBundleIdentifier)" = com.nuvi.app ] || fail "bundle identifier"
[ "$(plist CFBundleExecutable)" = Nuvi ] || fail "bundle executable"
ACTUAL_VERSION="$(plist CFBundleShortVersionString)"; ACTUAL_BUILD="$(plist CFBundleVersion)"
[[ "$ACTUAL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must have three numeric components"
[[ "$ACTUAL_BUILD" =~ ^[0-9]+$ ]] || fail "build must be numeric"
[ -z "$VERSION" ] || [ "$VERSION" = "$ACTUAL_VERSION" ] || fail "version mismatch"
[ -z "$BUILD" ] || [ "$BUILD" = "$ACTUAL_BUILD" ] || fail "build mismatch"
[ -x "$APP/Contents/MacOS/Nuvi" ] || fail "missing executable"
[[ " $(lipo -archs "$APP/Contents/MacOS/Nuvi") " = *" arm64 "* ]] || fail "missing arm64 architecture"
[ -d "$APP/Contents/Resources/Nuvi_Nuvi.bundle" ] || fail "missing SwiftPM resources"
[ -f "$APP/Contents/Resources/ModelsCatalog.json" ] || fail "missing model catalog"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --verbose=4 "$APP" 2> "$TMP/signature"
grep -qx 'Identifier=com.nuvi.app' "$TMP/signature" || fail "signed identifier"
grep -Eq '^Authority=(Apple Development|Developer ID Application): ' "$TMP/signature" || fail "stable Apple signing identity required"
grep -Eq '^TeamIdentifier=[A-Z0-9]+$' "$TMP/signature" || fail "missing team identity"
grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' "$TMP/signature" || fail "hardened runtime missing"
codesign -d --extract-certificates="$TMP/cert" "$APP"
SIGNER="$(openssl x509 -inform DER -in "$TMP/cert0" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr '[:lower:]' '[:upper:]')"
[[ "$SIGNER" =~ ^[A-F0-9]{40}$ ]] || fail "invalid signing certificate fingerprint"
[ -z "$IDENTITY" ] || [ "$SIGNER" = "$(printf '%s' "$IDENTITY" | tr '[:lower:]' '[:upper:]')" ] || fail "signer mismatch"
codesign -d --entitlements :- "$APP" > "$TMP/entitlements.plist"
plutil -convert xml1 -o "$TMP/entitlements.xml" "$TMP/entitlements.plist"
[ "$(grep -c '<key>' "$TMP/entitlements.xml")" = 1 ] || fail "unexpected entitlements"
grep -q '<key>com.apple.security.device.audio-input</key>' "$TMP/entitlements.xml" || fail "missing audio input entitlement"
grep -q '<true/>' "$TMP/entitlements.xml" || fail "audio input entitlement disabled"
# Compare every entry including modes, symlink targets, ACLs and stable extended attributes.
# Content hashing does not follow symlinks. NUL-delimited traversal permits spaces.
manifest() {
    local base="$1" path attr
    (cd "$base"; find . -print0) | while IFS= read -r -d '' path; do
        printf '%q ' "$path"
        { stat -f '%u:%g:%p' "$base/$path"
        ls -lde "$base/$path" | sed '1d'
        if [ -L "$base/$path" ]; then
            printf 'link '; readlink "$base/$path"
        elif [ -f "$base/$path" ]; then
            shasum -a 256 < "$base/$path"
        fi
        # -s inspects the symlink itself, never a target outside the bundle.
        xattr -s "$base/$path" | LC_ALL=C sort | while IFS= read -r attr; do
            # macOS can assign new provenance to a copy, even with ditto's
            # metadata-preservation flags. Compare all other attributes,
            # including quarantine; never remove or rewrite either attribute.
            [ "$attr" != com.apple.provenance ] || continue
            printf 'attr %s ' "$attr"; xattr -spx "$attr" "$base/$path"
        done
        } | shasum -a 256
    done
}
if [ -n "$COMPARE" ]; then
    [ -d "$COMPARE" ] && [ ! -L "$COMPARE" ] || fail "comparison app must be a real directory"
    # Stable entry ordering without depending on find traversal order.
    manifest "$APP" > "$TMP/app.manifest"
    manifest "$COMPARE" > "$TMP/compare.manifest"
    # Each path owns one digest covering its content and metadata.
    diff -u <(LC_ALL=C sort "$TMP/app.manifest") <(LC_ALL=C sort "$TMP/compare.manifest") || fail "bundle copy differs (payload or metadata)"
fi
printf 'Identity=%s\nVersion=%s\nBuild=%s\n' "$SIGNER" "$ACTUAL_VERSION" "$ACTUAL_BUILD"
