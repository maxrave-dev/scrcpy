import Foundation
import Darwin

/// One owned subprocess. Reads continuously, bounds retained output, and never invokes a shell.
final class ProcessJob: @unchecked Sendable {
    struct Result: Sendable {
        let status: Int32
        let output: String
        /// True when a signal (crash, kill) ended the process; `status` is then the signal number.
        var signaled = false
    }
    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var cancellation: Error?
    private var started = false
    private var finished = false
    private let timeout: TimeInterval?
    // Process.isRunning and waitUntilExit() can miss the exit of a process launched from a
    // Swift concurrency thread and block forever; terminationHandler is always called.
    private let termination = Termination()

    init(executable: URL, arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval? = nil) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        self.timeout = timeout
        let termination = self.termination
        process.terminationHandler = { termination.fire(status: $0.terminationStatus, signaled: $0.terminationReason == .uncaughtSignal) }
    }

    var pid: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return started && !finished && !termination.hasFired ? process.processIdentifier : nil
    }

    func run(onOutput: (@Sendable (Data) -> Void)? = nil) async throws -> Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let cancellation {
                    lock.unlock()
                    continuation.resume(throwing: cancellation)
                    return
                }
                do {
                    try process.run()
                    started = true
                    lock.unlock()
                    try? output.fileHandleForWriting.close()
                } catch {
                    finished = true
                    lock.unlock()
                    try? output.fileHandleForWriting.close()
                    try? output.fileHandleForReading.close()
                    continuation.resume(throwing: error)
                    return
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.cancel(reason: AppFailure("Command timed out after \(Int(timeout)) seconds"))
                    }
                }
                DispatchQueue.global(qos: .utility).async { [self] in
                    var retained = Data()
                    do {
                        let fd = output.fileHandleForReading.fileDescriptor
                        let flags = fcntl(fd, F_GETFL)
                        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw POSIXError(.EIO) }
                        var bytes = [UInt8](repeating: 0, count: 4096)
                        var eof = false
                        /// Reads what is available, at most 256 KiB, so a descendant's endless
                        /// output cannot hide that the parent exited. True at end of file.
                        func drain() throws -> Bool {
                            for _ in 0..<64 {
                                let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
                                if count > 0 {
                                    let data = Data(bytes.prefix(count))
                                    retained.append(data)
                                    if retained.count > 65_536 { retained = Data(retained.suffix(65_536)) }
                                    onOutput?(data)
                                } else if count == 0 { return true }
                                else if errno == EAGAIN || errno == EINTR { return false }
                                else { throw POSIXError(.EIO) }
                            }
                            return false
                        }
                        while !eof {
                            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                            let ready = Darwin.poll(&descriptor, 1, 100)
                            if ready < 0 {
                                if errno == EINTR { continue }
                                throw POSIXError(.EIO)
                            }
                            if ready > 0 { eof = try drain() }
                            // Foundation's blocking read-to-EOF would wait forever
                            // if an ADB descendant inherited the pipe. The owned
                            // process has finished; its final buffered output is drained,
                            // including stdio flushed at exit after the last read.
                            if termination.hasFired {
                                if !eof { _ = try drain() }
                                break
                            }
                        }
                    } catch { cancel(reason: error) }
                    let (status, signaled) = termination.wait(pid: process.processIdentifier)
                    lock.lock()
                    finished = true
                    let error = cancellation
                    lock.unlock()
                    try? output.fileHandleForReading.close()
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: Result(status: status, output: String(decoding: retained, as: UTF8.self), signaled: signaled)) }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel(reason: Error = CancellationError()) {
        lock.lock()
        guard !finished, cancellation == nil else { lock.unlock(); return }
        cancellation = reason
        let shouldTerminate = started && !termination.hasFired
        if shouldTerminate { process.terminate() }
        lock.unlock()
        guard shouldTerminate else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock()
            if !finished && !termination.hasFired { Darwin.kill(process.processIdentifier, SIGKILL) }
            lock.unlock()
        }
    }
}

/// Exit status delivered by Process.terminationHandler.
final class Termination: @unchecked Sendable {
    private let signal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var status: Int32?
    private var signaled = false

    var hasFired: Bool { lock.lock(); defer { lock.unlock() }; return status != nil }

    func fire(status: Int32, signaled: Bool) {
        lock.lock(); self.status = status; self.signaled = signaled; lock.unlock()
        signal.signal()
    }

    /// Blocks until the process has exited. Should the handler ever be missed, a pid that no
    /// longer exists ends the wait within a second (status -1) instead of blocking forever.
    func wait(pid: pid_t) -> (status: Int32, signaled: Bool) {
        while signal.wait(timeout: .now() + 1) == .timedOut {
            if Darwin.kill(pid, 0) != 0 && errno == ESRCH { return (-1, false) }
        }
        lock.lock(); defer { lock.unlock() }
        return (status ?? -1, signaled)
    }
}
