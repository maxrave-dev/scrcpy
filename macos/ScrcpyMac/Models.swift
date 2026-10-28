import Foundation

struct AndroidDevice: Identifiable, Equatable, Codable {
    let serial: String
    let state: String
    let model: String
    var id: String { serial }
    var name: String { model.isEmpty ? serial : model }
    var isReady: Bool { state == "device" }
    var connection: String { serial.contains(":") ? "Wi-Fi" : "USB" }
    var explanation: String {
        switch state {
        case "device": return "Ready"
        case "unauthorized": return "Allow USB debugging on this device"
        case "offline": return "Device is offline"
        case "connecting": return "Connecting…"
        case "authorizing": return "Waiting for the device to accept this Mac"
        case "reconnecting": return "Reconnecting…"
        default: return state
        }
    }

    static func parse(_ output: String) -> [AndroidDevice] {
        var seen = Set<String>()
        return output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            // A new Wi-Fi connection passes through connecting/authorizing; list it instead of hiding it.
            guard fields.count >= 2, ["device", "offline", "unauthorized", "connecting", "authorizing", "recovery", "bootloader", "sideload"].contains(String(fields[1])), seen.insert(String(fields[0])).inserted else { return nil }
            let model = fields.dropFirst(2).first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? ""
            return AndroidDevice(serial: String(fields[0]), state: String(fields[1]), model: model)
        }
    }
}

extension AndroidDevice {
    /// `transport_id:` per serial from `adb devices -l`; ADB assigns a new one whenever it
    /// reconnects a device, which ends streams such as logcat on the old transport.
    static func transportIDs(_ output: String) -> [String: String] {
        var ids: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2, ids[String(fields[0])] == nil, let id = fields.dropFirst().first(where: { $0.hasPrefix("transport_id:") }) else { continue }
            ids[String(fields[0])] = String(id.dropFirst("transport_id:".count))
        }
        return ids
    }
}

struct MirrorOptions {
    var maxSize = 0
    var audio = true
    var onTop = false

    func arguments(serial: String, name: String) -> [String] {
        var result = ["--serial=\(serial)", "--window-borderless", "--window-title=\(name)", "--no-terminal-title", "--verbosity=debug"]
        if maxSize > 0 { result.append("--max-size=\(maxSize)") }
        if !audio { result.append("--no-audio") }
        if onTop { result.append("--always-on-top") }
        return result
    }
}

enum DeviceAddress {
    /// The port `adb connect` uses when none is given (`adb tcpip 5555`).
    static let defaultPort = 5555

    /// Trims the input and gives a bare host ADB's default port, as `adb connect` does.
    static func normalized(_ input: String) -> String {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return isHost(address) ? "\(address):\(defaultPort)" : address
    }

    static func isValid(_ address: String) -> Bool {
        guard !address.isEmpty, !address.hasPrefix("-"), !address.contains(where: { $0.isWhitespace }), let colon = address.lastIndex(of: ":"), let port = Int(address[address.index(after: colon)...]), (1...65535).contains(port) else { return false }
        return isHost(String(address[..<colon]))
    }

    private static func isHost(_ host: String) -> Bool {
        if host.hasPrefix("[") && host.hasSuffix("]") {
            return host.count > 2 && host.dropFirst().dropLast().allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        return !host.isEmpty && !host.hasPrefix("-") && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
}

enum ADBMessage {
    /// A phone on Wi-Fi drops its ADB connection when its network or VPN resets, often as the screen
    /// wakes or unlocks; ADB reconnects within a second and the command in flight fails. The client
    /// words it "error: closed", "adb: device offline" or "adb: device '…' not found", by version.
    static func isConnectionLoss(_ message: String) -> Bool {
        let text = message.lowercased()
        guard text.hasPrefix("error: ") || text.hasPrefix("adb: ") else { return false }
        return ["closed", "offline", "not found", "no devices", "protocol fault", "connection reset"].contains { text.contains($0) }
    }
}

enum LockScreen {
    /// Android PINs are 4–16 ASCII digits. Nothing else is ever sent to the device shell.
    static func isValidPIN(_ pin: String) -> Bool {
        (4...16).contains(pin.utf8.count) && pin.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    /// Reads `deviceLocked` for the current user from `dumpsys trust`: true while a secure lock
    /// screen is up, false once unlocked or without a secure lock. Nil when the current user is unknown.
    static func isLocked(trustDump: String) -> Bool? {
        let users = trustDump.components(separatedBy: .newlines).filter { $0.contains("deviceLocked=") }
        // Another user's line would describe the wrong lock screen.
        guard let line = users.first(where: { $0.contains(") (current):") }) ?? (users.count == 1 ? users.first : nil), let field = line.range(of: "deviceLocked=") else { return nil }
        switch line[field.upperBound...].prefix(while: { $0.isLetter || $0.isNumber }) {
        case "1", "true": return true
        case "0", "false": return false
        default: return nil
        }
    }

    /// Title of the window focused on the built-in display 0, from `dumpsys window displays`
    /// ("null" without focus). Every display reports its own focus, and a mirror lists scrcpy's
    /// virtual display first. Nil when display 0 reports none.
    static func focusedWindow(windowDump: String) -> String? {
        var display: Substring?
        for line in windowDump.components(separatedBy: .newlines) {
            if let header = line.range(of: "Display: mDisplayId=") {
                display = line[header.upperBound...].prefix(while: { $0.isNumber })
            } else if let field = line.range(of: "mCurrentFocus="), display == nil || display == "0" {
                let value = line[field.upperBound...].trimmingCharacters(in: .whitespaces)
                // Window{9cf4626 u0 NotificationShade}; a title may contain spaces.
                guard value.hasPrefix("Window{"), value.hasSuffix("}") else { return value }
                return value.dropFirst(7).dropLast().split(separator: " ", maxSplits: 2).last.map(String.init) ?? value
            }
        }
        return nil
    }

    /// Whether SystemUI's lock screen (NotificationShade since Android 11, StatusBar before) holds
    /// input focus on display 0. A show-when-locked app could reuse the title, but such an app
    /// could equally draw a fake lock screen.
    static func keyguardHasFocus(windowDump: String) -> Bool? {
        focusedWindow(windowDump: windowDump).map { ["NotificationShade", "StatusBar", "Keyguard"].contains($0) }
    }

    /// The last `wm size` line wins: an override size is listed after the physical size.
    static func screenSize(wmSize: String) -> (width: Int, height: Int)? {
        guard let line = wmSize.components(separatedBy: .newlines).last(where: { $0.contains("size:") }),
              let value = line.split(separator: " ").last else { return nil }
        let parts = value.split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return (parts[0], parts[1])
    }
}

struct LineBuffer {
    private var pending = Data()
    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            lines.append(String(decoding: pending[..<newline], as: UTF8.self))
            pending.removeSubrange(...newline)
        }
        // A malformed unterminated log line must not grow without bound.
        if pending.count > 65_536 { pending = Data(pending.suffix(65_536)) }
        return lines
    }
}

struct EnginePaths {
    let directory: URL
    let resources: URL
    var scrcpy: URL { directory.appendingPathComponent("scrcpy") }
    var adb: URL { directory.appendingPathComponent("adb") }
    var server: URL { resources.appendingPathComponent("scrcpy-server") }
    var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["ADB"] = adb.path
        environment["SCRCPY_SERVER_PATH"] = server.path
        environment["SCRCPY_ICON_DIR"] = resources.path
        environment["SCRCPY_MAC_MANAGED"] = "1"
        environment["SDL_MAC_BACKGROUND_APP"] = "1"
        return environment
    }

    static func resolve() throws -> EnginePaths {
        let directory: URL
        if let override = ProcessInfo.processInfo.environment["SCRCPY_MAC_ENGINE_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = Bundle.main.resourceURL!.appendingPathComponent("engine/ScrcpyEngine.app/Contents/MacOS", isDirectory: true)
        }
        let resources = directory.lastPathComponent == "MacOS"
            ? directory.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
            : directory
        let paths = EnginePaths(directory: directory, resources: resources)
        for binary in [paths.scrcpy, paths.adb] {
            guard FileManager.default.isExecutableFile(atPath: binary.path) else {
                throw AppFailure("Missing engine executable: \(binary.path). Build/package the fork, or set SCRCPY_MAC_ENGINE_DIR to its portable dist directory.")
            }
        }
        guard FileManager.default.fileExists(atPath: paths.server.path) else { throw AppFailure("Missing scrcpy-server in \(resources.path). It must match the client version.") }
        return paths
    }
}

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// An adb command that failed because the device's connection dropped, either with a message
/// such as "adb: device offline" or silently with a non-zero exit when the transport closed mid-command.
struct ConnectionLost: LocalizedError {
    let device: String
    let detail: String
    var errorDescription: String? { detail.isEmpty ? "ADB lost the connection to \(device)." : "ADB lost the connection to \(device) (\(detail))." }
}
