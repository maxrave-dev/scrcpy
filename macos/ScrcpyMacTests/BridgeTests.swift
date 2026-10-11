import Foundation
import Darwin

@main
struct BridgeTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let adb = root.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        if [ "$1" = devices ]; then
          printf 'List of devices attached\\nfixture device model:Fixture_Device device:fixture\\n'
        elif [ "$3" = logcat ]; then
          printf '[ 2026-10-11 12:00:00.123 42: 43 E/AndroidRuntime ]\\nFATAL EXCEPTION: main\\n at App.start(App.kt:2)\\n\\n[ 2026-10-11 12:00:00.124 42: 43 I/Other ]\\nafter\\n\\n'
        elif [ "$3" = shell ]; then
          case "$4" in
            ps*) printf 'PID NAME\\n42 dev.example.app:remote\\n' ;;
            pm*) printf 'package:dev.example.app\\n' ;;
          esac
        fi
        """
        try script.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        // Real upstream backend, but all child commands and persisted config are isolated.
        setenv("ADB", adb.path, 1)
        setenv("HOME", root.path, 1)
        var error: UnsafeMutablePointer<CChar>?
        guard let core = "fixture".withCString({ termlog_create($0, &error) }) else {
            throw AppFailure(error.map { String(cString: $0) } ?? "No backend")
        }
        defer { termlog_destroy(core) }
        func request(_ value: [String: Any]) throws -> LogcatSnapshot {
            let data = try JSONSerialization.data(withJSONObject: value)
            let pointer = String(decoding: data, as: UTF8.self).withCString { termlog_request(core, $0) }!
            defer { termlog_free_string(pointer) }
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(LogcatSnapshot.self, from: Data(String(cString: pointer).utf8))
        }
        var snapshot = try request(["action": "snapshot"])
        for _ in 0..<30 where snapshot.buffered < 2 {
            try await Task.sleep(for: .milliseconds(50))
            snapshot = try request(["action": "snapshot"])
        }
        precondition(snapshot.buffered == 2 && snapshot.devices.first?.name == "Fixture Device")
        snapshot = try request(["action": "query", "query": "is:crash & -tag:Other"])
        precondition(snapshot.matched == 1 && snapshot.rows[0].message == "FATAL EXCEPTION: main\n at App.start(App.kt:2)")
        snapshot = try request(["action": "new_tab"])
        precondition(snapshot.tabs.count == 2 && snapshot.active == 1 && snapshot.matched == 1)
        _ = try request(["action": "save_filter", "name": "Crashes"])
        let file = root.appendingPathComponent("export.log")
        _ = try request(["action": "export", "path": file.path])
        let exported = try String(contentsOf: file, encoding: .utf8)
        precondition(exported.contains("FATAL EXCEPTION: main\n at App.start(App.kt:2)"))
        precondition(!exported.contains("after"))
        print("PASS: real Rust ingestion → C ABI → Swift decoding, filter, tabs, export (fake ADB only)")
    }
}
