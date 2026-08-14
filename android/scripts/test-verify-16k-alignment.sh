#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

mkdir -p "$temporary/payload/lib/arm64-v8a" \
  "$temporary/sdk/build-tools/1.0.0" \
  "$temporary/ndk/toolchains/llvm/prebuilt/test/bin"
printf 'fixture' > "$temporary/payload/lib/arm64-v8a/libfixture.so"
(cd "$temporary/payload" && zip -q -r "$temporary/fixture.apk" lib)

cat > "$temporary/sdk/build-tools/1.0.0/zipalign" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$temporary/sdk/build-tools/1.0.0/zipalign"

readelf="$temporary/ndk/toolchains/llvm/prebuilt/test/bin/llvm-readelf"
cat > "$readelf" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$readelf"
if ANDROID_HOME="$temporary/sdk" "$root/scripts/verify-16k-alignment.sh" "$temporary/fixture.apk" "$temporary/ndk" >/dev/null 2>&1; then
  echo "Expected llvm-readelf failure to fail verification" >&2
  exit 1
fi

cat > "$readelf" <<'EOF'
#!/usr/bin/env bash
echo 'ELF file with no program load headers'
EOF
if ANDROID_HOME="$temporary/sdk" "$root/scripts/verify-16k-alignment.sh" "$temporary/fixture.apk" "$temporary/ndk" >/dev/null 2>&1; then
  echo "Expected zero LOAD rows to fail verification" >&2
  exit 1
fi

cat > "$readelf" <<'EOF'
#!/usr/bin/env bash
echo 'LOAD 0x000000 0x000000 0x000000 0x100 0x100 R E 0x4000'
EOF
ANDROID_HOME="$temporary/sdk" "$root/scripts/verify-16k-alignment.sh" "$temporary/fixture.apk" "$temporary/ndk" >/dev/null
echo "PASS verifier failure fixtures"
