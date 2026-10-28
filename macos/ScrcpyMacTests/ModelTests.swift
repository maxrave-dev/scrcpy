import Foundation

@main
struct ModelTests {
    static func main() {
        let output = """
        * daemon started successfully *
        List of devices attached
        usb-1 device product:panther model:Pixel_7 device:panther transport_id:1
        usb-2 unauthorized transport_id:2
        192.168.1.8:37821 offline transport_id:3
        nonsense without-a-device-state
        usb-1 device model:Pixel_7
        """
        let devices = AndroidDevice.parse(output)
        precondition(devices.count == 3, "Ignore daemon/header/invalid lines and duplicate serials")
        precondition(devices[0].name == "Pixel 7")
        precondition(devices[0].isReady && !devices[1].isReady && !devices[2].isReady)
        precondition(devices[2].connection == "Wi-Fi")
        let options = MirrorOptions(maxSize: 1080, audio: false, onTop: true)
        let arguments = options.arguments(serial: "serial with spaces; $(touch bad)", name: "Pixel")
        precondition(arguments.contains("--window-borderless"))
        precondition(arguments.contains("--serial=serial with spaces; $(touch bad)"), "Serial stays one argument, never a shell command")
        precondition(arguments.contains("--max-size=1080") && arguments.contains("--no-audio") && arguments.contains("--always-on-top"))
        precondition(!MirrorOptions().arguments(serial: "x", name: "x").contains { $0.hasPrefix("--max-size=") })
        precondition(DeviceAddress.isValid("192.168.1.2:5555"))
        precondition(DeviceAddress.isValid("[::1]:5555"))
        for value in ["", "--help", "host", "host:0", "host:65536", "host:abc", "host name:5555", "host:5555;rm"] {
            precondition(!DeviceAddress.isValid(value), "Reject malformed/option-like address: \(value)")
        }
        precondition(DeviceAddress.normalized(" 192.168.1.2 ") == "192.168.1.2:5555" && DeviceAddress.normalized("[::1]") == "[::1]:5555", "A bare host gets adb's default port")
        precondition(DeviceAddress.normalized("192.168.1.2:37001") == "192.168.1.2:37001")
        for value in ["--help", "-h", "host name", "host:5555;rm"] {
            precondition(!DeviceAddress.isValid(DeviceAddress.normalized(value)), "Normalizing must not make an invalid address valid: \(value)")
        }
        precondition(AndroidDevice.parse("10.0.0.2:5555 connecting\n10.0.0.3:5555 authorizing\n").count == 2, "Show new Wi-Fi connections before they are ready")
        precondition(LockScreen.isValidPIN("1234") && LockScreen.isValidPIN("0123456789012345"))
        for value in ["", "123", "12345678901234567", "12a4", "1234;reboot", "12 34", "١٢٣٤"] {
            precondition(!LockScreen.isValidPIN(value), "Only 4-16 ASCII digits reach the device shell: \(value)")
        }
        let trust = """
        Trust manager state:
         User "Owner" (id=0, flags=0xc13) (current): trusted=0, trustManaged=1, deviceLocked=1, isActiveUnlockRunning=0, strongAuthRequired=0x0
         User "Work" (id=10, flags=0x1030): trusted=0, trustManaged=0, deviceLocked=0, strongAuthRequired=0x0
        """
        precondition(LockScreen.isLocked(trustDump: trust) == true, "Use the current user's lock state")
        precondition(LockScreen.isLocked(trustDump: trust.replacingOccurrences(of: "deviceLocked=1", with: "deviceLocked=0")) == false)
        precondition(LockScreen.isLocked(trustDump: "Trust manager state:\n") == nil, "An unknown state must not be treated as locked or unlocked")
        // Android 17 replaces trusted=0 with trustState=; deviceLocked keeps its format.
        precondition(LockScreen.isLocked(trustDump: " User \"Đức\" (id=0, flags=0x4c13) (current): trustState=UNTRUSTED, trustManaged=0, deviceLocked=1, isActiveUnlockRunning=0") == true)
        precondition(LockScreen.isLocked(trustDump: trust.replacingOccurrences(of: " (current)", with: "")) == nil, "Without a current marker, another user's line must not decide")
        precondition(LockScreen.keyguardHasFocus(windowDump: "  mCurrentFocus=Window{9cf4626 u0 NotificationShade}") == true)
        precondition(LockScreen.keyguardHasFocus(windowDump: "  mCurrentFocus=Window{1a2b u0 com.example.chat/com.example.chat.Thread}") == false, "An app above the lock screen must not receive the PIN")
        precondition(LockScreen.keyguardHasFocus(windowDump: "  mCurrentFocus=null") == false && LockScreen.keyguardHasFocus(windowDump: "") == nil)
        let mirrored = "  Display: mDisplayId=2 (organized)\n  mCurrentFocus=null\n  Display: mDisplayId=0 (organized)\n  mCurrentFocus=Window{9cf4626 u0 NotificationShade}\n"
        precondition(LockScreen.keyguardHasFocus(windowDump: mirrored) == true, "Only display 0 decides; scrcpy's mirror display has no focus")
        precondition(LockScreen.keyguardHasFocus(windowDump: "  Display: mDisplayId=0\n  mCurrentFocus=Window{1 u0 com.example/.Main}\n  Display: mDisplayId=3\n  mCurrentFocus=Window{2 u0 NotificationShade}\n") == false, "Another display's lock screen must not unlock typing on display 0")
        precondition(LockScreen.keyguardHasFocus(windowDump: "  Display: mDisplayId=10\n  mCurrentFocus=Window{2 u0 NotificationShade}\n") == nil, "Display 10 is not display 0")
        // Real Android 17 dump while mirroring: scrcpy's virtual display 4 is listed first.
        let sofascore = "  Display: mDisplayId=4\n  mCurrentFocus=null\n  Display: mDisplayId=0 (organized)\n  mCurrentFocus=Window{8a960 u0 com.sofascore.results/com.sofascore.results.main.MainActivity}\n"
        precondition(LockScreen.focusedWindow(windowDump: sofascore) == "com.sofascore.results/com.sofascore.results.main.MainActivity" && LockScreen.keyguardHasFocus(windowDump: sofascore) == false, "An unlocked app must never be swiped or typed into")
        precondition(LockScreen.focusedWindow(windowDump: "  mCurrentFocus=Window{e118f5e u0 Lightweight Headsup}") == "Lightweight Headsup")
        precondition(LockScreen.screenSize(wmSize: "Physical size: 1224x2720\n")! == (1224, 2720))
        precondition(LockScreen.screenSize(wmSize: "Physical size: 1440x3120\nOverride size: 1080x2340\n")! == (1080, 2340), "Input uses the override size")
        precondition(LockScreen.screenSize(wmSize: "37\n") == nil)
        let transports = AndroidDevice.transportIDs("List of devices attached\n100.109.92.12:5555 device product:a56 model:SM_A566B device:a56x transport_id:2\nusb-2 unauthorized transport_id:7\n")
        precondition(transports == ["100.109.92.12:5555": "2", "usb-2": "7"], "A reconnect shows up as a new transport id")
        // Seen from the Samsung while it unlocked; both prefixes come from the same adb.
        for message in ["error: closed", "adb: device offline", "adb: device offline (no transport)", "adb: device '100.109.92.12:5555' not found", "adb: no devices/emulators found", "error: protocol fault (couldn't read status): Connection reset by peer"] {
            precondition(ADBMessage.isConnectionLoss(message), "A dropped connection must be waited out: \(message)")
        }
        for message in ["Error: Unknown command: text", "/system/bin/sh: wm: not found", "adb: failed to stat remote object", "Command timed out after 10 seconds"] {
            precondition(!ADBMessage.isConnectionLoss(message), "Not a dropped connection: \(message)")
        }
        var lines = LineBuffer()
        precondition(lines.append(Data("INFO: SCRCPY_MAC_".utf8)).isEmpty)
        precondition(lines.append(Data("WINDOW_READY\nERROR: broken\n".utf8)) == ["INFO: SCRCPY_MAC_WINDOW_READY", "ERROR: broken"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let binaries = root.appendingPathComponent("Contents/MacOS")
        let resources = root.appendingPathComponent("Contents/Resources")
        try! FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        for name in ["scrcpy", "adb"] {
            let file = binaries.appendingPathComponent(name)
            try! Data("#!/bin/sh\\nexit 0\\n".utf8).write(to: file)
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        try! Data("fixture".utf8).write(to: resources.appendingPathComponent("scrcpy-server"))
        let previous = ProcessInfo.processInfo.environment["SCRCPY_MAC_ENGINE_DIR"]
        setenv("SCRCPY_MAC_ENGINE_DIR", binaries.path, 1)
        let paths = try! EnginePaths.resolve()
        precondition(paths.server == resources.appendingPathComponent("scrcpy-server"))
        precondition(paths.environment["SCRCPY_ICON_DIR"] == resources.path, "Resources must not live in the executable/signing directory")
        if let previous { setenv("SCRCPY_MAC_ENGINE_DIR", previous, 1) } else { unsetenv("SCRCPY_MAC_ENGINE_DIR") }
        try! FileManager.default.removeItem(at: root)
        print("PASS: device parsing, serial-safe arguments, Wi-Fi validation, PIN/lock state, chunked logs, bundle resource paths")
    }
}
