// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct LogcatView: View {
    @Bindable var store: LogcatStore
    @Environment(\.colorScheme) private var scheme
    @FocusState private var queryFocused: Bool

    var body: some View {
        let palette = AppPalette(scheme)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("Logcat").font(.system(size: 24, weight: .semibold))
                    if let snapshot = store.snapshot {
                        Picker("Device", selection: Binding(get: { snapshot.serial }, set: store.chooseDevice)) {
                            ForEach(snapshot.devices) { device in Text(device.name).tag(device.serial) }
                        }.labelsHidden().frame(maxWidth: 260)
                        Spacer()
                        Button(snapshot.paused ? "Resume" : "Pause", action: store.pause).buttonStyle(PillButton())
                        Button("Follow", action: store.follow).buttonStyle(PillButton(prominent: snapshot.follow))
                        Button("Copy", action: store.copySelected).buttonStyle(PillButton()).keyboardShortcut("c", modifiers: .command)
                    } else { Spacer(); ProgressView().controlSize(.small) }
                    Menu {
                        Button("Settings…") { store.settingsPresented = true }
                        Button("History & saved filters…") { store.historyPresented = true }
                        Button("Save current filter…") { store.savePresented = true }
                        Button("Export matched entries…", action: store.export)
                        Divider()
                        Button("Clear this view") { store.send("clear_view") }
                        Button("Clear device logcat buffer…", role: .destructive) { store.confirmClearDevice = true }
                        Button("Restart stream") { store.send("restart") }
                        Divider()
                        Button("Filter help") { store.helpPresented = true }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28)
                }
                HStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(palette.muted)
                    TextField("Filter: package:mine & level:WARN", text: $store.query).textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).focused($queryFocused).onSubmit { store.applyQuery() }
                    Button("Apply") { store.applyQuery() }.buttonStyle(PillButton())
                    Button { queryFocused = true } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain).keyboardShortcut("f", modifiers: .command).help("Focus filter")
                    Button { store.historyPresented = true } label: { Image(systemName: "clock") }.buttonStyle(.plain).help("Query history")
                }.padding(12).background(palette.surface, in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).stroke(palette.line, lineWidth: 1))
                if let error = store.error ?? store.snapshot?.queryError { Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled) }
                HStack(spacing: 7) {
                    ForEach(store.snapshot?.tabs ?? []) { tab in
                        Button("\(tab.name)  \(tab.count)") { store.chooseTab(tab.index) }.buttonStyle(PillButton(prominent: store.snapshot?.active == tab.index))
                    }
                    Button { store.send("new_tab") } label: { Image(systemName: "plus") }.buttonStyle(.plain).keyboardShortcut("t", modifiers: .command).help("New filter tab")
                    Button { store.send("close_tab") } label: { Image(systemName: "xmark") }.buttonStyle(.plain).disabled((store.snapshot?.tabs.count ?? 0) < 2).help("Close filter tab")
                    Spacer()
                }
            }.padding(22)
            Divider()
            LogcatTable(store: store).frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if let snapshot = store.snapshot {
                    Text("\(snapshot.matched.formatted()) matched / \(snapshot.buffered.formatted()) buffered").font(.system(size: 11, design: .monospaced))
                    if snapshot.paused { Text("Paused — buffer keeps filling").font(.system(size: 11)) }
                    Spacer()
                    Text(snapshot.status).font(.system(size: 11)).lineLimit(1)
                    if snapshot.config.showHints { Text("⌘F filter · ⌘T tab · ⌘C copy").font(.system(size: 11, design: .monospaced)) }
                } else { Text("Starting Logcat…").font(.system(size: 12)); Spacer() }
            }.foregroundStyle(palette.muted).padding(.horizontal, 20).padding(.vertical, 12)
        }.foregroundStyle(palette.ink).background(palette.background).accentColor(palette.ink)
            .sheet(isPresented: $store.settingsPresented) {
                if let config = store.snapshot?.config { LogcatSettings(config: config, apply: store.applySettings, cancel: { store.settingsPresented = false }) }
            }
            .sheet(isPresented: $store.historyPresented) { history(palette) }
            .sheet(isPresented: $store.savePresented) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Save filter").font(.title2.weight(.semibold))
                    TextField("Filter name", text: $store.filterName).textFieldStyle(.roundedBorder).onSubmit { if !store.filterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { store.saveFilter() } }
                    HStack { Spacer(); Button("Cancel") { store.savePresented = false }; Button("Save", action: store.saveFilter).disabled(store.filterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }.padding(26).frame(width: 420)
            }
            .sheet(isPresented: $store.helpPresented) { help }
            .alert("Clear device logcat buffer?", isPresented: $store.confirmClearDevice) {
                Button("Cancel", role: .cancel) {}
                Button("Clear device buffer", role: .destructive) { store.send("clear_device") }
            } message: { Text("This deletes the selected logcat buffers on the Android device. Clearing this view alone does not delete device logs.") }
    }

    private func history(_ palette: AppPalette) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("History & saved filters").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.snapshot?.config.saved ?? [], id: \.name) { filter in
                        Button { store.applyQuery(filter.query); store.historyPresented = false } label: { VStack(alignment: .leading, spacing: 4) { Text("★ \(filter.name)"); Text(filter.query).font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.muted) }.frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                    }
                    Divider()
                    ForEach(store.snapshot?.config.history ?? [], id: \.self) { query in
                        Button { store.applyQuery(query); store.historyPresented = false } label: { Text(query).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                    }
                }
            }
            HStack { Spacer(); Button("Close") { store.historyPresented = false } }
        }.padding(26).frame(width: 560, height: 430)
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The same filters as termlog").font(.title2.weight(.semibold))
            Text("tag: · package: · process: · message: · line: · level: · age: · is: · name:").font(.system(size: 12, design: .monospaced))
            Text("Use & / | and parentheses. A leading - excludes. = matches exactly, ~ matches regex. Whitespace joins terms; repeated positive keys are OR-ed, repeated exclusions are AND-ed.").font(.system(size: 13))
            Text("package:mine & level:WARN\n-tag~:Choreographer|OpenGLRenderer\npackage:mine & is:crash\ntag:OkHttp & -message:heartbeat & age:5m").font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
            Text("package:mine means third-party apps on the device. Clicking an entry copies its complete message, including a stack trace. Pause stops the view, not collection.").font(.system(size: 13))
            HStack { Spacer(); Button("Close") { store.helpPresented = false } }
        }.padding(28).frame(width: 600)
    }
}

private struct LogcatSettings: View {
    @State var config: LogcatConfig
    let apply: (LogcatConfig) -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Logcat settings").font(.title2.weight(.semibold))
            Form {
                Section("Columns") {
                    Toggle("Date", isOn: $config.columns.date); Toggle("Time", isOn: $config.columns.time)
                    Toggle("PID–TID", isOn: $config.columns.pid); Toggle("Level", isOn: $config.columns.level)
                    Toggle("Tag", isOn: $config.columns.tag); Toggle("Package", isOn: $config.columns.package)
                }
                Toggle("Soft wrap", isOn: $config.softWrap)
                Toggle("Show keyboard hints", isOn: $config.showHints)
                Picker("Buffer capacity", selection: $config.bufferSize) {
                    ForEach(Array(Set([50_000, 100_000, 250_000, 500_000, 1_000_000, config.bufferSize])).sorted(), id: \.self) { value in Text("\(value.formatted()) entries").tag(value) }
                }
                TextField("Logcat buffers", text: $config.buffers)
                Text("Changing buffers restarts collection. Settings and saved filters use termlog’s existing configuration file.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            HStack { Spacer(); Button("Cancel", action: cancel); Button("Apply") { apply(config) } }
        }.padding(25).frame(width: 480, height: 600)
    }
}
