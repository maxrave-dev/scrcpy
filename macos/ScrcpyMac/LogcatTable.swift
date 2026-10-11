// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

/// NSTableView virtualizes the complete matched index. Only a 200-entry viewport
/// crosses the Rust bridge; a 250k-entry ring never becomes 250k SwiftUI views.
struct LogcatTable: NSViewRepresentable {
    let store: LogcatStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = LogScrollView()
        let table = LogTableView()
        table.headerView = NSTableHeaderView()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.onClick = { [weak coordinator = context.coordinator] row in coordinator?.copyClicked(row) }
        table.onKey = { [weak coordinator = context.coordinator] in coordinator?.key($0) ?? false }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.table = table
        context.coordinator.scroll = scroll
        scroll.onUserScroll = { [weak coordinator = context.coordinator] in coordinator?.visibleChanged(user: true) }
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.visibleChanged(user: false) }
        }
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update() }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let store: LogcatStore
        weak var table: NSTableView?
        weak var scroll: NSScrollView?
        var observer: NSObjectProtocol?
        private var applying = false
        private var rows: [Int: LogcatRow] = [:]
        private var columns: LogcatConfig.Columns?
        private var activeTab: Int?
        init(store: LogcatStore) { self.store = store }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        func update() {
            guard let snapshot = store.snapshot, let table else { return }
            applying = true
            defer { applying = false }
            if columns != snapshot.config.columns {
                columns = snapshot.config.columns
                for column in table.tableColumns { table.removeTableColumn(column) }
                let c = snapshot.config.columns
                let definitions: [(String, String, CGFloat, Bool)] = [("date", "Date", 92, c.date), ("time", "Time", 110, c.time), ("pid", "PID–TID", 90, c.pid), ("level", "Level", 44, c.level), ("tag", "Tag", 165, c.tag), ("package", "Package", 180, c.package), ("message", "Message", 500, true)]
                for (id, title, width, enabled) in definitions where enabled {
                    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                    column.title = title; column.width = width; column.minWidth = 35
                    table.addTableColumn(column)
                }
            }
            rows = Dictionary(uniqueKeysWithValues: snapshot.rows.enumerated().map { (snapshot.offset + $0.offset, $0.element) })
            let visible = table.rows(in: table.visibleRect)
            let changedTab = activeTab != snapshot.active
            activeTab = snapshot.active
            table.reloadData()
            if snapshot.selected < snapshot.matched {
                table.selectRowIndexes(IndexSet(integer: snapshot.selected), byExtendingSelection: false)
            }
            if snapshot.follow && snapshot.matched > 0 { table.scrollRowToVisible(snapshot.matched - 1) }
            else if changedTab && snapshot.matched > 0 { table.scrollRowToVisible(snapshot.offset) }
            else if visible.location != NSNotFound && visible.location < snapshot.matched { table.scrollRowToVisible(visible.location) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { store.snapshot?.matched ?? 0 }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn else { return nil }
            let identifier = column.identifier
            let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? cell(identifier)
            let entry = rows[row]
            let key = identifier.rawValue
            let value: String
            switch key {
            case "date": value = entry?.date ?? ""
            case "time": value = entry?.time ?? ""
            case "pid": value = entry.map { "\($0.pid)–\($0.tid)" } ?? ""
            case "level": value = entry?.level ?? ""
            case "tag": value = entry?.tag ?? ""
            case "package": value = entry?.package ?? ""
            default: value = entry?.message ?? ""
            }
            field.textField?.stringValue = value
            field.textField?.lineBreakMode = store.snapshot?.config.softWrap == true && key == "message" ? .byWordWrapping : .byClipping
            let dark = tableView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = LogcatPalette.rgb(column: key, level: entry?.level ?? "", tag: entry?.tag ?? "", dark: dark)
            field.textField?.textColor = NSColor(calibratedRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
            field.textField?.font = .monospacedSystemFont(ofSize: 12, weight: key == "level" ? .semibold : .regular)
            return field
        }

        private func cell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView(); cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.maximumNumberOfLines = 0
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text); cell.textField = text
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), text.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4), text.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -4)])
            return cell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard let entry = rows[row] else { return 25 }
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            if store.snapshot?.config.softWrap == true, let column = tableView.tableColumns.last {
                let bounds = (entry.message as NSString).boundingRect(with: NSSize(width: max(50, column.width - 10), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
                return max(25, ceil(bounds.height) + 8)
            }
            return max(25, CGFloat(entry.message.components(separatedBy: "\n").count) * 16 + 8)
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { MonoLogRow() }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table, let row = rows[table.selectedRow] else { return }
            store.select(row)
        }
        func copyClicked(_ index: Int) {
            guard let row = rows[index] else { return }
            store.select(row, copy: true)
        }
        func visibleChanged(user: Bool) {
            guard !applying, let table else { return }
            let range = table.rows(in: table.visibleRect)
            guard range.location != NSNotFound, range.length > 0 else { return }
            store.visibleRowsChanged(first: range.location, last: NSMaxRange(range) - 1, userScrolled: user)
        }
        func key(_ event: NSEvent) -> Bool {
            guard let characters = event.charactersIgnoringModifiers else { return false }
            let command = event.modifierFlags.contains(.command)
            switch characters {
            case "c" where command, "y": store.copySelected()
            case " ": store.pause()
            case "f": store.follow()
            case "c": store.send("clear_view")
            case "C": store.confirmClearDevice = true
            case "w": if var config = store.snapshot?.config { config.softWrap.toggle(); store.applySettings(config) }
            case ",": store.settingsPresented = true
            case "h": store.historyPresented = true
            case "s": store.savePresented = true
            case "e": store.export()
            case "?": store.helpPresented = true
            case "t": store.send("new_tab")
            case "x": store.send("close_tab")
            default: return false
            }
            return true
        }
    }
}

// Stable colors are shared by the level letter and complete message. Tag
// identity uses the same UTF-8 FNV-1a / ten-color palette as termlog's theme.rs.
// Light counterparts keep text contrast instead of reusing pale dark colors.
enum LogcatPalette {
    private static let levels: [String: (dark: UInt32, light: UInt32)] = [
        "V": (0xA1A7B4, 0x586474), "D": (0x73D9FF, 0x006B8F),
        "I": (0x75E5A0, 0x197D44), "W": (0xFFD166, 0x926000),
        "E": (0xFF758F, 0xC23850), "A": (0xE5A0FF, 0x8245AA)
    ]
    private static let tags: [(dark: UInt32, light: UInt32)] = [
        (0x5FD7D7, 0x087F88), (0x87D787, 0x387F43),
        (0xAF87D7, 0x8052A8), (0xAFD787, 0x697A23),
        (0xD7875F, 0xA35324), (0x87AFD7, 0x436DA0),
        (0xD7AF87, 0x946025), (0x87AF5F, 0x547528),
        (0xAFAFD7, 0x6A63A2), (0x87D7AF, 0x287B5B)
    ]

    static func rgb(column: String, level: String, tag: String, dark: Bool) -> UInt32 {
        switch column {
        case "date", "time", "pid": return dark ? 0x8E96A5 : 0x686F7C
        case "tag":
            var hash: UInt32 = 2_166_136_261
            for byte in tag.utf8 { hash ^= UInt32(byte); hash = hash &* 16_777_619 }
            let color = tags[Int(hash) % tags.count]
            return dark ? color.dark : color.light
        case "level", "message":
            if let color = levels[level] { return dark ? color.dark : color.light }
            return dark ? 0xC0C7D4 : 0x515865
        default: return dark ? 0xC0C7D4 : 0x515865
        }
    }
}

private final class MonoLogRow: NSTableRowView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isSelected { NSColor.labelColor.withAlphaComponent(0.06).setFill(); dirtyRect.fill() }
    }
}

private final class LogScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?
    override func scrollWheel(with event: NSEvent) { super.scrollWheel(with: event); onUserScroll?() }
}

private final class LogTableView: NSTableView {
    var onClick: ((Int) -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    override func mouseDown(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        if index >= 0 { onClick?(index) }
    }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
}
