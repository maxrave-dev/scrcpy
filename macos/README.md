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

This runs termlog's imported parser/query tests, bridge tests, native model/process tests and SDL-independent window-geometry tests. The native bridge integration uses an isolated fake ADB executable and temporary HOME; it exercises ingestion, Swift decoding, filters, tabs and export without a physical device. MCP integration tests use Python 3 fixtures and exercise the real stdio/Unix transport, all tool groups, access profiles, binary output/stdin, jobs, cancellation and shared native state without GUI windows or clipboard mutation. It also compiles/links the native app without launching it. It does not run Gradle, a simulator or a real ADB command.

Manual verification still requires permission to run the app against a real device: first frame/readiness, click/swipe/typing, Option drag/resize, Retina/multiple monitors, focusing helper windows, reconnect, closing the manager and quitting.

## MCP automation

The app exposes its **live** manager, mirror sessions and native Logcat backend, plus the bundled ADB CLI. There is no second device manager or duplicate Logcat collector. This integration uses Foundation/Darwin only; no additional runtime, package install or HTTP listener is required.

### Connect an agent

Build this version of the app and open it yourself first. The stdio bridge deliberately does **not** launch the GUI, connect devices, install an app or replace anything in `/Applications` automatically. Point your MCP client's stdio configuration at the executable **inside that same app bundle**:

```json
{
  "mcpServers": {
    "scrcpy": {
      "command": "/absolute/path/to/scrcpy.app/Contents/MacOS/scrcpy",
      "args": ["--mcp", "--mcp-allow-control"]
    }
  }
}
```

`--mcp` runs only the stdio bridge, not another GUI. With no permission flags, the connection is **read-only**. Choose permissions explicitly in your trusted client's launch configuration:

| Flag | Access profile |
| --- | --- |
| none | Status, discovery, finite logs, screenshots, UI hierarchy and owned read-only jobs |
| `--mcp-allow-control` | Also app/window/mirror controls, device input, pairing, installs, file transfers and log-view changes |
| `--mcp-allow-destructive` | Also destructive operations; includes control. Each such call requires `confirm: true` |
| `--mcp-allow-raw` | Full bundled ADB/Android shell passthrough; includes control and destructive access. Raw calls require `confirm: true` |

The client must still enforce human approval. `confirm` is an acknowledgement, **not** proof of human consent. Raw access can perform destructive commands and read sensitive device data; do not enable it for an untrusted agent. These flags select the trusted local client's profile, not an authentication boundary against other processes running as the same OS user.

The GUI listens on a Unix socket in a private `0700` per-user temporary directory; the socket is `0600`, both peers verify the OS UID, and a lock prevents a second instance replacing an active listener. There are no TCP ports or credential files. For an isolated development instance, set `SCRCPY_MCP_SOCKET` to a short absolute socket path inside a private directory **in both the GUI and bridge environments**. macOS limits Unix socket paths to 103 UTF-8 bytes.

### Tool catalog

`tools/list` returns the complete catalog, JSON input schemas, permitted `action` values and conservative safety annotations. Permissions are checked at execution time, not just advertised in annotations.

| App tool | Coverage |
| --- | --- |
| `app_status`, `app_help` | Live state, engine availability, connection permissions and filter help |
| `app_window` | Manager/Logcat visibility, focus, close, minimize/restore, frame origin and size |
| `app_devices` | List, refresh, connect, cancel-connect, reconnect, forget |
| `app_device_control` | Wake, lock, volume, request Unlock in the existing sheet |
| `app_mirror` | List/status, open, focus, stop, stop-all, retry; open waits for the ready marker by default |
| `app_mirror_defaults` | Get/set max_size, audio and on_top for new mirrors |
| `app_logcat` | Open/close, device, snapshot, query and restart using the GUI's store |
| `app_logcat_tabs`, `app_logcat_view` | Tabs, pause/resume, follow, scroll, selection and complete-message copy |
| `app_logcat_filters`, `app_logcat_settings` | Saved filters/history and partial settings patches |
| `app_logcat_export`, `app_logcat_clear` | Export matched entries; clear local view or confirmed Android buffers |
| `app_quit` | Request shutdown of app-owned work, never the shared ADB server |

Unlock returns `awaiting_user_input`: the human enters the PIN in the existing native sheet. No MCP PIN argument exists. Copy uses the macOS clipboard. `app_quit` returns `shutdown_requested`, not a claim that shutdown has already completed. Native Logcat remains a single shared window: supplying `serial` on its actions rejects an unexpected selected device rather than silently acting on another phone. Applying a query, changing tabs or settings intentionally updates that shared UI.

| ADB tool | Coverage |
| --- | --- |
| `adb_info` | help, version, features, host-features, server-status |
| `adb_devices` | List/track devices, identity/state, wait-for states and transports |
| `adb_connection`, `adb_mdns` | Connect/disconnect/pair/reconnect, USB/TCP mode, attach/detach, mDNS discovery/tracking |
| `adb_forward`, `adb_reverse` | List/add/remove/remove-all, native socket forms, no-rebind |
| `adb_files` | push, pull, sync with native flags/compression/dry-run |
| `adb_install`, `adb_uninstall` | Single/split/atomic multi-package installation, native options, uninstall |
| `adb_shell`, `adb_exec_out` | Raw scripts, interactive shell, binary-safe exec-out |
| `adb_logcat`, `adb_debug` | Native logcat options/stream, bugreport, JDWP and JDWP tracking |
| `adb_system` | reboot, sideload, root/unroot, remount, enable/disable verity |
| `adb_server` | Shared-server status/start/kill/foreground, listen socket/interface, one-device |
| `adb_keygen`, `adb_emulator` | Key generation (private key is not read/returned), emulator console |
| `adb_command` | Complete argv passthrough, including global flags, exec-in and future/version-specific commands |
| `adb_discover` | Host help; device SDK, binaries, cmd services, dumpsys services and command help |
| `android_input` | Literal input arguments, source and logical display ID; never automatically retried |
| `android_screenshot` | PNG returned as MCP image content, not merely a local filename |
| `android_screenrecord`, `android_ui_tree` | Owned screen-recording job; primary-display uiautomator hierarchy |

Most ADB tools accept native `args`, an explicit `serial` **or** `transport_id`, optional `server_host`/`server_port`, timeout and output settings. `environment` can override native `ADB_`/`ANDROID_` variables (string values, or null to unset), including tracing, product output and discovery options; overrides require raw permission and are not returned/logged. Unrelated host-loader environment injection is rejected. `adb_command` accepts complete argv and therefore allows native selectors/global options directly; the caller is responsible for explicitly selecting a device for device commands. Arguments are passed directly to the bundled executable, never through a host shell. `adb_shell` intentionally permits Android shell syntax; `android_input` instead shell-quotes each literal argument. Pairing codes go to ADB stdin, not its process arguments. Device permissions and Android/OEM/version support still apply: exposing `root` does not root a production phone, and wrappers do not fabricate success for unsupported commands.

Android shell commands are not a finite cross-device catalog. `am`, `pm`, `cmd`, `dumpsys`, `settings`, `getprop`, `setprop`, `wm`, `content`, `appops`, `run-as`, `perfetto`, toybox and OEM tools remain available through `adb_shell`, with `adb_discover` providing device-specific help. New ADB commands/flags remain accessible through `adb_command` without an app update.

`android_input` uses Android 10+ logical-display targeting (default `0`). Screenshots default to the primary display; screencap's optional `physical_display_id` belongs to a **different ID namespace**. Use display/SurfaceFlinger diagnostics to map secondary displays; never assume a physical ID equals an input display ID. `android_ui_tree` is explicitly primary-display only, may omit custom-rendered UI and can fail when Android cannot become idle. Native `input text` retains Android's text/encoding limitations; failures are not silently retried through another mechanism.

### Results, streaming and cancellation

Recent MCP clients receive `structuredContent` and a JSON text content block; for results above 1 MiB the text block is a short pointer to the complete structured result rather than a duplicate blob. Screenshots additionally contain an MCP PNG image. Older protocol versions receive the text content representation. Oversized responses return an actionable error rather than silently dropping the connection; effects already sent to a device are not undone. The server supports initialization/version negotiation, ping, tool discovery/calls and cancellation; it does not advertise unsupported resources, prompts or MCP task capabilities.

Finite ADB calls default to a 30-second timeout and retain at most 256 KiB per output stream. `timeout_seconds`, `output_limit` (up to 8 MiB) and `encoding` (`text`/`base64`) are configurable. Results report `state`, `exit_code`, `signaled`, `timed_out` and **separate** stdout/stderr objects. A nonzero exit is a tool error. The streams report byte offsets, `total_bytes`, `lost_bytes` and `has_more`; truncation is never hidden. Non-UTF-8 or split UTF-8 pages fall back to base64. Large reports/files should use explicit output paths rather than an unbounded response.

Streaming tools, `stream:true` or `adb_job_start` return a `job_id`. The job tools are:

- `adb_job_start`: run a registered ADB/Android tool with its existing validation and permissions. Example: `{"tool":"adb_logcat","arguments":{"serial":"DEVICE","stream":true}}`.
- `adb_job_list`: list only this connection's jobs.
- `adb_job_read`: read stdout/stderr using independent `stdout_offset`/`stderr_offset`, `limit` and `encoding`. Continue from each returned `next_offset`.
- `adb_job_write`: send `stdin` or `stdin_base64`; `close:true` sends EOF. Start with `keep_stdin:true` to keep input open.
- `adb_job_stop`: `mode:"interrupt"` allows commands such as screenrecord to finalize; otherwise terminate. `forget:true` releases a completed job.

Jobs default to a one-hour timeout; an explicit job timeout of `0` disables it. Each connection owns at most 16 retained jobs, with 64 across the app; finished retention can be reclaimed when limits are reached. Jobs are not shared between clients. Closing the MCP connection or quitting the app stops its owned ADB **client** processes, without `adb kill-server`. Cancelling a finite request cancels its owned process. Cancelling or losing a response does not prove that device input failed: no input command is automatically replayed.

The server bounds concurrent clients, requests, input frames, queued output and retained process output. It does not persist MCP requests, commands, stdin or output. Your MCP client may retain tool calls/results in its own history; do not put credentials in raw commands or text input unless that history is acceptable.

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
