# Licenses

The native macOS application links the termlog backend and is distributed under GPL-3.0-only. The upstream scrcpy engine retains its Apache-2.0 license; the root LICENSE is unchanged.

- scrcpy: https://github.com/Genymobile/scrcpy — Apache-2.0, included as SCRCPY-LICENSE.
- termlog: https://github.com/maxrave-dev/termlog — GPL-3.0-only, included as TERMLOG-LICENSE; source pinned by the vendor/termlog submodule.
- Rust bridge: macos/TermLogCore — GPL-3.0-only.
- Rust dependencies are pinned in macos/TermLogCore/Cargo.lock. Their package manifests contain their individual license declarations.
- A portable engine also contains its upstream FFmpeg, SDL, libusb and ADB components. Keep the engine distribution's notices and corresponding-source obligations when publishing a signed release.

This prototype does not change the upstream scrcpy or termlog licenses.
