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
        print("PASS: device parsing, serial-safe arguments, Wi-Fi validation, chunked logs, bundle resource paths")
    }
}
