#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 PORTABLE_ENGINE_DIR [OUTPUT_APP]" >&2; exit 1
fi
ENGINE="$(cd "$1" && pwd)"
OUTPUT="${2:-$ROOT/dist/scrcpy.app}"
[[ ! -e "$OUTPUT" ]] || { echo "error: Output already exists: $OUTPUT. Choose a fresh output path." >&2; exit 1; }
for file in scrcpy adb scrcpy-server scrcpy.png disconnected.png; do
  [[ -f "$ENGINE/$file" ]] || { echo "error: Missing engine asset: $file" >&2; exit 1; }
done
# The release engine is static. Do not silently ship Homebrew-dependent binaries.
for binary in scrcpy adb; do
  while IFS= read -r library; do
    case "$library" in /opt/homebrew/*|/usr/local/*|/Users/*)
      echo "error: $binary depends on external library $library. Use release/build_macos.sh output." >&2; exit 1 ;;
    esac
  done < <(otool -L "$ENGINE/$binary" | awk '/^[[:space:]]/ {print $1}')
done
export SCRCPY_MAC_ENGINE_DIR="$ENGINE"
BUILD="$ROOT/build-macos-app"
xcodebuild -project "$ROOT/macos/ScrcpyMac.xcodeproj" -scheme ScrcpyMac -configuration Release \
  -derivedDataPath "$BUILD" CODE_SIGNING_ALLOWED=NO build
APP="$BUILD/Build/Products/Release/scrcpy.app"
[[ -x "$APP/Contents/Resources/engine/ScrcpyEngine.app/Contents/MacOS/scrcpy" ]] || { echo "error: Engine was not embedded" >&2; exit 1; }
HELPER="$APP/Contents/Resources/engine/ScrcpyEngine.app"
# Ad-hoc signing is only for local testing. Distribution signing/notarization is separate.
codesign --force --sign - "$HELPER/Contents/MacOS/adb"
codesign --force --sign - "$HELPER/Contents/MacOS/scrcpy"
codesign --force --sign - "$HELPER"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$(dirname "$OUTPUT")"
ditto "$APP" "$OUTPUT"
printf 'Created %s (local ad-hoc build; not launched)\n' "$OUTPUT"
