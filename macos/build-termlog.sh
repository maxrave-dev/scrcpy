#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
if [[ ! -x "$CARGO" ]]; then CARGO="$(command -v cargo || true)"; fi
[[ -x "$CARGO" ]] || { echo "error: Cargo is required. Install Rust explicitly before building." >&2; exit 1; }
export PATH="$(dirname "$CARGO"):$PATH"
[[ -f "$ROOT/vendor/termlog/src/model.rs" ]] || { echo "error: Run git submodule update --init --recursive first." >&2; exit 1; }
ARCH="${CURRENT_ARCH:-}"
if [[ "$ARCH" != arm64 && "$ARCH" != x86_64 ]]; then ARCH="${ARCHS:-$(uname -m)}"; fi
case "$ARCH" in
  arm64) TARGET=aarch64-apple-darwin ;;
  x86_64) TARGET=x86_64-apple-darwin ;;
  *) echo "error: Build one macOS architecture at a time (arm64 or x86_64)." >&2; exit 1 ;;
esac
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
"$CARGO" build --locked --release --target "$TARGET" --manifest-path "$ROOT/macos/TermLogCore/Cargo.toml"
DEST="${DERIVED_FILE_DIR:-$ROOT/build-macos-app/lib}"
mkdir -p "$DEST"
cp "$ROOT/macos/TermLogCore/target/$TARGET/release/libscrcpy_termlog_core.a" "$DEST/"
