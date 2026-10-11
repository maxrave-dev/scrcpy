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
        default: return state
        }
    }

    static func parse(_ output: String) -> [AndroidDevice] {
        var seen = Set<String>()
        return output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2, ["device", "offline", "unauthorized", "recovery", "bootloader", "sideload"].contains(String(fields[1])), seen.insert(String(fields[0])).inserted else { return nil }
            let model = fields.dropFirst(2).first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? ""
            return AndroidDevice(serial: String(fields[0]), state: String(fields[1]), model: model)
        }
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
    static func isValid(_ address: String) -> Bool {
        guard !address.isEmpty, !address.hasPrefix("-"), !address.contains(where: { $0.isWhitespace }), let colon = address.lastIndex(of: ":"), let port = Int(address[address.index(after: colon)...]), (1...65535).contains(port) else { return false }
        let host = String(address[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") {
            return host.count > 2 && host.dropFirst().dropLast().allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        return !host.isEmpty && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
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
