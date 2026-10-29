import Foundation
import Observation

@MainActor @Observable
final class DeviceStore {
    enum ConnectStatus: Equatable {
        case idle, connecting(String), connected(String), failed(String)
    }

    private(set) var devices: [AndroidDevice] = []
    private(set) var error: String?
    private(set) var refreshing = false
    // Shared with the existing manager sheet; MCP never receives a PIN.
    var unlockTarget: AndroidDevice?
    // Kept apart from `error`, which every 3-second poll clears.
    private(set) var connectStatus = ConnectStatus.idle
    var connecting: Bool {
        if case .connecting = connectStatus { return true }
        return false
    }
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var connection: Task<ConnectStatus, Never>?
    @ObservationIgnored private var lastConnectResult = ConnectStatus.idle
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var transports: [String: String] = [:]
    @ObservationIgnored private var stopped = false

    /// A device whose connection dropped; its row stays listed with the progress until it is back.
    struct Reconnection: Equatable {
        let device: AndroidDevice
        var status: String
        var failed = false
    }
    static let reconnectDelays = [2, 4, 8]
    private(set) var reconnecting: [String: Reconnection] = [:]
    @ObservationIgnored private var reconnects: [String: Task<Bool, Never>] = [:]
    @ObservationIgnored private var readyWiFi: [String: AndroidDevice] = [:]
    /// Called once a dropped device is back, so open tools such as Logcat can resume.
    @ObservationIgnored var onReconnect: ((String) -> Void)?

    func start() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }

    func stop() {
        stopped = true
        poll?.cancel(); poll = nil; connection?.cancel(); connection = nil
        reconnects.values.forEach { $0.cancel() }
    }

    /// Returns once a device listing that started after the call has finished; false if it failed.
    @discardableResult
    func refresh() async -> Bool {
        // The listing in flight may predate the caller's change (such as adb connect):
        // ask it to list once more and wait for that.
        guard !refreshing else {
            refreshAgain = true
            return await withCheckedContinuation { refreshWaiters.append($0) }
        }
        refreshing = true
        var listedOK = false
        defer {
            refreshing = false
            let waiters = refreshWaiters
            refreshWaiters = []
            waiters.forEach { $0.resume(returning: listedOK) }
        }
        repeat {
            refreshAgain = false
            do {
                let paths = try EnginePaths.resolve()
                let result = try await ProcessJob(executable: paths.adb, arguments: ["devices", "-l"], environment: paths.environment, timeout: 12).run()
                guard result.status == 0 else { throw AppFailure(result.output.isEmpty ? "ADB could not list devices" : result.output) }
                let listed = AndroidDevice.parse(result.output)
                let ready = Set(listed.filter(\.isReady).map(\.serial))
                let current = AndroidDevice.transportIDs(result.output)
                if !stopped {
                    // A Wi-Fi device that was ready and is now gone or offline dropped its connection.
                    for (serial, device) in readyWiFi where !ready.contains(serial) { startReconnect(device) }
                    // A new transport id means ADB reconnected between two polls; streams on the old one ended.
                    for (serial, id) in current where ready.contains(serial) && reconnects[serial] == nil && transports[serial].map({ $0 != id }) == true { onReconnect?(serial) }
                }
                transports = current
                readyWiFi = Dictionary(listed.filter { $0.isReady && $0.connection == "Wi-Fi" }.map { ($0.serial, $0) }, uniquingKeysWith: { first, _ in first })
                // A failed reconnect is over once the device is back another way, e.g. Connect over Wi-Fi.
                for serial in reconnecting.keys where ready.contains(serial) && reconnects[serial] == nil {
                    reconnecting[serial] = nil
                    onReconnect?(serial)
                }
                devices = listed + reconnecting.values.filter { dropped in !listed.contains { $0.serial == dropped.device.serial } }
                    .sorted { $0.device.serial < $1.device.serial }
                    .map { AndroidDevice(serial: $0.device.serial, state: "reconnecting", model: $0.device.model) }
                error = nil
                listedOK = true
            } catch is CancellationError {
                return false
            } catch { self.error = error.localizedDescription; listedOK = false }
        } while refreshAgain
        return listedOK
    }

    func connect(address input: String) {
        guard !connecting else { return }
        let address = DeviceAddress.normalized(input)
        guard DeviceAddress.isValid(address) else { connectStatus = .failed("Enter the IP address and port from Wireless debugging, such as 192.168.1.20:37001."); lastConnectResult = connectStatus; return }
        connectStatus = .connecting(address)
        connection = Task { [weak self] in
            guard let self else { return .idle }
            defer { lastConnectResult = connectStatus; connection = nil }
            do {
                let paths = try EnginePaths.resolve()
                let result = try await ProcessJob(executable: paths.adb, arguments: ["connect", address], environment: paths.environment, timeout: 15).run()
                // adb connect may return exit 0 even when the connection failed.
                let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard result.status == 0, text.split(separator: "\n").contains(where: { $0.hasPrefix("connected to ") || $0.hasPrefix("already connected to ") }) else { throw AppFailure(text.isEmpty ? "ADB could not connect to \(address)" : text) }
                await refresh()
                try Task.checkCancellation()
                connectStatus = .connected(address)
            } catch is CancellationError {
                connectStatus = .idle
            } catch { connectStatus = .failed(error.localizedDescription) }
            return connectStatus
        }
    }

    func cancelConnect() { connection?.cancel() }

    /// The UI clears connectStatus after showing its success banner; retain the actual outcome.
    func finishConnect() async -> ConnectStatus {
        if let connection { return await connection.value }
        return lastConnectResult
    }

    func clearConnectStatus() { if !connecting { connectStatus = .idle } }

    /// Brings a dropped device back, waiting 2, 4 and 8 seconds before the attempts: ADB often
    /// recovers by itself, otherwise a Wi-Fi device gets a fresh `adb connect`. Callers share one run.
    @discardableResult
    func reconnect(_ device: AndroidDevice) async -> Bool {
        await startReconnect(device).value
    }

    /// Drops the row of a device whose reconnect failed.
    func forget(_ serial: String) {
        guard reconnects[serial] == nil else { return }
        reconnecting[serial] = nil
        devices.removeAll { $0.serial == serial && $0.state == "reconnecting" }
    }

    @discardableResult
    private func startReconnect(_ device: AndroidDevice) -> Task<Bool, Never> {
        if let running = reconnects[device.serial] { return running }
        // Quitting: no new attempts that would outlive the app's shutdown.
        guard !stopped else { return Task { false } }
        let delays = Self.reconnectDelays
        func waiting(_ attempt: Int) -> String { "Connection lost. Reconnecting in \(delays[attempt]) s (attempt \(attempt + 1) of \(delays.count))…" }
        // Set before the task runs, so this refresh already keeps the row.
        reconnecting[device.serial] = Reconnection(device: device, status: waiting(0))
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            defer { reconnects[device.serial] = nil }
            for (attempt, delay) in delays.enumerated() {
                reconnecting[device.serial] = Reconnection(device: device, status: waiting(attempt))
                do { try await Task.sleep(for: .seconds(delay)) } catch { reconnecting[device.serial] = nil; return false }
                reconnecting[device.serial]?.status = "Reconnecting (attempt \(attempt + 1) of \(delays.count))…"
                if await isBack(device) {
                    reconnecting[device.serial] = nil
                    onReconnect?(device.serial)
                    return true
                }
                if Task.isCancelled { reconnecting[device.serial] = nil; return false }
            }
            let tried = delays.map { "\($0) s" }.joined(separator: ", ")
            reconnecting[device.serial] = Reconnection(device: device, status: "Connection lost. \(delays.count) reconnect attempts (\(tried)) failed.", failed: true)
            return false
        }
        reconnects[device.serial] = task
        return task
    }

    /// One reconnect attempt; true once the device is listed ready again.
    private func isBack(_ device: AndroidDevice) async -> Bool {
        // A failed listing leaves the old list in place, which would still show the device ready.
        func ready(_ listed: Bool) -> Bool { listed && devices.contains { $0.serial == device.serial && $0.isReady } }
        if ready(await refresh()) { return true }
        guard device.connection == "Wi-Fi", let paths = try? EnginePaths.resolve() else { return false }
        // An offline transport often keeps failing until it is dropped and connected afresh.
        if devices.contains(where: { $0.serial == device.serial && $0.state == "offline" }) {
            _ = try? await ProcessJob(executable: paths.adb, arguments: ["disconnect", device.serial], environment: paths.environment, timeout: 10).run()
        }
        _ = try? await ProcessJob(executable: paths.adb, arguments: ["connect", device.serial], environment: paths.environment, timeout: 15).run()
        // A fresh connection passes through connecting/authorizing before it is ready.
        for _ in 0..<3 where !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            if ready(await refresh()) { return true }
        }
        return false
    }

    enum Key: String {
        case wakeUp = "KEYCODE_WAKEUP", sleep = "KEYCODE_SLEEP", volumeUp = "KEYCODE_VOLUME_UP", volumeDown = "KEYCODE_VOLUME_DOWN"
    }

    /// Turns the screen off. Whether the secure lock engages at once or after the device's lock
    /// timeout is a device setting, so the result says which happened.
    func lock(_ device: AndroidDevice) async throws -> String {
        try await retrying(device) { try await shell(device, "input keyevent \(Key.sleep.rawValue)") }
        try await Task.sleep(for: .milliseconds(700))
        let locked = LockScreen.isLocked(trustDump: try await retrying(device) { try await read(device, "dumpsys trust | grep deviceLocked=") })
        return locked == true ? "\(device.name) is locked" : "\(device.name) screen is off"
    }

    /// Presses a hardware key, as the device's own button would.
    func press(_ key: Key, on device: AndroidDevice) async throws {
        try await shell(device, "input keyevent \(key.rawValue)")
    }

    /// Turns the screen on without unlocking it.
    func wake(_ device: AndroidDevice) async throws {
        try await retrying(device) { try await shell(device, "input keyevent \(Key.wakeUp.rawValue)") }
    }

    /// Wakes the device, swipes up its lock screen and types the PIN. The swipe, PIN and Enter
    /// are sent only while the lock screen holds focus on display 0 (an app would be scrolled or
    /// typed into), the PIN only while a secure lock is reported; a short race remains (face unlock).
    func unlock(_ device: AndroidDevice, pin: String, progress: @escaping (String) -> Void = { _ in }) async throws -> String {
        let unlocked = "\(device.name) is unlocked"
        let info = try await retrying(device) { try await read(device, "input keyevent KEYCODE_WAKEUP; getprop ro.build.version.sdk; wm size") }
        guard let screen = LockScreen.screenSize(wmSize: info) else { throw AppFailure("\(device.name) did not report its screen size, so nothing was swiped.") }
        // Android 10+ can target display 0, the display whose focus is checked.
        let sdk = info.split(separator: "\n").lazy.compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.first ?? 0
        let input = sdk >= 29 ? "input -d 0" : "input"
        try await Task.sleep(for: .milliseconds(300))
        let state = try await lockScreen(device)
        guard let locked = state.locked else {
            throw AppFailure("The screen is on, but \(device.name) does not report whether it is locked, so the PIN was not typed. Unlock it on the device.")
        }
        guard state.focused == true else {
            if !locked { return unlocked }
            throw AppFailure("\(device.name) shows \(state.window ?? "no window") instead of its lock screen, so nothing was swiped or typed.")
        }
        if locked, !LockScreen.isValidPIN(pin) { throw AppFailure("\(device.name) is locked. Enter its PIN (4–16 digits).") }
        // From the lower middle: clear of the navigation bar and the lock screen shortcuts.
        try await sendInput(device, "\(input) swipe \(screen.width / 2) \(screen.height * 3 / 4) \(screen.width / 2) \(screen.height / 4) 250")
        guard locked else { return unlocked }
        // The lock screen and its PIN pad share one window, so focus cannot tell when the pad is up.
        try await Task.sleep(for: .milliseconds(500))
        guard try await waitForPINPad(device) else { return unlocked }
        try await sendInput(device, "\(input) text \(pin)")
        progress("PIN sent. Confirming that \(device.name) unlocked…")
        // Some phones (Samsung) drop ADB right as they unlock; the checks wait for it to come back.
        let reconnecting = { progress("PIN sent. \(device.name) dropped its connection; waiting for it to come back…") }
        do {
            // PIN auto-confirm unlocks without Enter; an extra Enter would reach the unlocked app.
            if try await waitUntilUnlocked(device, within: .milliseconds(1200), onRetry: reconnecting) { return unlocked }
            let beforeEnter = try await lockScreen(device, onRetry: reconnecting)
            if beforeEnter.locked == false { return unlocked }
            guard beforeEnter.locked == true, beforeEnter.focused == true else {
                throw AppFailure("\(device.name) left the lock screen before Enter, so Enter was not pressed. Check the device screen.")
            }
            try await sendInput(device, "\(input) keyevent KEYCODE_ENTER")
            if try await waitUntilUnlocked(device, within: .milliseconds(2500), onRetry: reconnecting) { return unlocked }
        } catch is ConnectionLost {
            throw AppFailure("The PIN was sent, but \(device.name) dropped its connection before the unlock could be confirmed. Check the device screen.")
        }
        throw AppFailure("\(device.name) is still locked. Check the PIN on the device screen.")
    }

    /// Waits until the PIN pad can take the PIN. Returns false if the device unlocked meanwhile.
    private func waitForPINPad(_ device: AndroidDevice) async throws -> Bool {
        var window: String?
        for check in 0..<8 {
            if check > 0 { try await Task.sleep(for: .milliseconds(250)) }
            let state = try await lockScreen(device)
            guard let locked = state.locked else { throw AppFailure("\(device.name) stopped reporting whether it is locked, so the PIN was not typed.") }
            if !locked { return false }
            if state.focused == true { return true }
            window = state.window
        }
        throw AppFailure("\(device.name) did not show its PIN pad (focus: \(window ?? "none")), so the PIN was not typed.")
    }

    /// Polls by time rather than by count, so a slow Wi-Fi round trip does not stretch the wait.
    private func waitUntilUnlocked(_ device: AndroidDevice, within limit: Duration, onRetry: (() -> Void)? = nil) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        repeat {
            try await Task.sleep(for: .milliseconds(250))
            if LockScreen.isLocked(trustDump: try await retrying(device, onRetry: onRetry) { try await read(device, "dumpsys trust | grep deviceLocked=") }) == false { return true }
        } while clock.now < deadline
        return false
    }

    /// Reads the secure-lock state and display 0's focused window in one round trip.
    private func lockScreen(_ device: AndroidDevice, onRetry: (() -> Void)? = nil) async throws -> (locked: Bool?, focused: Bool?, window: String?) {
        let output = try await retrying(device, onRetry: onRetry) { try await read(device, "dumpsys trust | grep deviceLocked=; dumpsys window displays | grep -E 'Display: mDisplayId=|mCurrentFocus='") }
        return (LockScreen.isLocked(trustDump: output), LockScreen.keyguardHasFocus(windowDump: output), LockScreen.focusedWindow(windowDump: output))
    }

    /// Runs an operation that is safe to repeat (a read, a wake or sleep key) again after a dropped
    /// connection, waiting through the reconnect attempts (2 + 4 + 8 s).
    private func retrying<T>(_ device: AndroidDevice, onRetry: (() -> Void)? = nil, _ operation: () async throws -> T) async throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(Self.reconnectDelays.reduce(2, +)))
        while true {
            do { return try await operation() }
            catch is ConnectionLost where clock.now < deadline {
                onRetry?()
                // While reconnect attempts run (they can outlast the window), wait for them instead.
                if let running = reconnects[device.serial] { _ = await running.value }
                else { try await Task.sleep(for: .milliseconds(500)) }
                try Task.checkCancellation()
            }
        }
    }

    /// For input that must not repeat: after a dropped connection it may already have reached the
    /// device (a second PIN would count as a wrong attempt), so the lock-state checks that follow decide.
    private func sendInput(_ device: AndroidDevice, _ command: String) async throws {
        do { try await shell(device, command) }
        catch is ConnectionLost {}
    }

    /// Runs a read-only command and returns its output. The command ends by echoing a marker: when
    /// it arrives, the output is whole, even if the transport dropped before adb got the exit status
    /// (a Samsung does this as it unlocks). Without it, the connection dropped mid-command.
    private static let doneMarker = "__SCRCPY_MAC_DONE__"

    private func read(_ device: AndroidDevice, _ command: String) async throws -> String {
        let paths = try EnginePaths.resolve()
        let result = try await ProcessJob(executable: paths.adb, arguments: ["-s", device.serial, "shell", "\(command); echo \(Self.doneMarker)"], environment: paths.environment, timeout: 10).run()
        guard let end = result.output.range(of: Self.doneMarker, options: .backwards) else {
            throw ConnectionLost(device: device.name, detail: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(result.output[..<end.lowerBound])
    }

    /// Runs an input command. The marker is echoed only after the command succeeded on the device,
    /// so it proves the command ran even when the transport dropped before adb got the exit status.
    /// Without it, the command's own error text is reported; a silent failure means adb lost the
    /// transport mid-command (a Samsung does this as it unlocks).
    private func shell(_ device: AndroidDevice, _ command: String) async throws {
        let paths = try EnginePaths.resolve()
        let result = try await ProcessJob(executable: paths.adb, arguments: ["-s", device.serial, "shell", "\(command) && echo \(Self.doneMarker)"], environment: paths.environment, timeout: 10).run()
        if result.output.contains(Self.doneMarker) { return }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || ADBMessage.isConnectionLoss(text) { throw ConnectionLost(device: device.name, detail: text) }
        throw AppFailure(text)
    }
}
