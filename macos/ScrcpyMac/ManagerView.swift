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
    func makeBody(configuration: Configuration) -> some View {
        let palette = AppPalette(scheme)
        configuration.label.font(.system(size: 13, weight: .medium)).padding(.horizontal, 17).padding(.vertical, 10)
            .foregroundStyle(prominent ? palette.background : palette.ink)
            .background(prominent ? palette.ink : palette.surface, in: Capsule())
            .overlay(Capsule().stroke(prominent ? Color.clear : palette.line, lineWidth: 1))
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
    private var options: MirrorOptions { MirrorOptions(maxSize: maxSize, audio: audio, onTop: onTop) }

    var body: some View {
        let palette = AppPalette(scheme)
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Devices").font(.system(size: 27, weight: .semibold))
                    Text("\(devices.devices.count) connected, \(sessions.activeCount) mirroring").font(.system(size: 13)).foregroundStyle(palette.muted)
                }
                Spacer()
                Button { Task { await devices.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Refresh devices").disabled(devices.refreshing)
                Button("Connect over Wi-Fi") { wifiPresented = true }.buttonStyle(PillButton())
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
            .sheet(isPresented: $wifiPresented) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Connect over Wi-Fi").font(.system(size: 23, weight: .semibold))
                    Text("Use the connection address from Wireless debugging on a device already paired with this Mac. Pairing setup is not included yet.").font(.system(size: 13)).foregroundStyle(palette.muted)
                    TextField("192.168.1.20:37001", text: $address).textFieldStyle(.roundedBorder).onSubmit(connect)
                    HStack { Spacer(); Button("Cancel") { wifiPresented = false }.buttonStyle(PillButton()); Button("Connect", action: connect).buttonStyle(PillButton(prominent: true)).disabled(!DeviceAddress.isValid(address.trimmingCharacters(in: .whitespacesAndNewlines)) || devices.connecting) }
                }.padding(28).frame(width: 420).background(palette.background)
            }
    }

    private func settingLabel(_ title: String, _ palette: AppPalette) -> some View {
        Text(title).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted)
    }

    private func deviceRow(_ device: AndroidDevice, palette: AppPalette) -> some View {
        let session = sessions.sessions[device.serial]
        return HStack(spacing: 23) {
            RoundedRectangle(cornerRadius: 5).stroke(palette.muted, lineWidth: 1).frame(width: 29, height: 51).overlay(alignment: .bottom) { Capsule().fill(palette.muted).frame(width: 11, height: 1).padding(.bottom, 5) }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(device.name).font(.system(size: 21, weight: .semibold)).lineLimit(1)
                Text("\(device.connection.lowercased())   \(device.serial)").font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.muted).lineLimit(1).textSelection(.enabled)
                if let session { Text(session.phase.label).font(.system(size: 12)).foregroundStyle(palette.muted).lineLimit(3).textSelection(.enabled) }
                else if !device.isReady { Text(device.explanation).font(.system(size: 12)).foregroundStyle(palette.muted) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Button("Logcat") { openLogcat(device) }.buttonStyle(PillButton()).disabled(!device.isReady)
                if let session, session.phase.isActive {
                    Button("Show window") { sessions.show(device.serial) }.buttonStyle(PillButton()).disabled(session.phase != .running)
                    Button("Stop") { sessions.stop(device.serial) }.buttonStyle(PillButton()).disabled(session.phase == .stopping)
                } else {
                    Button("Open mirror") { sessions.open(device, options: options) }.buttonStyle(PillButton(prominent: true)).disabled(!device.isReady)
                }
            }
        }.padding(24).background(palette.surface, in: RoundedRectangle(cornerRadius: 23)).overlay(RoundedRectangle(cornerRadius: 23).stroke(palette.line, lineWidth: 1))
    }

    private func connect() {
        guard DeviceAddress.isValid(address.trimmingCharacters(in: .whitespacesAndNewlines)), !devices.connecting else { return }
        devices.connect(address: address)
        wifiPresented = false
    }
}
