import Foundation
import Darwin

@main
struct ProcessTests {
    static func check(_ condition: Bool, _ name: String) {
        if !condition { fputs("FAIL: \(name)\n", stderr); exit(1) }
    }
    static func main() async throws {
        let result = try await ProcessJob(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", "hello; $(not-a-command)"]).run()
        check(result.status == 0 && result.output == "hello; $(not-a-command)", "arguments never become shell syntax")
        let start = Date()
        let job = ProcessJob(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"])
        let task = Task { try await job.run() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { _ = try await task.value; check(false, "cancellation must throw") } catch is CancellationError {}
        check(Date().timeIntervalSince(start) < 3, "owned process is stopped promptly")
        let before = Date()
        // A descendant holding stdout must not delay the parent's completion.
        let inherited = try await ProcessJob(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 1 & printf parent"]).run()
        check(inherited.output == "parent" && Date().timeIntervalSince(before) < 0.6, "inherited pipe cannot keep the session alive")
        print("PASS: subprocess argument isolation, cancellation, inherited-pipe completion")
    }
}
