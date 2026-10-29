#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export PATH="$HOME/.cargo/bin:$PATH"
cargo test --locked --manifest-path macos/TermLogCore/Cargo.toml
swiftc macos/ScrcpyMac/Models.swift macos/ScrcpyMacTests/ModelTests.swift -o "$WORK/models"
"$WORK/models"
swiftc macos/ScrcpyMac/{Models,ProcessJob}.swift macos/ScrcpyMacTests/ProcessTests.swift -o "$WORK/processes"
"$WORK/processes"
cc -std=c11 -Wall -Wextra -Werror -Iapp/src app/tests/test_window_geometry.c -o "$WORK/geometry" -lm
"$WORK/geometry"
bash macos/build-termlog.sh
LIB="$ROOT/build-macos-app/lib"
ARGS=(-swift-version 5 -import-objc-header macos/TermLogCore/termlog.h -L"$LIB" -lscrcpy_termlog_core -framework Security -framework SystemConfiguration -framework CoreFoundation -liconv -lresolv)
swiftc "${ARGS[@]}" macos/ScrcpyMac/{Models,LogcatStore}.swift macos/ScrcpyMacTests/BridgeTests.swift -o "$WORK/bridge"
"$WORK/bridge"
swiftc "${ARGS[@]}" macos/ScrcpyMac/{Models,ProcessJob,DeviceStore,SessionManager,ManagerView,LogcatStore,LogcatView,LogcatTable}.swift macos/ScrcpyMacTests/ColorTests.swift -o "$WORK/colors"
"$WORK/colors"
swiftc "${ARGS[@]}" macos/ScrcpyMac/{Models,ProcessJob,DeviceStore,SessionManager,LogcatStore,MCP,MCPTransport,ADBProcess,ADBTools,AppTools}.swift macos/ScrcpyMacTests/MCPTests.swift -o "$WORK/mcp"
"$WORK/mcp"
swiftc -typecheck -swift-version 5 -import-objc-header macos/TermLogCore/termlog.h macos/ScrcpyMac/*.swift
swiftc "${ARGS[@]}" macos/ScrcpyMac/*.swift -o "$WORK/native-link-check"
echo "PASS: native app compile/link; no app launched and no real ADB used"
