// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct LogcatConfig: Codable, Equatable {
    struct Columns: Codable, Equatable {
        var date = false, time = true, pid = true, level = true, tag = true, package = true
    }
    struct SavedFilter: Codable, Equatable { var name: String; var query: String }
    var bufferSize = 250_000
    var softWrap = false
    var showHints = true
    var buffers = "main,system,crash"
    var columns = Columns()
    var saved: [SavedFilter] = []
    var history: [String] = []
}

struct LogcatRow: Decodable, Identifiable {
    let seq: UInt64
    let date, time: String
    let pid, tid: UInt32
    let level, tag, package, message: String
    var id: UInt64 { seq }
}

struct LogcatSnapshot: Decodable {
    struct Tab: Decodable, Identifiable { let index: Int; let name, query: String; let count: Int; var id: Int { index } }
    let serial: String
    let active: Int
    let paused, follow: Bool
    let selected, offset, matched, buffered: Int
    let seen: UInt64
    let queryError: String?
    let status: String
    let config: LogcatConfig
    let rows: [LogcatRow]
    let tabs: [Tab]
    let devices: [AndroidDevice]
}

/// The opaque Rust handle and every backend call belong exclusively to this queue.
private final class LogcatWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.maxrave.scrcpy.logcat", qos: .userInitiated)
    private var handle: OpaquePointer?
    private var closed = false

    func open(serial: String, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        queue.async { [self] in
            guard !closed else { return }
            var error: UnsafeMutablePointer<CChar>?
            handle = serial.withCString { termlog_create($0, &error) }
            guard handle != nil else {
                let message = error.map { String(cString: $0) } ?? "Cannot initialize Logcat"
                if let error { termlog_free_string(error) }
                completion(.failure(AppFailure(message)))
                return
            }
            completion(requestNow(["action": "snapshot"]))
        }
    }

    func request(_ value: [String: Any], completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        // Serialize before crossing queues; the bridge accepts JSON, never pointers into Swift objects.
        do {
            let data = try JSONSerialization.data(withJSONObject: value)
            queue.async { [self] in
                guard !closed, let handle else { return }
                let response = String(decoding: data, as: UTF8.self).withCString { termlog_request(handle, $0) }
                guard let response else { completion(.failure(AppFailure("Logcat returned no response"))); return }
                defer { termlog_free_string(response) }
                completion(.success(Data(String(cString: response).utf8)))
            }
        } catch { completion(.failure(error)) }
    }

    private func requestNow(_ value: [String: Any]) -> Result<Data, Error> {
        do {
            guard let handle else { throw AppFailure("Logcat is closed") }
            let data = try JSONSerialization.data(withJSONObject: value)
            guard let response = String(decoding: data, as: UTF8.self).withCString({ termlog_request(handle, $0) }) else { throw AppFailure("Logcat returned no response") }
            defer { termlog_free_string(response) }
            return .success(Data(String(cString: response).utf8))
        } catch { return .failure(error) }
    }

    func close(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            closed = true
            if let handle { termlog_destroy(handle); self.handle = nil }
            completion?()
        }
    }
}

@MainActor @Observable
final class LogcatStore {
    private(set) var snapshot: LogcatSnapshot?
    private(set) var error: String?
    var query = ""
    var settingsPresented = false
    var historyPresented = false
    var helpPresented = false
    var savePresented = false
    var confirmClearDevice = false
    var filterName = ""
    @ObservationIgnored private let worker = LogcatWorker()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var snapshotPending = false
    @ObservationIgnored private var pageOffset: Int?

    init(serial: String) {
        worker.open(serial: serial) { [weak self] result in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.receive(result)
                self.timer = Task { [weak self] in
                    while !Task.isCancelled {
                        self?.refresh()
                        do { try await Task.sleep(for: .milliseconds(180)) } catch { break }
                    }
                }
            }
        }
    }

    func close() { closed = true; timer?.cancel(); timer = nil; worker.close() }

    func shutdown() async {
        closed = true; timer?.cancel(); timer = nil
        await withCheckedContinuation { continuation in worker.close { continuation.resume() } }
    }

    func refresh() {
        guard !closed, snapshot != nil, !snapshotPending else { return }
        snapshotPending = true
        var value: [String: Any] = ["action": "snapshot", "limit": 200]
        if let pageOffset { value["offset"] = pageOffset }
        worker.request(value) { [weak self] result in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.snapshotPending = false
                self.receive(result)
            }
        }
    }

    func send(_ action: String, _ arguments: [String: Any] = [:]) {
        guard !closed else { return }
        var value = arguments
        value["action"] = action
        value["limit"] = 200
        if value["offset"] == nil, let pageOffset { value["offset"] = pageOffset }
        worker.request(value) { [weak self] result in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.receive(result)
            }
        }
    }

    private func receive(_ result: Result<Data, Error>) {
        do {
            let data = try result.get()
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let message = object?["error"] as? String { throw AppFailure(message) }
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let value = try decoder.decode(LogcatSnapshot.self, from: data)
            let changedTab = snapshot?.active != value.active || snapshot?.serial != value.serial
            snapshot = value
            if changedTab { query = value.tabs[value.active].query; pageOffset = nil }
            error = nil
            if let copied = object?["copied"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copied, forType: .string)
            }
        } catch { self.error = error.localizedDescription }
    }

    func applyQuery(_ value: String? = nil) { if let value { query = value }; send("query", ["query": query]) }
    func chooseTab(_ index: Int) { pageOffset = nil; send("tab", ["index": index]) }
    func chooseDevice(_ serial: String) { pageOffset = nil; send("device", ["serial": serial]) }
    func pause() { if let snapshot { send("pause", ["paused": !snapshot.paused]) } }
    func follow() { pageOffset = nil; send("follow", ["follow": true]) }
    func select(_ row: LogcatRow, copy: Bool = false) { send(copy ? "copy" : "select", ["seq": row.seq]) }
    func copySelected() { send("copy") }

    func visibleRowsChanged(first: Int, last: Int, userScrolled: Bool) {
        guard let snapshot, first >= 0 else { return }
        if userScrolled {
            pageOffset = first
            send("scroll", ["offset": first])
        } else if !snapshot.follow, first < snapshot.offset || last >= snapshot.offset + snapshot.rows.count {
            pageOffset = max(0, first - 20)
            refresh()
        }
    }

    func saveFilter() { send("save_filter", ["name": filterName]); filterName = ""; savePresented = false }

    func applySettings(_ config: LogcatConfig) {
        do {
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
            let value = try JSONSerialization.jsonObject(with: encoder.encode(config))
            send("settings", ["config": value])
            settingsPresented = false
        } catch { self.error = error.localizedDescription }
    }

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "logcat.log"
        panel.allowedContentTypes = [.plainText]
        panel.begin { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            Task { @MainActor in self?.send("export", ["path": path]) }
        }
    }
}
