import Foundation
import Darwin

/// One owned subprocess. Reads continuously, bounds retained output, and never invokes a shell.
final class ProcessJob: @unchecked Sendable {
    struct Result: Sendable {
        let status: Int32
        let output: String
    }
    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var cancellation: Error?
    private var started = false
    private var finished = false
    private let timeout: TimeInterval?

    init(executable: URL, arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval? = nil) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        self.timeout = timeout
    }

    var pid: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return started && !finished && process.isRunning ? process.processIdentifier : nil
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
                        while !eof {
                            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                            let ready = Darwin.poll(&descriptor, 1, 100)
                            if ready < 0 {
                                if errno == EINTR { continue }
                                throw POSIXError(.EIO)
                            }
                            if ready > 0 {
                                // Drain at most 256 KiB per poll so a descendant's
                                // endless output cannot hide that the parent exited.
                                for _ in 0..<64 {
                                    let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
                                    if count > 0 {
                                        let data = Data(bytes.prefix(count))
                                        retained.append(data)
                                        if retained.count > 65_536 { retained = Data(retained.suffix(65_536)) }
                                        onOutput?(data)
                                    } else if count == 0 { eof = true; break }
                                    else if errno == EAGAIN || errno == EINTR { break }
                                    else { throw POSIXError(.EIO) }
                                }
                            }
                            // Foundation's blocking read-to-EOF would wait forever
                            // if an ADB descendant inherited the pipe. The owned
                            // process has finished; its final buffered output is drained.
                            if !process.isRunning { break }
                        }
                    } catch { cancel(reason: error) }
                    process.waitUntilExit()
                    lock.lock()
                    finished = true
                    let error = cancellation
                    lock.unlock()
                    try? output.fileHandleForReading.close()
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: Result(status: process.terminationStatus, output: String(decoding: retained, as: UTF8.self))) }
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
        let shouldTerminate = started && process.isRunning
        if shouldTerminate { process.terminate() }
        lock.unlock()
        guard shouldTerminate else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock()
            if !finished && process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            lock.unlock()
        }
    }
}
