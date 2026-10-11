import Foundation
import Observation

@MainActor @Observable
final class DeviceStore {
    private(set) var devices: [AndroidDevice] = []
    private(set) var error: String?
    private(set) var refreshing = false
    private(set) var connecting = false
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var connection: Task<Void, Never>?

    func start() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }

    func stop() { poll?.cancel(); poll = nil; connection?.cancel(); connection = nil }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let paths = try EnginePaths.resolve()
            let result = try await ProcessJob(executable: paths.adb, arguments: ["devices", "-l"], environment: paths.environment, timeout: 12).run()
            guard result.status == 0 else { throw AppFailure(result.output.isEmpty ? "ADB could not list devices" : result.output) }
            devices = AndroidDevice.parse(result.output)
            error = nil
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    func connect(address: String) {
        guard !connecting else { return }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DeviceAddress.isValid(address) else { error = "Enter a device address with a port, such as 192.168.1.20:37001"; return }
        connecting = true
        connection = Task { [weak self] in
            guard let self else { return }
            defer { connecting = false; connection = nil }
            do {
                let paths = try EnginePaths.resolve()
                let result = try await ProcessJob(executable: paths.adb, arguments: ["connect", address], environment: paths.environment, timeout: 15).run()
                // adb connect may return exit 0 even when the connection failed.
                let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard result.status == 0, text.split(separator: "\n").contains(where: { $0.hasPrefix("connected to ") || $0.hasPrefix("already connected to ") }) else { throw AppFailure(text.isEmpty ? "ADB could not connect to this device" : text) }
                await refresh()
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}
