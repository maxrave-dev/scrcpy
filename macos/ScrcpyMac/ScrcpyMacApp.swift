import AppKit
import SwiftUI

@main
struct ScrcpyMacApp {
    @MainActor static func main() {
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
        guard device.isReady else { return }
        if let logcat, let logcatStore {
            logcatStore.chooseDevice(device.serial)
            logcat.makeKeyAndOrderFront(nil)
            return
        }
        do {
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
        } catch {
            let alert = NSAlert()
            alert.messageText = "Cannot open Logcat"
            alert.informativeText = error.localizedDescription
            if let manager { alert.beginSheetModal(for: manager) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        quitting = true
        devices.stop()
        Task {
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
