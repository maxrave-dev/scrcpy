// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

enum MCPUnix {
    static var path: String {
        ProcessInfo.processInfo.environment["SCRCPY_MCP_SOCKET"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("scrcpy-mcp-\(geteuid())/rpc.sock").path
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw AppFailure("MCP socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes + [0]) }
        return address
    }
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }
    static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }
    static func send(_ fd: Int32, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else { throw AppFailure("MCP connection closed or its reader stopped accepting data (\(String(cString: strerror(errno))))") }
        }
    }
    static func connect(_ path: String) throws -> Int32 {
        var info = stat()
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard lstat(parent, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFDIR, info.st_mode & 0o077 == 0,
              lstat(path, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFSOCK else { throw AppFailure("Open the MCP-enabled scrcpy.app first (no private socket at \(path)).") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        configure(fd)
        do {
            var address = try address(path)
            let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0, sameUser(fd) else { throw AppFailure("Cannot connect to scrcpy MCP. Open/restart the newly built app first.") }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
}

/// newline framing is internal too; no network listener, REST server, credentials or shell.
final class MCPUnixServer {
    private let tools: [MCPTool]
    private let handler: MCPRPCSession.Handler
    private let disconnect: (String) async -> Void
    private let path: String
    private let lock = NSLock()
    private var listener: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private var peers: [UUID: MCPUnixPeer] = [:]

    init(path: String = MCPUnix.path, tools: [MCPTool], handler: @escaping MCPRPCSession.Handler, disconnect: @escaping (String) async -> Void) {
        self.path = path; self.tools = tools; self.handler = handler; self.disconnect = disconnect
    }

    func start() throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFDIR else { throw AppFailure("MCP requires a private directory owned by this user") }
        guard chmod(directory.path, 0o700) == 0 else { throw POSIXError(.EACCES) }
        let guardFD = Darwin.open(directory.appendingPathComponent("server.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard guardFD >= 0 else { throw AppFailure("Cannot lock MCP socket directory") }
        guard fstat(guardFD, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFREG, flock(guardFD, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(guardFD); throw AppFailure("Another scrcpy MCP server is already running") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { Darwin.close(guardFD); throw POSIXError(.ENFILE) }
        do {
            MCPUnix.configure(fd)
            if lstat(path, &info) == 0 {
                guard info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFSOCK else { throw AppFailure("Refusing to replace a non-socket MCP path") }
                guard unlink(path) == 0 else { throw POSIXError(.EACCES) }
            }
            var address = try MCPUnix.address(path)
            let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else { throw AppFailure("Cannot bind scrcpy MCP socket") }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in self?.accept(fd) }
            source.setCancelHandler { Darwin.close(fd) }
            lock.lock(); lockFD = guardFD; listener = source; lock.unlock()
            source.resume()
        } catch { Darwin.close(fd); Darwin.close(guardFD); throw error }
    }

    private func accept(_ listenerFD: Int32) {
        while true {
            let fd = Darwin.accept(listenerFD, nil, nil)
            guard fd >= 0 else { return }
            MCPUnix.configure(fd)
            // Darwin accept() inherits O_NONBLOCK from the listener; each peer has a blocking reader.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            guard MCPUnix.sameUser(fd) else { Darwin.close(fd); continue }
            let id = UUID()
            let peer = MCPUnixPeer(fd: fd, tools: tools, handler: handler, disconnect: disconnect) { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.peers[id] = nil; self.lock.unlock()
            }
            lock.lock()
            guard listener != nil, peers.count < 8 else { lock.unlock(); Darwin.close(fd); continue }
            peers[id] = peer
            lock.unlock()
            peer.start()
        }
    }

    func stop() {
        lock.lock()
        guard let source = listener else { lock.unlock(); return }
        listener = nil
        let clients = Array(peers.values), guardFD = lockFD
        lockFD = -1
        lock.unlock()
        source.cancel(); clients.forEach { $0.close() }
        _ = unlink(path)
        Darwin.close(guardFD)
    }
    deinit { stop() }
}

private final class MCPUnixPeer: @unchecked Sendable {
    private let fd: Int32
    private let tools: [MCPTool]
    private let handler: MCPRPCSession.Handler
    private let disconnect: (String) async -> Void
    private let ended: () -> Void
    private let writer = DispatchQueue(label: "dev.maxrave.scrcpy.mcp.writer")
    private let lock = NSLock()
    private var closed = false
    private var queuedBytes = 0

    init(fd: Int32, tools: [MCPTool], handler: @escaping MCPRPCSession.Handler, disconnect: @escaping (String) async -> Void, ended: @escaping () -> Void) {
        self.fd = fd; self.tools = tools; self.handler = handler; self.disconnect = disconnect; self.ended = ended
    }
    func start() { DispatchQueue.global(qos: .utility).async { [self] in read() } }
    func close() {
        lock.lock(); let alreadyClosed = closed; closed = true; lock.unlock()
        if !alreadyClosed { _ = Darwin.shutdown(fd, SHUT_RDWR) }
    }
    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { close(); return }
        if data.count >= 24 * 1_048_576 {
            let error = MCPReply.failure(AppFailure("Response exceeds the 24 MiB transport limit. The action may already have completed; do not replay input. Request fewer Logcat rows, reduce output_limit, or use a paged ADB job/export."))
            guard let replacement = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": object["id"] ?? NSNull(), "result": error.json(structured: false)]) else { close(); return }
            data = replacement
        }
        data.append(10)
        lock.lock()
        guard !closed, queuedBytes + data.count <= 32 * 1_048_576 else { lock.unlock(); close(); return }
        queuedBytes += data.count
        lock.unlock()
        writer.async { [self, data] in
            lock.lock(); let stop = closed; lock.unlock()
            if !stop { do { try MCPUnix.send(fd, data) } catch { close() } }
            lock.lock(); queuedBytes -= data.count; lock.unlock()
        }
    }
    private func read() {
        var session: MCPRPCSession?
        var buffer = Data(), bytes = [UInt8](repeating: 0, count: 16_384)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        loop: while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard line.count <= 1_048_576 else { break loop }
                if session == nil {
                    guard let hello = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], hello.int("bridge_version") == 1 else { break loop }
                    let permissions = hello.object("permissions")
                    var grants = MCPPermissions()
                    grants.raw = permissions.flag("raw")
                    grants.destructive = grants.raw || permissions.flag("destructive")
                    grants.control = grants.destructive || permissions.flag("control")
                    session = MCPRPCSession(context: MCPContext(id: UUID().uuidString, permissions: grants), tools: tools, handler: handler, output: { [weak self] in self?.send($0) }, disconnect: disconnect)
                    timeout = timeval(tv_sec: 0, tv_usec: 0)
                    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                } else if let session {
                    // Preserve input order without waiting for tool execution (receive schedules it).
                    let accepted = DispatchSemaphore(value: 0)
                    Task { await session.receive(line); accepted.signal() }
                    accepted.wait()
                }
            }
            guard buffer.count <= 1_048_576 else { break }
        }
        close()
        if let session { Task { await session.close() } }
        writer.async { [self] in Darwin.close(fd); ended() }
    }
}

/// Agent-facing standard MCP stdio transport. The GUI remains the sole state owner.
enum MCPBridge {
    static func run(arguments: [String]) -> Int32 {
        do {
            let fd = try MCPUnix.connect(MCPUnix.path)
            let hello: [String: Any] = ["bridge_version": 1, "permissions": MCPPermissions(arguments: arguments).json]
            var data = try JSONSerialization.data(withJSONObject: hello); data.append(10)
            try MCPUnix.send(fd, data)
            let finished = DispatchSemaphore(value: 0)
            _ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)
            DispatchQueue.global().async {
                var bytes = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let count = bytes.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress!, $0.count) }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { break }
                    do { try MCPUnix.send(fd, Data(bytes.prefix(count))) } catch { break }
                }
                _ = Darwin.shutdown(fd, SHUT_RDWR); finished.signal()
            }
            DispatchQueue.global().async {
                var bytes = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { break }
                    do { try MCPUnix.send(STDOUT_FILENO, Data(bytes.prefix(count))) } catch { break }
                }
                _ = Darwin.shutdown(fd, SHUT_RDWR); finished.signal()
            }
            finished.wait()
            // main immediately exits, so a blocked stdin reader cannot retain this process.
            return 0
        } catch { fputs("scrcpy MCP: \(error.localizedDescription)\n", stderr); return 1 }
    }
}
