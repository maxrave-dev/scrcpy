# scrcpy for macOS — native prototype

The manager is AppKit + SwiftUI (macOS 14+). Each selected device launches the fork's own scrcpy client with --window-borderless. No video pipeline is reimplemented.

## Current local build

The Apple Silicon prototype is packaged at ../dist/scrcpy.app (about 33 MB). The native app and patched static C engine build successfully, and codesign --verify --deep --strict passes. The bundled server matches the documented 5.0.1 SHA-256. Only system macOS libraries are referenced at runtime; Homebrew is not needed to run this bundle. No app window or real device has been opened by the build/verification workflow.

The static build also uses a locally compiled zlib 1.3.2 with MACOSX_DEPLOYMENT_TARGET=14.0, rather than the host macOS-27 Homebrew static archive. This avoids raising the engine's deployment target through a dependency.

## Windows

- Manager: discover ADB devices, show authorization/offline/connecting states, Open mirror, Show window, Stop, Logcat, and connect to an already-paired wireless device. A bare host uses port 5555. The Wi-Fi sheet stays open with progress and ADB's error until the connection succeeds; success shows a banner and refreshes the list. Disabled buttons are dimmed.
- Device keys: one split pill per ready device. Unlock opens the PIN sheet. Lock sends KEYCODE_SLEEP, then reports whether deviceLocked engaged or only the screen went off; that depends on the device's lock timeout. Volume down / up send KEYCODE_VOLUME_DOWN / KEYCODE_VOLUME_UP, like the device's own buttons and scrcpy's MOD+↓ / MOD+↑. A failure shows a red banner for 5 seconds.
- Reconnect: a Wi-Fi device that was ready and then disappears or goes offline keeps its row. The row shows the progress while the app waits 2, 4 and 8 seconds before three attempts. Each attempt checks whether ADB recovered on its own; otherwise it runs adb connect, preceded by adb disconnect for an offline transport. Once the device is back, a mirror that was showing reopens with the options it had, and Logcat restarts if it shows that device. After three failures the row offers Reconnect and Forget. Commands that only read state wait through the same window. Swipes, PIN and Enter are never resent.
- Unlock: Wake screen sends KEYCODE_WAKEUP. Unlock wakes the device, reads deviceLocked from dumpsys trust, swipes up from the lower middle of the screen (input swipe, sized from wm size) to show the PIN pad, types the PIN and confirms with Enter, then reports whether the device unlocked. The swipe, PIN and Enter are sent only while SystemUI's lock screen holds input focus on display 0 (mCurrentFocus in dumpsys window displays). A mirror adds scrcpy's own virtual display. The PIN is typed only while a secure lock is reported. On Android 10+, input targets display 0 with input -d 0. If a check is unknown or an app has focus, nothing is swiped or typed, and the error names the focused window. Enter waits for PIN auto-confirm first. A short race remains, about one check plus starting input, for example if face unlock completes in that moment.
- Android mirror: titlebar hidden by default. Moving the pointer into the 20-point band at the top reveals the native macOS titlebar, so the window can be dragged normally. Leaving the wider 60-point top retain band hides it after 300 ms; hovering the titlebar or holding the left mouse button keeps it visible. Content size/position are restored around decoration changes. The hover behavior is limited to app-managed, windowed video mirrors. Option + drag/edge-resize remains available while borderless; ordinary Android input, relative-mouse mode and fullscreen are unchanged.
- Logcat: one native window, shared tabs and device picker, using the real pinned termlog backend. Filter language, pause/follow, complete-message copy, saved filters/history, columns, wrapping, ring capacity, buffer selection, restart, clear view, confirmed device-buffer clearing and export are available. Level letters and complete messages use vivid severity colors; tags keep stable UTF-8 FNV colors from termlog's ten-color palette. Metadata stays quieter, and light/dark counterparts maintain readable text, including selected rows. No terminal UI or terminal subprocess is launched.
- Closing the manager hides it without stopping mirrors. The Dock or Show devices menu reopens it. Closing Logcat stops its collection. Quit stops the app's owned mirror processes and Logcat stream, without killing the shared ADB server.

## Source and prerequisites

Clone/update submodules with git submodule update --init --recursive. vendor/termlog is pinned at 9bb363c531236af2db0e36c9893a161078a85d7a; upstream sources are not modified or duplicated. macos/TermLogCore imports its backend modules directly and excludes the terminal renderer.

The GUI requires Xcode 15+ and an installed Rust toolchain. Xcode builds the Rust static library automatically; Cargo downloads locked dependencies on the first build. Neither the scripts nor the app install toolchains or Rust targets automatically. The Xcode project builds the host architecture; build Intel and Apple Silicon on the appropriate toolchain separately.

The patched C engine must be built separately. See ../doc/build.md and ../release/build_macos.sh. Meson, Ninja and pkg-config are required for a client build; the complete static release script also builds upstream dependencies and requires their toolchains (including CMake). That release build may take tens of minutes on a cold cache. No Gradle/server build is required for this change: use a prebuilt scrcpy-server matching client version 5.0.1.

## Build the app

Open ScrcpyMac.xcodeproj and choose the ScrcpyMac scheme. Provide SCRCPY_MAC_ENGINE_DIR as a build setting/environment variable pointing to a portable engine directory containing scrcpy, adb, scrcpy-server, scrcpy.png and disconnected.png. The default is release/work/build-macos-aarch64/dist on Apple Silicon, or release/work/build-macos-x86_64/dist on Intel.

If no engine exists, the GUI can still compile, but it explains the missing engine instead of silently falling back to an unpatched Homebrew client. For an unbundled development engine, SCRCPY_MAC_ENGINE_DIR can also be set in the Run scheme environment.

To package an existing static engine, from the repository root:

```bash
./release/package_macos_app.sh /absolute/path/to/portable/engine
```

This builds and ad-hoc signs dist/scrcpy.app for local testing. It does not launch the app, install it, connect to a device or notarize it. Existing output paths are refused. Use a fresh second argument for another output path. External Homebrew library references are rejected rather than shipped as a broken standalone app.

## Verification

```bash
./macos/test.sh
```

This runs termlog's imported parser/query tests, bridge tests, native model/process tests and SDL-independent window-geometry tests. The native bridge integration uses an isolated fake ADB executable and temporary HOME; it exercises ingestion, Swift decoding, filters, tabs and export without a physical device. It also compiles/links the native app without launching it. It does not run Gradle, a simulator or a real ADB command.

Manual verification still requires permission to run the app against a real device: first frame/readiness, click/swipe/typing, Option drag/resize, Retina/multiple monitors, focusing helper windows, reconnect, closing the manager and quitting.

## Data and privacy

- Mirror defaults and window frames: macOS UserDefaults under the app domain dev.maxrave.scrcpy, retained until reset.
- termlog settings/history/saved filters: upstream Config::path(); on macOS this is ~/Library/Application Support/termlog/config.json, not the Linux ~/.config path. Existing termlog configuration is reused.
- Logcat entries: the upstream in-memory ring buffer (default 250,000 entries). The view requests at most 500 entries per snapshot; it does not instantiate hundreds of thousands of SwiftUI rows. Pause keeps collecting into the ring.
- Mirror diagnostics: at most 64 KiB per owned process; discarded with the session.
- Export: only on a user-chosen save path. Clear view is local; clearing device buffers requires explicit confirmation.
- Engine bundle: Contents/Resources/engine/ScrcpyEngine.app. Only scrcpy and adb executables live in its Contents/MacOS; scrcpy-server and PNG assets live in its Contents/Resources. Keeping data out of the executable directory is required for code signing. The helper is an LSUIElement app so the manager owns the main Dock entry.
- ADB uses the existing user authorization keys; no automatic TCP/IP enablement, adb kill-server, telemetry, uploads or screen-capture cache.
- Device PIN: 4–16 digits held only by the open Unlock sheet and passed once to adb shell input text; never stored or logged.

## License

The native application and Rust adapter link GPL-3.0-only termlog and are distributed under GPL-3.0-only. The original scrcpy engine/root LICENSE remain Apache-2.0. See LICENSE and THIRD_PARTY_NOTICES.md in this directory. This is a local prototype, not a notarized distribution release.
