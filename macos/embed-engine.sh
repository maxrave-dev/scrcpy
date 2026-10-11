#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
mkdir -p "$RESOURCES"
ENGINE="${SCRCPY_MAC_ENGINE_DIR:-}"
if [[ -z "$ENGINE" ]]; then
  case "${ARCHS:-$(uname -m)}" in
    arm64) ENGINE="$ROOT/release/work/build-macos-aarch64/dist" ;;
    x86_64) ENGINE="$ROOT/release/work/build-macos-x86_64/dist" ;;
  esac
fi
if [[ -n "$ENGINE" && -x "$ENGINE/scrcpy" && -x "$ENGINE/adb" && -f "$ENGINE/scrcpy-server" ]]; then
  HELPER="$RESOURCES/engine/ScrcpyEngine.app/Contents"
  mkdir -p "$HELPER/MacOS" "$HELPER/Resources"
  for file in scrcpy adb scrcpy-server scrcpy.png disconnected.png; do
    [[ -f "$ENGINE/$file" ]] || { echo "error: Portable engine is missing $file" >&2; exit 1; }
    case "$file" in
      scrcpy|adb) cp "$ENGINE/$file" "$HELPER/MacOS/" ;;
      *) cp "$ENGINE/$file" "$HELPER/Resources/" ;;
    esac
  done
  # Remove only misplaced assets from earlier builds of this owned bundle.
  rm -f "$HELPER/MacOS/scrcpy-server" "$HELPER/MacOS/scrcpy.png" "$HELPER/MacOS/disconnected.png"
  chmod +x "$HELPER/MacOS/scrcpy" "$HELPER/MacOS/adb"
  cp "$ROOT/macos/EngineInfo.plist" "$HELPER/Info.plist"
  printf 'APPL????' > "$HELPER/PkgInfo"
  # Xcode signs the outer app later; nested executable code must already be sealed.
  codesign --force --sign - "$HELPER/MacOS/adb"
  codesign --force --sign - "$HELPER/MacOS/scrcpy"
  codesign --force --sign - "$RESOURCES/engine/ScrcpyEngine.app"
else
  if [[ -n "${SCRCPY_MAC_ENGINE_DIR:-}" ]]; then
    echo "error: SCRCPY_MAC_ENGINE_DIR must contain scrcpy, adb and scrcpy-server." >&2; exit 1
  fi
  # This directory is an owned build output, never user data. Do not retain
  # an older engine after a subsequent build without an engine input.
  rm -rf "$RESOURCES/engine"
  echo "warning: No portable fork engine found. The manager will explain the missing engine at runtime; set SCRCPY_MAC_ENGINE_DIR for a runnable package." >&2
fi
cp "$ROOT/LICENSE" "$RESOURCES/SCRCPY-LICENSE"
cp "$ROOT/vendor/termlog/LICENSE" "$RESOURCES/TERMLOG-LICENSE"
cp "$ROOT/macos/THIRD_PARTY_NOTICES.md" "$RESOURCES/"
# Reuse the existing scrcpy icon; no new branding or browser renderer.
ICONSET="${DERIVED_FILE_DIR:?}/scrcpy.iconset"
mkdir -p "$ICONSET"
for n in 16 32 128 256 512; do
  sips -z "$n" "$n" "$ROOT/app/data/scrcpy.png" --out "$ICONSET/icon_${n}x${n}.png" >/dev/null
  double=$((n * 2))
  sips -z "$double" "$double" "$ROOT/app/data/scrcpy.png" --out "$ICONSET/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/scrcpy.icns"
