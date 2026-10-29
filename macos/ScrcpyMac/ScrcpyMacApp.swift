import AppKit
import SwiftUI

@main
struct ScrcpyMacApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--mcp") { exit(MCPBridge.run(arguments: CommandLine.arguments)) }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let devices = DeviceStore()
    private let sessions = SessionManager()
    private var manager: NSWindow?
    private var logcat: NSWindow?
    private var logcatStore: LogcatStore?
    private var quitting = false
    private let adbTools = ADBTools()
    private var mcp: MCPUnixServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 590), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "scrcpy"
        window.minSize = NSSize(width: 760, height: 450)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let restored = window.setFrameUsingName("scrcpy.manager")
        window.setFrameAutosaveName("scrcpy.manager")
        window.contentView = NSHostingView(rootView: ManagerView(devices: devices, sessions: sessions, openLogcat: { [weak self] in self?.openLogcat($0) }))
        if !restored { window.center() }
        manager = window
        showManager()
        // A device back after a dropped connection gets its mirror reopened and its Logcat restarted.
        sessions.devices = devices
        devices.onReconnect = { [weak self] serial in self?.logcatStore?.restart(serial: serial) }
        devices.start()
        startMCP()
    }

    @objc private func showManager() {
        manager?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showManager(); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === manager { sender.orderOut(nil); return false }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === logcat {
            logcatStore?.close()
            logcatStore = nil
            logcat = nil
        }
    }

    private func openLogcat(_ device: AndroidDevice) {
        do { _ = try prepareLogcat(device) }
        catch {
            let alert = NSAlert()
            alert.messageText = "Cannot open Logcat"
            alert.informativeText = error.localizedDescription
            if let manager { alert.beginSheetModal(for: manager) }
        }
    }

    private func prepareLogcat(_ device: AndroidDevice) throws -> LogcatStore {
        guard device.isReady else { throw AppFailure("Device is not ready") }
        if let logcat, let logcatStore {
            logcatStore.chooseDevice(device.serial)
            logcat.makeKeyAndOrderFront(nil)
            return logcatStore
        }
        let paths = try EnginePaths.resolve()
        // The reused Rust backend reads ADB from the host environment.
        setenv("ADB", paths.adb.path, 1)
        let store = LogcatStore(serial: device.serial)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "scrcpy · Logcat"
        window.minSize = NSSize(width: 900, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let restored = window.setFrameUsingName("scrcpy.logcat")
        window.setFrameAutosaveName("scrcpy.logcat")
        window.contentView = NSHostingView(rootView: LogcatView(store: store))
        if !restored { window.center() }
        logcatStore = store
        logcat = window
        window.makeKeyAndOrderFront(nil)
        return store
    }

    private func startMCP() {
        let appTools = AppTools(devices: devices, sessions: sessions)
        appTools.logcat = { [weak self] in self?.logcatStore }
        appTools.openLogcat = { [weak self] device in
            guard let self else { throw AppFailure("App is shutting down") }
            return try self.prepareLogcat(device)
        }
        appTools.closeLogcat = { [weak self] in self?.logcat?.performClose(nil) }
        appTools.showManager = { [weak self] in self?.showManager() }
        appTools.quit = { NSApp.terminate(nil) }
        appTools.window = { [weak self] arguments in
            guard let self else { throw AppFailure("App is shutting down") }
            return try self.windowAction(arguments)
        }
        let adb = adbTools
        let server = MCPUnixServer(tools: AppToolCatalog.tools + ADBToolCatalog.tools, handler: { name, arguments, context in
            if name.hasPrefix("app_") { return try await appTools.call(name, arguments, context) }
            return try await adb.call(name, arguments, context)
        }, disconnect: { owner in await adb.close(owner: owner) })
        do { try server.start(); mcp = server }
        catch { fputs("scrcpy MCP unavailable: \(error.localizedDescription)\n", stderr) }
    }

    private func windowAction(_ a: [String: Any]) throws -> [String: Any] {
        let name = a.text("window", default: "manager")
        guard let window = name == "manager" ? manager : logcat else { throw AppFailure("Window is not open; open Logcat first if needed") }
        switch a.text("action", default: "get") {
        case "show", "focus": window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        case "hide": window.orderOut(nil)
        case "close": window.performClose(nil)
        case "minimize": window.miniaturize(nil)
        case "restore": window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
        case "move":
            guard let x = a["x"] as? NSNumber, let y = a["y"] as? NSNumber else { throw AppFailure("move requires x and y") }
            window.setFrameOrigin(NSPoint(x: x.doubleValue, y: y.doubleValue))
        case "resize":
            guard a["width"] != nil, a["height"] != nil else { throw AppFailure("resize requires width and height") }
            var frame = window.frame
            frame.size = NSSize(width: max(window.minSize.width, CGFloat(a.int("width"))), height: max(window.minSize.height, CGFloat(a.int("height"))))
            window.setFrame(frame, display: true)
        default: break
        }
        return ["window": name, "visible": window.isVisible, "minimized": window.isMiniaturized,
                "frame": ["x": window.frame.minX, "y": window.frame.minY, "width": window.frame.width, "height": window.frame.height]]
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        quitting = true
        mcp?.stop(); mcp = nil
        devices.stop()
        Task {
            await adbTools.close()
            await sessions.stopAll()
            await logcatStore?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func installMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "scrcpy")
        let about = NSMenuItem(title: "About scrcpy", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(about)
        applicationMenu.addItem(.separator())
        let show = NSMenuItem(title: "Show devices", action: #selector(showManager), keyEquivalent: "1")
        show.target = self
        applicationMenu.addItem(show)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(NSMenuItem(title: "Quit scrcpy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (name, selector, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { editMenu.addItem(NSMenuItem(title: name, action: selector, keyEquivalent: key)) }
        edit.submenu = editMenu; menu.addItem(edit)
        let windows = NSMenuItem()
        let windowsMenu = NSMenu(title: "Window")
        windowsMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windows.submenu = windowsMenu; menu.addItem(windows)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowsMenu
    }
}
