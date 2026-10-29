// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// An owned ADB client, not the shared ADB server. Binary-safe, bounded, separate streams.
final class ADBProcess: @unchecked Sendable {
    private struct Stream {
        var data = Data()
        var total = 0
        mutating func append(_ bytes: Data, capacity: Int) {
            total += bytes.count; data.append(bytes)
            if data.count > capacity { data = Data(data.suffix(capacity)) }
        }
        func page(offset: Int, limit: Int, encoding: String) -> [String: Any] {
            let base = total - data.count
            let start = max(base, min(offset, total))
            let bytes = data.subdata(in: (start - base)..<min(data.count, start - base + limit))
            var result: [String: Any] = ["offset": start, "next_offset": start + bytes.count, "total_bytes": total,
                                         "lost_bytes": max(0, base - offset), "has_more": start + bytes.count < total]
            if encoding == "base64" { result["base64"] = bytes.base64EncodedString() }
            else if let text = String(data: bytes, encoding: .utf8) { result["text"] = text }
            else { result["base64"] = bytes.base64EncodedString(); result["encoding"] = "base64" }
            return result
        }
    }

    private let process = Process()
    private let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
    private let inputQueue = DispatchQueue(label: "dev.maxrave.scrcpy.adb.stdin")
    private let lock = NSLock()
    private let termination = Termination()
    private let capacity: Int
    private var out = Stream(), err = Stream()
    private var finished = false
    private var status: Int32?
    private var signaled = false
    private var timedOut = false
    private var inputClosed = false // owned by inputQueue
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL?, capacity: Int) {
        self.capacity = capacity
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        let termination = self.termination
        process.terminationHandler = { termination.fire(status: $0.terminationStatus, signaled: $0.terminationReason == .uncaughtSignal) }
    }

    func start(timeout: Int) throws {
        do { try process.run() }
        catch {
            for pipe in [stdout, stderr, stdin] { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
            throw error
        }
        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close(); try? stdin.fileHandleForReading.close()
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .utility).async { [self] in drain() }
        if timeout > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) { [weak self] in self?.stop(timeout: true) }
        }
    }

    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var output: Data { lock.lock(); defer { lock.unlock() }; return out.data }
    var outputWasTruncated: Bool { lock.lock(); defer { lock.unlock() }; return out.data.count < out.total }

    func snapshot(stdoutOffset: Int = 0, stderrOffset: Int = 0, limit: Int = 65_536, encoding: String = "text") -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["state": finished ? "finished" : "running", "exit_code": status.map { $0 as Any } ?? NSNull(),
                "signaled": signaled, "timed_out": timedOut,
                "stdout": out.page(offset: stdoutOffset, limit: limit, encoding: encoding),
                "stderr": err.page(offset: stderrOffset, limit: limit, encoding: encoding)]
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if finished { lock.unlock(); continuation.resume() }
                else { waiters.append(continuation); lock.unlock() }
            }
        } onCancel: { self.stop() }
    }

    /// A slow or non-reading child cannot block the MCP actor or the UI thread.
    func write(_ data: Data, close: Bool) async throws {
        guard data.count <= 1_048_576 else { throw AppFailure("stdin writes are limited to 1 MiB") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            inputQueue.async { [self] in
                do {
                    guard !inputClosed else { throw AppFailure("The job's stdin is already closed") }
                    let fd = stdin.fileHandleForWriting.fileDescriptor
                    let flags = fcntl(fd, F_GETFL)
                    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw POSIXError(.EIO) }
                    var sent = 0
                    let deadline = Date().addingTimeInterval(5)
                    while sent < data.count {
                        guard !isFinished, Date() < deadline else { throw AppFailure("stdin write timed out or the job exited") }
                        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        let ready = Darwin.poll(&descriptor, 1, 100)
                        if ready < 0 && errno != EINTR { throw POSIXError(.EIO) }
                        if ready <= 0 { continue }
                        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), data.count - sent) }
                        if count > 0 { sent += count }
                        else if errno != EAGAIN && errno != EINTR { throw AppFailure("The job no longer accepts stdin") }
                    }
                    if close { inputClosed = true; try? stdin.fileHandleForWriting.close() }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop(interrupt: Bool = false, timeout: Bool = false) {
        lock.lock()
        guard !finished, !termination.hasFired else { lock.unlock(); return }
        if timeout { timedOut = true }
        let pid = process.processIdentifier
        if pid > 0 { Darwin.kill(pid, interrupt ? SIGINT : SIGTERM) }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if !self.finished && !self.termination.hasFired { Darwin.kill(pid, SIGKILL) }
        }
    }

    private func drain() {
        let handles = [stdout.fileHandleForReading, stderr.fileHandleForReading]
        var descriptors = handles.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0) }
        for item in descriptors { _ = fcntl(item.fd, F_SETFL, fcntl(item.fd, F_GETFL) | O_NONBLOCK) }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        func readAvailable(_ index: Int) {
            // A descendant's endless output must not hide the owned client's exit.
            for _ in 0..<16 {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptors[index].fd, $0.baseAddress!, $0.count) }
                guard count > 0 else { if count == 0 { descriptors[index].fd = -1 }; return }
                let data = Data(bytes.prefix(count))
                lock.lock()
                if index == 0 { out.append(data, capacity: capacity) } else { err.append(data, capacity: capacity) }
                lock.unlock()
            }
        }
        while true {
            _ = Darwin.poll(&descriptors, 2, 100)
            for index in 0..<2 where descriptors[index].revents != 0 { readAvailable(index) }
            if termination.hasFired { readAvailable(0); readAvailable(1); break }
        }
        let result = termination.wait(pid: process.processIdentifier)
        handles.forEach { try? $0.close() }
        inputQueue.async { [self] in if !inputClosed { inputClosed = true; try? stdin.fileHandleForWriting.close() } }
        lock.lock()
        status = result.status; signaled = result.signaled; finished = true
        let pending = waiters; waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}
