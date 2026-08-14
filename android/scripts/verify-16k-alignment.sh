#!/usr/bin/env bash
set -euo pipefail

apk="${1:-app/build/outputs/apk/release/app-release-unsigned.apk}"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
ndk="${2:-${sdk}/ndk/28.2.13676358}"

[[ -f "$apk" ]] || { echo "APK not found: $apk" >&2; exit 1; }
[[ -d "$ndk" ]] || { echo "NDK not found: $ndk" >&2; exit 1; }

readelf=""
for candidate in "$ndk"/toolchains/llvm/prebuilt/*/bin/llvm-readelf; do
  if [[ -x "$candidate" ]]; then readelf="$candidate"; break; fi
done
[[ -n "$readelf" ]] || { echo "llvm-readelf not found under $ndk" >&2; exit 1; }

zipalign=""
while IFS= read -r directory; do
  if [[ -x "$directory/zipalign" ]]; then zipalign="$directory/zipalign"; break; fi
done < <(printf '%s\n' "$sdk"/build-tools/* | sort -Vr)
[[ -n "$zipalign" ]] || { echo "zipalign not found under $sdk/build-tools" >&2; exit 1; }

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
unzip -qq "$apk" 'lib/*.so' -d "$temporary"

count=0
while IFS= read -r library; do
  count=$((count + 1))
  if ! program_headers="$("$readelf" -lW "$library" 2>&1)"; then
    echo "FAIL llvm-readelf: $library" >&2
    echo "$program_headers" >&2
    exit 1
  fi
  load_alignments="$(printf '%s\n' "$program_headers" | awk '$1 == "LOAD" { print $NF }')"
  [[ -n "$load_alignments" ]] || { echo "FAIL no ELF LOAD rows: $library" >&2; exit 1; }
  load_count=0
  while IFS= read -r alignment; do
    [[ -n "$alignment" ]] || continue
    [[ "$alignment" =~ ^(0x[0-9a-fA-F]+|[0-9]+)$ ]] || {
      echo "FAIL invalid ELF LOAD alignment: $library align=$alignment" >&2
      exit 1
    }
    load_count=$((load_count + 1))
    value=$((alignment))
    if (( value < 16384 )); then
      echo "FAIL ELF alignment: $library LOAD align=$alignment" >&2
      exit 1
    fi
  done <<< "$load_alignments"
  (( load_count > 0 )) || { echo "FAIL no parsed ELF LOAD rows: $library" >&2; exit 1; }
  echo "PASS ELF 16KB: ${library#"${temporary}"/}"
done < <(find "$temporary/lib" -type f -name '*.so' | sort)
(( count > 0 )) || { echo "No native libraries found in $apk" >&2; exit 1; }

"$zipalign" -c -P 16 -v 4 "$apk" >/dev/null
echo "PASS APK ZIP 16KB: $apk"
