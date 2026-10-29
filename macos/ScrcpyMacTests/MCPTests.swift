import Foundation
import Darwin

private final class RPCClient: @unchecked Sendable {
    let input: Int32
    let output: Int32
    private let process: Process?
    private let pipes: [Pipe]
    private let termination: Termination
    private let reader = DispatchQueue(label: "mcp.test.reader")
    private var buffer = Data()
    private var nextID = 0

    init(socket: String, permissions: MCPPermissions) throws {
        input = try MCPUnix.connect(socket); output = input; process = nil; pipes = []; termination = Termination()
        try send(["bridge_version": 1, "permissions": permissions.json])
    }

    init(bridge: URL, environment: [String: String]) throws {
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        let termination = Termination()
        process.terminationHandler = { termination.fire(status: $0.terminationStatus, signaled: $0.terminationReason == .uncaughtSignal) }
        process.executableURL = bridge; process.arguments = ["--mcp"]
        process.environment = environment; process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.standardError
        try process.run()
        try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
        input = stdin.fileHandleForWriting.fileDescriptor; output = stdout.fileHandleForReading.fileDescriptor
        self.process = process; pipes = [stdin, stdout]; self.termination = termination
    }

    func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
        try MCPUnix.send(input, data)
    }
    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        nextID += 1
        try send(["jsonrpc": "2.0", "id": nextID, "method": method, "params": params])
        let result = try await read()
        precondition(result.int("id") == nextID, "Response ID mismatch")
        return result
    }
    func initialize(version: String = "2025-11-25") async throws {
        let reply = try await request("initialize", ["protocolVersion": version, "capabilities": [:], "clientInfo": ["name": "fixture", "version": "1"]])
        precondition(reply.object("result").text("protocolVersion") == version)
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }
    func call(_ name: String, _ arguments: [String: Any] = [:], error expected: Bool = false) async throws -> [String: Any] {
        let reply = try await request("tools/call", ["name": name, "arguments": arguments])
        precondition(reply["error"] == nil, "Unexpected protocol error: \(reply)")
        let result = reply.object("result")
        precondition(result.flag("isError") == expected, "\(name): unexpected tool result \(result)")
        return result
    }
    func read() async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            reader.async { [self] in
                do {
                    let deadline = Date().addingTimeInterval(10)
                    while true {
                        if let newline = buffer.firstIndex(of: 10) {
                            let data = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppFailure("Non-object RPC output") }
                            continuation.resume(returning: result); return
                        }
                        guard Date() < deadline else { throw AppFailure("Test MCP response timed out") }
                        var item = pollfd(fd: output, events: Int16(POLLIN | POLLHUP), revents: 0)
                        if Darwin.poll(&item, 1, 100) <= 0 { continue }
                        var bytes = [UInt8](repeating: 0, count: 65_536)
                        let count = bytes.withUnsafeMutableBytes { Darwin.read(output, $0.baseAddress!, $0.count) }
                        guard count > 0 else { throw AppFailure("Test MCP connection closed") }
                        buffer.append(contentsOf: bytes.prefix(count))
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func close() {
        if process != nil {
            try? pipes[0].fileHandleForWriting.close()
        } else { _ = Darwin.shutdown(input, SHUT_RDWR); Darwin.close(input) }
    }
    func waitForExit() async throws {
        for _ in 0..<100 {
            if termination.hasFired { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        process?.terminate()
        throw AppFailure("stdio bridge failed to exit after stdin EOF")
    }
}

@main
struct MCPTests {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--mcp") { exit(MCPBridge.run(arguments: CommandLine.arguments)) }
        // sockaddr_un paths are limited to 103 UTF-8 bytes on macOS.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpt-\(UUID().uuidString.prefix(12))")
        precondition(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Data(contentsOf: URL(fileURLWithPath: "macos/ScrcpyMacTests/Fixtures/fake-engine.py"))
        for name in ["adb", "scrcpy"] {
            let path = root.appendingPathComponent(name)
            try fixture.write(to: path); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        try Data().write(to: root.appendingPathComponent("scrcpy-server"))
        let calls = root.appendingPathComponent("calls.jsonl")
        setenv("HOME", root.path, 1); setenv("SCRCPY_MAC_ENGINE_DIR", root.path, 1)
        setenv("TEST_ADB_CALLS", calls.path, 1); setenv("ADB", root.appendingPathComponent("adb").path, 1)
        let socket = root.appendingPathComponent("ipc/rpc.sock").path
        setenv("SCRCPY_MCP_SOCKET", socket, 1)
        let suite = "dev.maxrave.scrcpy.mcp-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let devices = DeviceStore(), sessions = SessionManager(), adb = ADBTools()
        sessions.devices = devices
        let app = AppTools(devices: devices, sessions: sessions, defaults: defaults)
        var store: LogcatStore?, copied = "", quit = false
        app.window = { ["window": $0.text("window", default: "manager"), "action": $0.text("action", default: "get")] }
        app.logcat = { store }
        app.openLogcat = { device in
            if let store { store.chooseDevice(device.serial); return store }
            let value = LogcatStore(serial: device.serial)
            value.copyMessage = { copied = $0 }; store = value; return value
        }
        app.closeLogcat = { store?.close(); store = nil }
        app.quit = { quit = true }
        let definitions = AppToolCatalog.tools + ADBToolCatalog.tools
        precondition(Set(definitions.map(\.name)).count == definitions.count)
        let large = MCPReply(value: ["output": String(repeating: "x", count: 1_048_577)])
        let largeJSON = large.json()
        precondition((largeJSON["content"] as? [[String: Any]])?.first?.text("text").contains("structuredContent") == true)
        precondition(largeJSON.object("structuredContent").text("output").count == 1_048_577)
        let server = MCPUnixServer(path: socket, tools: definitions, handler: { name, args, context in
            if name.hasPrefix("app_") { return try await app.call(name, args, context) }
            return try await adb.call(name, args, context)
        }, disconnect: { await adb.close(owner: $0) })
        try server.start()
        defer { server.stop() }
        do {
            let collision = MCPUnixServer(path: socket, tools: [], handler: { _, _, _ in MCPReply(value: [:]) }, disconnect: { _ in })
            try collision.start(); preconditionFailure("Second server replaced the first")
        } catch { /* Existing listener and socket must survive. */ }
        var info = stat(); precondition(lstat(socket, &info) == 0 && info.st_mode & 0o777 == 0o600)

        let readOnly = try RPCClient(socket: socket, permissions: MCPPermissions())
        let beforeInit = try await readOnly.request("tools/list")
        precondition(beforeInit.object("error").int("code") == -32002)
        try await readOnly.initialize()
        let listed = try await readOnly.request("tools/list")
        precondition((listed.object("result")["tools"] as? [[String: Any]])?.count == definitions.count)
        _ = try await readOnly.call("app_status")
        _ = try await readOnly.call("app_help")
        _ = try await readOnly.call("adb_info")
        _ = try await readOnly.call("adb_devices")
        _ = try await readOnly.call("adb_discover")
        let beforeDenied = (try String(contentsOf: calls, encoding: .utf8)).count
        _ = try await readOnly.call("android_input", ["serial": "fixture", "action": "tap", "args": ["1", "2"]], error: true)
        _ = try await readOnly.call("adb_command", ["args": ["root"], "confirm": true], error: true)
        _ = try await readOnly.call("adb_server", ["action": "kill", "confirm": true], error: true)
        _ = try await readOnly.call("app_quit", ["confirm": true], error: true)
        _ = try await readOnly.call("adb_info", ["environment": ["ADB_TRACE": "adb"], "confirm": true], error: true)
        let afterDenied = try String(contentsOf: calls, encoding: .utf8)
        precondition(afterDenied.count == beforeDenied, "Denied calls spawned ADB")
        _ = try await readOnly.call("adb_devices", ["action": "get-state"], error: true)
        _ = try await readOnly.call("app_mirror_defaults", ["action": "set", "audio": 1], error: true)
        _ = try await readOnly.call("adb_info", ["unexpected": true], error: true)
        let image = try await readOnly.call("android_screenshot", ["serial": "fixture"])
        precondition((image["content"] as? [[String: Any]])?.contains(where: { $0.text("type") == "image" && $0.text("mimeType") == "image/png" }) == true)
        _ = try await readOnly.call("android_ui_tree", ["serial": "fixture"])
        try MCPUnix.send(readOnly.input, Data("{bad json}\n".utf8))
        let malformed = try await readOnly.read()
        precondition(malformed.object("error").int("code") == -32700)
        print("PASS: \(definitions.count) schemas, MCP lifecycle/catalog, read-only enforcement, real PNG content, socket permissions/collision")

        let full = try RPCClient(socket: socket, permissions: MCPPermissions(arguments: ["--mcp-allow-raw"]))
        try await full.initialize()
        let executionCases: [(String, [String: Any])] = [
            ("adb_info", ["action": "features"]), ("adb_devices", ["action": "get-state"]),
            ("adb_connection", ["action": "pair", "address": "fixture.local:37001", "pairing_code": "123456"]),
            ("adb_connection", ["action": "disconnect", "all": true]), ("adb_connection", ["action": "tcpip", "port": 5555]),
            ("adb_mdns", ["action": "services"]),
            ("adb_forward", ["action": "add", "local": "tcp:0", "remote": "localabstract:fixture", "no_rebind": true]),
            ("adb_reverse", ["action": "add", "local": "tcp:8080", "remote": "tcp:9000"]),
            ("adb_files", ["action": "push", "args": ["--sync", "file with spaces", "/sdcard/a"]]),
            ("adb_files", ["action": "pull", "args": ["-a", "/sdcard/a", root.path]]),
            ("adb_files", ["action": "sync", "args": ["-n", "system"]]),
            ("adb_install", ["action": "install-multi-package", "args": ["-r", "one.apk", "two.apk"]]),
            ("adb_uninstall", ["package": "dev.fixture", "args": ["-k"]]),
            ("adb_shell", ["command": "printf 'literal; $(not-a-host-command)'"]),
            ("adb_exec_out", ["args": ["printf", "fixture"]]),
            ("adb_logcat", [:]), ("adb_debug", ["action": "bugreport", "path": root.appendingPathComponent("report.zip").path]),
            ("adb_debug", ["action": "jdwp"]), ("adb_system", ["action": "root"]),
            ("adb_system", ["action": "sideload", "args": ["fixture.zip"]]),
            ("adb_server", ["action": "start", "one_device": "fixture"]),
            ("adb_keygen", ["path": root.appendingPathComponent("generated-adb").path]),
            ("adb_emulator", ["args": ["avd", "name"]]),
            ("adb_discover", ["action": "device"]),
            ("adb_discover", ["action": "command-help", "command": "cmd"]),
            ("android_input", ["action": "text", "args": ["a'b; $(literal)"], "display_id": 0])
        ]
        for (name, arguments) in executionCases {
            _ = try await full.call(name, arguments.merging(["serial": "fixture", "confirm": true]) { old, _ in old })
        }
        let callsText = try String(contentsOf: calls, encoding: .utf8)
        precondition(callsText.contains("file with spaces") && !callsText.contains("123456"), "Lost argv boundaries or pairing code leaked into argv")
        let binary = try await full.call("adb_command", ["args": ["fixture-binary"], "encoding": "base64", "confirm": true])
        let binaryResult = binary.object("structuredContent")
        precondition(Data(base64Encoded: binaryResult.object("stdout").text("base64")) == Data([0, 255, 65, 13, 10]))
        precondition(binaryResult.object("stderr").text("base64") == Data("separate stderr".utf8).base64EncodedString())
        let flood = try await full.call("adb_command", ["args": ["fixture-flood"], "output_limit": 1024, "confirm": true])
        precondition(flood.object("structuredContent").object("stdout").int("lost_bytes") == 3976)
        let failure = try await full.call("adb_command", ["args": ["fixture-fail"], "confirm": true], error: true)
        precondition(failure.object("structuredContent").int("exit_code") == 7)
        let timeout = try await full.call("adb_command", ["args": ["fixture-sleep"], "timeout_seconds": 1, "confirm": true], error: true)
        precondition(timeout.object("structuredContent").flag("timed_out"))
        _ = try await full.call("adb_system", ["action": "root", "serial": "fixture"], error: true)
        _ = try await full.call("adb_info", ["environment": ["DYLD_INSERT_LIBRARIES": "/not-allowed"], "confirm": true], error: true)
        _ = try await full.call("adb_info", ["environment": ["ADB_BAD=NAME": "bad"], "confirm": true], error: true)
        _ = try await full.call("adb_info", ["environment": ["ADB_TRACE": "adb"], "confirm": true])
        let combinedFlags = try ADBToolCatalog.plan("adb_logcat", ["serial": "fixture", "args": ["-dc"]])
        precondition(combinedFlags.access == .destructive)
        print("PASS: all ADB command families/passthrough, literal argv, no pairing-code argv, binary/stderr preservation, truncation, failures, timeout")

        try full.send(["jsonrpc": "2.0", "id": "cancel-active", "method": "tools/call", "params": ["name": "adb_command", "arguments": ["args": ["fixture-sleep"], "confirm": true]]])
        try await Task.sleep(for: .milliseconds(100))
        try full.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": "cancel-active"]])
        let cancelled = try await full.read()
        precondition(cancelled.text("id") == "cancel-active" && cancelled.object("result").flag("isError"))
        precondition(cancelled.object("result").object("structuredContent").text("error").contains("cancelled"))

        let started = try await full.call("adb_job_start", ["tool": "adb_shell", "arguments": ["serial": "fixture", "command": "fixture-stdin", "keep_stdin": true, "confirm": true]])
        let job = started.object("structuredContent").text("job_id")
        _ = try await full.call("adb_job_write", ["job_id": job, "stdin_base64": Data([0, 255, 65]).base64EncodedString(), "close": true])
        var jobResult: [String: Any] = [:]
        for _ in 0..<50 {
            jobResult = try await full.call("adb_job_read", ["job_id": job, "encoding": "base64"]).object("structuredContent")
            if jobResult.text("state") == "finished" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(jobResult.text("state") == "finished" && jobResult.object("stdout").text("base64") == Data([0, 255, 65]).base64EncodedString())
        _ = try await readOnly.call("adb_job_read", ["job_id": job], error: true)
        _ = try await full.call("adb_job_list")
        _ = try await full.call("adb_job_stop", ["job_id": job, "forget": true])
        let recording = try await full.call("android_screenrecord", ["serial": "fixture", "remote_path": "/sdcard/fixture.mp4"])
        _ = try await full.call("adb_job_stop", ["job_id": recording.object("structuredContent").text("job_id"), "mode": "interrupt", "forget": true])

        let owner = try RPCClient(socket: socket, permissions: MCPPermissions(arguments: ["--mcp-allow-raw"]))
        try await owner.initialize()
        let stream = try await owner.call("adb_shell", ["serial": "fixture", "command": "fixture-stream", "stream": true, "confirm": true])
        let streamID = stream.object("structuredContent").text("job_id")
        var pid: Int32 = 0
        for _ in 0..<50 {
            let result = try await owner.call("adb_job_read", ["job_id": streamID]).object("structuredContent")
            pid = Int32(result.object("stdout").text("text").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if pid > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(pid > 0)
        owner.close()
        for _ in 0..<100 {
            if Darwin.kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        precondition(Darwin.kill(pid, 0) != 0, "Disconnect leaked an owned ADB client")
        print("PASS: interactive binary stdin/EOF, paged jobs, per-client ownership, interrupt, disconnect cleanup")

        _ = try await full.call("app_window", ["action": "show"])
        _ = try await full.call("app_mirror_defaults", ["action": "set", "max_size": 720, "audio": false])
        precondition(defaults.integer(forKey: "mirror.maxSize") == 720)
        _ = try await full.call("app_devices", ["action": "refresh"])
        _ = try await full.call("app_devices", ["action": "connect", "address": "fixture.local"])
        devices.clearConnectStatus()
        if case .connected = await devices.finishConnect() {} else { preconditionFailure("UI clearing lost the connection outcome") }
        _ = try await full.call("app_device_control", ["action": "wake", "serial": "fixture"])
        _ = try await full.call("app_device_control", ["action": "lock", "serial": "fixture"])
        _ = try await full.call("app_device_control", ["action": "unlock", "serial": "fixture"])
        precondition(devices.unlockTarget?.serial == "fixture")
        let mirror = try await full.call("app_mirror", ["action": "open", "serial": "fixture"])
        precondition((mirror.object("structuredContent")["mirrors"] as? [[String: Any]])?.first?.text("phase") == "running")
        _ = try await full.call("app_mirror", ["action": "stop-all"])
        precondition(sessions.sessions.isEmpty)
        _ = try await full.call("app_logcat", ["action": "open", "serial": "fixture"])
        var snapshot: [String: Any] = [:]
        for _ in 0..<50 {
            snapshot = try await full.call("app_logcat", ["serial": "fixture"]).object("structuredContent")
            if snapshot.int("buffered") >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(snapshot.int("buffered") >= 2)
        _ = try await full.call("app_logcat", ["serial": "wrong-device"], error: true)
        _ = try await full.call("app_logcat", ["action": "query", "query": "tag:AndroidRuntime", "serial": "fixture"])
        _ = try await full.call("app_logcat_tabs", ["action": "new"])
        _ = try await full.call("app_logcat_tabs", ["action": "select", "index": 0])
        _ = try await full.call("app_logcat_tabs", ["action": "close"])
        for action in ["pause", "resume", "unfollow", "follow", "copy"] { _ = try await full.call("app_logcat_view", ["action": action]) }
        precondition(copied.contains("FATAL EXCEPTION: main\n at App.start"))
        _ = try await full.call("app_logcat_filters", ["action": "save", "name": "Fixture crashes"])
        _ = try await full.call("app_logcat_filters", ["action": "list"])
        _ = try await full.call("app_logcat_filters", ["action": "history"])
        _ = try await full.call("app_logcat_filters", ["action": "apply", "name": "Fixture crashes"])
        _ = try await full.call("app_logcat_settings", ["action": "set", "config": ["soft_wrap": true, "columns": ["date": true]]])
        precondition(store?.snapshot?.config.softWrap == true && store?.snapshot?.config.columns.date == true)
        _ = try await full.call("app_logcat_settings", ["action": "set", "config": ["columns": ["unknown": true]]], error: true)
        let export = root.appendingPathComponent("export.log")
        _ = try await full.call("app_logcat_export", ["path": export.path])
        let exported = try String(contentsOf: export, encoding: .utf8)
        precondition(exported.contains("FATAL EXCEPTION"))
        _ = try await full.call("app_logcat_export", ["path": export.path], error: true)
        _ = try await full.call("app_logcat_clear", ["action": "device", "confirm": true])
        _ = try await full.call("app_logcat_clear", ["action": "view"])
        _ = try await full.call("app_logcat", ["action": "query", "query": ""])
        let closing = store
        _ = try await full.call("app_logcat", ["action": "close"])
        await closing?.shutdown()
        _ = try await full.call("app_quit", ["confirm": true])
        try await Task.sleep(for: .milliseconds(350))
        precondition(quit)
        print("PASS: every app tool, shared mirror/defaults/Logcat state, human-only PIN, guarded device selection, tabs/filter/settings/export/clear")

        let legacy = try RPCClient(socket: socket, permissions: MCPPermissions())
        try await legacy.initialize(version: "2024-11-05")
        let oldReply = try await legacy.call("app_help")
        precondition(oldReply["structuredContent"] == nil)
        legacy.close()
        let bridge = try RPCClient(bridge: URL(fileURLWithPath: CommandLine.arguments[0]), environment: ProcessInfo.processInfo.environment)
        try await bridge.initialize()
        _ = try await bridge.call("app_help")
        _ = try await bridge.call("adb_system", ["action": "reboot", "serial": "fixture", "confirm": true], error: true)
        bridge.close()
        try await bridge.waitForExit()
        readOnly.close(); full.close()
        await adb.close(); devices.stop(); await sessions.stopAll()
        print("PASS: active cancellation, malformed JSON, native-only environment overrides, actual stdio EOF shutdown, legacy MCP compatibility; no GUI, real ADB, device input, clipboard mutation or shared-server shutdown")
    }
}
