import AppKit
import Foundation
import Observation

@MainActor @Observable
final class MirrorSession: Identifiable {
    enum Phase: Equatable {
        case starting, running, stopping, failed(String)
        var isActive: Bool {
            switch self { case .starting, .running, .stopping: return true; case .failed: return false }
        }
        var label: String {
            switch self { case .starting: return "Opening…"; case .running: return "Mirroring"; case .stopping: return "Stopping…"; case .failed(let message): return message }
        }
    }
    let id = UUID()
    let serial: String
    let job: ProcessJob
    var phase: Phase = .starting
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var deadline: Task<Void, Never>?
    @ObservationIgnored var lines = LineBuffer()
    @ObservationIgnored var lastError: String?
    init(serial: String, job: ProcessJob) { self.serial = serial; self.job = job }
}

@MainActor @Observable
final class SessionManager {
    private(set) var sessions: [String: MirrorSession] = [:]
    private(set) var error: String?
    var activeCount: Int { sessions.values.filter { $0.phase.isActive }.count }

    func open(_ device: AndroidDevice, options: MirrorOptions) {
        guard device.isReady else { return }
        if let existing = sessions[device.serial], existing.phase.isActive { show(device.serial); return }
        do {
            let paths = try EnginePaths.resolve()
            let job = ProcessJob(executable: paths.scrcpy, arguments: options.arguments(serial: device.serial, name: device.name), environment: paths.environment)
            let session = MirrorSession(serial: device.serial, job: job)
            sessions[device.serial] = session
            error = nil
            session.task = Task { [weak self, weak session] in
                guard let self, let session else { return }
                defer { session.deadline?.cancel(); session.deadline = nil; session.task = nil }
                do {
                    let result = try await job.run { [weak self, weak session] data in
                        Task { @MainActor in
                            guard let self, let session, self.sessions[session.serial]?.id == session.id, session.phase.isActive else { return }
                            for line in session.lines.append(data) {
                                if line == "INFO: SCRCPY_MAC_WINDOW_READY", session.phase == .starting {
                                    session.phase = .running
                                    session.deadline?.cancel()
                                } else if line.hasPrefix("ERROR:") { session.lastError = line }
                            }
                        }
                    }
                    guard sessions[device.serial]?.id == session.id else { return }
                    if result.status == 0 { sessions.removeValue(forKey: device.serial) }
                    else { session.phase = .failed(session.lastError ?? result.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(1200).description) }
                } catch is CancellationError {
                    if sessions[device.serial]?.id == session.id { sessions.removeValue(forKey: device.serial) }
                } catch {
                    if sessions[device.serial]?.id == session.id { session.phase = .failed(error.localizedDescription) }
                }
            }
            session.deadline = Task { [weak session] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let session, session.phase == .starting else { return }
                job.cancel(reason: AppFailure("The mirror did not become ready. Check device authorization and use the patched fork engine."))
            }
        } catch { self.error = error.localizedDescription }
    }

    func show(_ serial: String) {
        guard let session = sessions[serial], let pid = session.job.pid, let application = NSRunningApplication(processIdentifier: pid) else { return }
        if !application.activate(options: [.activateAllWindows]) { error = "macOS could not focus the mirror window" }
    }

    func stop(_ serial: String) {
        guard let session = sessions[serial] else { return }
        if !session.phase.isActive { sessions.removeValue(forKey: serial); return }
        session.phase = .stopping
        session.deadline?.cancel()
        session.task?.cancel()
    }

    func stopAll() async {
        let owned = Array(sessions.values)
        for session in owned { stop(session.serial) }
        for session in owned { await session.task?.value }
        sessions.removeAll()
    }
}
