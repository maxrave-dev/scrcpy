import SwiftUI

struct AppPalette {
    let background, surface, soft, ink, muted, line: Color
    init(_ scheme: ColorScheme) {
        func gray(_ value: Double) -> Color { Color(white: value) }
        let dark = scheme == .dark
        background = gray(dark ? 0.145 : 0.96)
        surface = gray(dark ? 0.192 : 1)
        soft = gray(dark ? 0.23 : 0.92)
        ink = gray(dark ? 0.95 : 0.125)
        muted = gray(dark ? 0.67 : 0.47)
        line = gray(dark ? 0.27 : 0.875)
    }
}

struct PillButton: ButtonStyle {
    var prominent = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        let palette = AppPalette(scheme)
        configuration.label.font(.system(size: 13, weight: .medium)).lineLimit(1).padding(.horizontal, 17).padding(.vertical, 10)
            .foregroundStyle(prominent ? palette.background : palette.ink)
            .background(prominent ? palette.ink : palette.surface, in: Capsule())
            .overlay(Capsule().stroke(prominent ? Color.clear : palette.line, lineWidth: 1))
            // A custom style is not dimmed automatically; a disabled button must not look clickable.
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.65 : 1)
    }
}

/// One part of a split pill; the enclosing capsule draws the background and the disabled dimming.
struct SegmentButton: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).lineLimit(1).frame(minWidth: 16, minHeight: 16).padding(.horizontal, 8).padding(.vertical, 10)
            .foregroundStyle(AppPalette(scheme).ink).contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct MonoSwitch: View {
    @Binding var value: Bool
    var label: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let palette = AppPalette(scheme)
        Button { value.toggle() } label: {
            Capsule().fill(value ? palette.ink : palette.line).frame(width: 40, height: 22)
                .overlay(alignment: value ? .trailing : .leading) { Circle().fill(palette.background).frame(width: 16, height: 16).padding(3) }
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(value ? "On" : "Off")
    }
}

struct ManagerView: View {
    @Bindable var devices: DeviceStore
    @Bindable var sessions: SessionManager
    let openLogcat: (AndroidDevice) -> Void
    @AppStorage("mirror.maxSize") private var maxSize = 0
    @AppStorage("mirror.audio") private var audio = true
    @AppStorage("mirror.onTop") private var onTop = false
    @Environment(\.colorScheme) private var scheme
    @State private var wifiPresented = false
    @State private var address = ""
    // The id restarts the 5-second timer even when the same text is shown again.
    private struct Notice: Equatable { let id = UUID(); let text: String; var failure = false }
    @State private var notice: Notice?
    @State private var manualRefresh = false
    private var options: MirrorOptions { MirrorOptions(maxSize: maxSize, audio: audio, onTop: onTop) }

    var body: some View {
        let palette = AppPalette(scheme)
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Devices").font(.system(size: 27, weight: .semibold))
                    Text("\(devices.devices.filter { $0.state != "reconnecting" }.count) connected, \(sessions.activeCount) mirroring").font(.system(size: 13)).foregroundStyle(palette.muted)
                }
                Spacer()
                Button(action: refreshNow) {
                    Group {
                        if manualRefresh { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }.frame(width: 18, height: 18)
                }.buttonStyle(.plain).help("Refresh devices").disabled(manualRefresh)
                Button("Connect over Wi-Fi") { devices.clearConnectStatus(); wifiPresented = true }.buttonStyle(PillButton())
            }
            if let current = notice {
                Label { Text(current.text) } icon: {
                    Image(systemName: current.failure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(current.failure ? .red : .green)
                }
                    .font(.system(size: 12, weight: .medium)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(palette.soft, in: RoundedRectangle(cornerRadius: 14))
                    .task(id: current.id) {
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        if notice?.id == current.id { notice = nil }
                    }
            }
            if let error = devices.error ?? sessions.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(palette.soft, in: RoundedRectangle(cornerRadius: 14))
            }
            ScrollView {
                LazyVStack(spacing: 14) {
                    if devices.devices.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Connect an Android device").font(.system(size: 20, weight: .semibold))
                            Text("Enable USB debugging, plug in the device, then allow this Mac on the device screen.").foregroundStyle(palette.muted)
                            Text("Already paired wirelessly? Use Connect over Wi-Fi.").font(.system(size: 13)).foregroundStyle(palette.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(28).background(palette.surface, in: RoundedRectangle(cornerRadius: 23))
                    }
                    ForEach(devices.devices) { device in deviceRow(device, palette: palette) }
                }.padding(.vertical, 1)
            }
            HStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Mirror defaults").font(.system(size: 14, weight: .semibold))
                    Text("For new windows").font(.system(size: 12)).foregroundStyle(palette.muted)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 9) {
                    settingLabel("resolution", palette)
                    Picker("Resolution", selection: $maxSize) {
                        Text("Device native").tag(0); Text("1080p").tag(1080); Text("720p").tag(720)
                    }.labelsHidden().pickerStyle(.menu).frame(width: 145)
                }
                VStack(alignment: .leading, spacing: 11) { settingLabel("audio", palette); MonoSwitch(value: $audio, label: "Mirror audio") }
                VStack(alignment: .leading, spacing: 11) { settingLabel("on top", palette); MonoSwitch(value: $onTop, label: "Keep new mirrors on top") }
            }.padding(22).background(palette.soft, in: RoundedRectangle(cornerRadius: 23))
            Text("⌥ drag to move   /   ⌥ edge-drag to resize").font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted)
        }.padding(28).foregroundStyle(palette.ink).background(palette.background).accentColor(palette.ink)
            // Closing the sheet any way, including Esc, cancels a running connection.
            .sheet(isPresented: $wifiPresented, onDismiss: { devices.cancelConnect(); devices.clearConnectStatus() }) { wifiSheet(palette) }
            .sheet(item: $devices.unlockTarget) { device in UnlockSheet(device: device, devices: devices) { notice = Notice(text: $0) } }
            .onChange(of: devices.connectStatus) { _, status in
                guard case .connected(let target) = status else { return }
                notice = Notice(text: "Connected to \(target)")
                wifiPresented = false
                devices.clearConnectStatus()
            }
    }

    private func wifiSheet(_ palette: AppPalette) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect over Wi-Fi").font(.system(size: 23, weight: .semibold))
            Text("Use the connection address from Wireless debugging on a device already paired with this Mac. Without a port, 5555 (adb tcpip) is used. Pairing setup is not included yet.").font(.system(size: 13)).foregroundStyle(palette.muted)
            TextField("192.168.1.20:37001", text: $address).textFieldStyle(.roundedBorder).onSubmit(connect).disabled(devices.connecting)
            switch devices.connectStatus {
            case .connecting(let target):
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Connecting to \(target)…") }.font(.system(size: 12)).foregroundStyle(palette.muted)
            case .failed(let message):
                Text(message).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            case .idle, .connected:
                EmptyView()
            }
            HStack {
                Spacer()
                Button("Cancel") { wifiPresented = false }.buttonStyle(PillButton())
                Button("Connect", action: connect).buttonStyle(PillButton(prominent: true)).disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || devices.connecting)
            }
        }.padding(28).frame(width: 420).foregroundStyle(palette.ink).background(palette.background)
            .onChange(of: address) { if case .failed = devices.connectStatus { devices.clearConnectStatus() } }
    }

    private func settingLabel(_ title: String, _ palette: AppPalette) -> some View {
        Text(title).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted)
    }

    private func deviceRow(_ device: AndroidDevice, palette: AppPalette) -> some View {
        let session = sessions.sessions[device.serial]
        let dropped = devices.reconnecting[device.serial]
        return HStack(spacing: 23) {
            RoundedRectangle(cornerRadius: 5).stroke(palette.muted, lineWidth: 1).frame(width: 29, height: 51).overlay(alignment: .bottom) { Capsule().fill(palette.muted).frame(width: 11, height: 1).padding(.bottom, 5) }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(device.name).font(.system(size: 21, weight: .semibold)).lineLimit(1)
                Text("\(device.connection.lowercased())   \(device.serial)").font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.muted).lineLimit(1).textSelection(.enabled)
                if let session {
                    // While reconnecting, the attempt countdown says more than the generic phase.
                    let countdown = session.phase == .reconnecting ? dropped?.status : nil
                    Text(countdown.map { "\($0) The mirror reopens once it is back." } ?? session.phase.label).font(.system(size: 12)).foregroundStyle(palette.muted).lineLimit(3).textSelection(.enabled)
                }
                else if !device.isReady { Text(dropped?.status ?? device.explanation).font(.system(size: 12)).foregroundStyle(dropped?.failed == true ? .red : palette.muted).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                // After failed attempts the row must stay actionable, also when its mirror failed with it.
                if let dropped, dropped.failed, session?.phase.isActive != true {
                    Button("Forget") { sessions.stop(device.serial); devices.forget(device.serial) }.buttonStyle(PillButton())
                    Button("Reconnect") {
                        if session != nil { sessions.retry(dropped.device) } else { Task { await devices.reconnect(dropped.device) } }
                    }.buttonStyle(PillButton(prominent: true))
                } else {
                    Button("Logcat") { openLogcat(device) }.buttonStyle(PillButton()).disabled(!device.isReady)
                    deviceKeys(device, palette: palette)
                    if let session, session.phase.isActive {
                        Button("Show window") { sessions.show(device.serial) }.buttonStyle(PillButton()).disabled(session.phase != .running)
                        Button("Stop") { sessions.stop(device.serial) }.buttonStyle(PillButton()).disabled(session.phase == .stopping)
                    } else {
                        Button("Open mirror") { sessions.open(device, options: options) }.buttonStyle(PillButton(prominent: true)).disabled(!device.isReady)
                    }
                }
            }
            // Keeps every pill at its full width; the name column truncates instead.
            .fixedSize()
        }.padding(24).background(palette.surface, in: RoundedRectangle(cornerRadius: 23)).overlay(RoundedRectangle(cornerRadius: 23).stroke(palette.line, lineWidth: 1))
    }

    /// Unlock, Lock and volume down/up as one split pill, about as wide as separate Unlock and
    /// volume pills were, so the row's IP stays readable at the default window width.
    private func deviceKeys(_ device: AndroidDevice, palette: AppPalette) -> some View {
        HStack(spacing: 0) {
            Button("Unlock") { devices.unlockTarget = device }.help("Wake the screen and enter the PIN")
            Rectangle().fill(palette.line).frame(width: 1, height: 16)
            Button(action: { lock(device) }) { Image(systemName: "lock.fill") }.help("Lock (turn the screen off)").accessibilityLabel("Lock")
            Rectangle().fill(palette.line).frame(width: 1, height: 16)
            Button { press(.volumeDown, on: device) } label: { Image(systemName: "speaker.minus.fill") }.help("Volume down").accessibilityLabel("Volume down")
            Rectangle().fill(palette.line).frame(width: 1, height: 16)
            Button { press(.volumeUp, on: device) } label: { Image(systemName: "speaker.plus.fill") }.help("Volume up").accessibilityLabel("Volume up")
        }.buttonStyle(SegmentButton())
            .background(palette.surface, in: Capsule()).overlay(Capsule().stroke(palette.line, lineWidth: 1))
            .disabled(!device.isReady).opacity(device.isReady ? 1 : 0.4)
    }

    private func lock(_ device: AndroidDevice) {
        Task {
            do { notice = Notice(text: try await devices.lock(device)) }
            catch is CancellationError {}
            catch { notice = Notice(text: error.localizedDescription, failure: true) }
        }
    }

    private func press(_ key: DeviceStore.Key, on device: AndroidDevice) {
        Task {
            do { try await devices.press(key, on: device) }
            catch is CancellationError {}
            catch { notice = Notice(text: error.localizedDescription, failure: true) }
        }
    }

    // The sheet stays open until ADB answers; an invalid address is reported inline.
    private func connect() {
        guard !devices.connecting else { return }
        devices.connect(address: address)
    }

    private func refreshNow() {
        manualRefresh = true
        Task {
            // Listing takes milliseconds; keep the spinner up long enough to be seen.
            async let minimum: Void? = try? Task.sleep(for: .milliseconds(400))
            await devices.refresh()
            _ = await minimum
            manualRefresh = false
        }
    }
}

struct UnlockSheet: View {
    let device: AndroidDevice
    let devices: DeviceStore
    let finished: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var pin = ""
    @State private var working: String?
    @State private var failure: String?
    @State private var job: Task<Void, Never>?

    var body: some View {
        let palette = AppPalette(scheme)
        VStack(alignment: .leading, spacing: 18) {
            Text("Unlock \(device.name)").font(.system(size: 23, weight: .semibold)).lineLimit(1)
            Text("Wakes the screen and types the PIN on the lock screen. The PIN is typed only while the device reports it is locked, and it is never saved.").font(.system(size: 13)).foregroundStyle(palette.muted)
            SecureField("PIN (leave empty for a swipe lock)", text: $pin).textFieldStyle(.roundedBorder).onSubmit { run(unlock: true) }.disabled(working != nil)
                .onChange(of: pin) { _, value in
                    let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(16))
                    if digits != value { pin = digits }
                    failure = nil
                }
            if let working {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(working) }.font(.system(size: 12)).foregroundStyle(palette.muted)
            } else if let failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { job?.cancel(); dismiss() }.buttonStyle(PillButton())
                Button("Wake screen") { run(unlock: false) }.buttonStyle(PillButton()).disabled(working != nil)
                Button("Unlock") { run(unlock: true) }.buttonStyle(PillButton(prominent: true)).disabled(working != nil || !(pin.isEmpty || LockScreen.isValidPIN(pin)))
            }
        }.padding(28).frame(width: 420).foregroundStyle(palette.ink).background(palette.background)
            .onDisappear { job?.cancel() }
    }

    private func run(unlock: Bool) {
        guard working == nil, !unlock || pin.isEmpty || LockScreen.isValidPIN(pin) else { return }
        working = unlock ? "Unlocking \(device.name)…" : "Waking \(device.name)…"
        failure = nil
        let pin = self.pin
        job = Task {
            do {
                let message: String
                if unlock { message = try await devices.unlock(device, pin: pin) { working = $0 } }
                else { try await devices.wake(device); message = "\(device.name) screen is on" }
                self.pin = ""
                finished(message)
                dismiss()
            } catch is CancellationError {
            } catch { failure = error.localizedDescription }
            working = nil
        }
    }
}
