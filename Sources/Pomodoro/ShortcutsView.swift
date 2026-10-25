import AppKit
import SwiftUI

/// The one place every shortcut is listed. Opened with ? or ⌘/, the keyboard
/// button in the timesheet, or "Keyboard Shortcuts…" in the menus.
@MainActor
final class ShortcutsWindowController: NSObject, NSWindowDelegate {
    private let prefs: Preferences
    private var window: NSWindow?
    private var keyMonitor: Any?
    var onCustomize: (() -> Void)?

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var nsWindow: NSWindow? { window }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        if window == nil {
            let view = ShortcutsView(prefs: prefs) { [weak self] in
                self?.close()
                self?.onCustomize?()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Keyboard Shortcuts"
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.delegate = self
            self.window = window
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func close() {
        window?.orderOut(nil)
        removeKeyMonitor()
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
    }

    /// esc, ? or ⌘/ dismisses it again.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isDismiss = event.keyCode == 53 || event.charactersIgnoringModifiers == "?"
                || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "/")
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.window?.isKeyWindow == true, isDismiss else { return false }
                self.close()
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

struct ShortcutsView: View {
    @ObservedObject var prefs: Preferences
    var onCustomize: () -> Void

    struct Item: Identifiable {
        var keys: [String]
        var action: String
        var id: String { action }
    }

    struct Group: Identifiable {
        var title: String
        var subtitle: String
        var items: [Item]
        var id: String { title }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    Text("Show this anytime with")
                        .foregroundStyle(.secondary)
                    KeyCaps(keys: ["?"])
                    Text("or").foregroundStyle(.secondary)
                    KeyCaps(keys: ["⌘", "/"])
                }
                .font(.system(size: 11.5))
            }

            HStack(alignment: .top, spacing: 28) {
                ForEach(groups) { group in
                    column(group)
                        .frame(width: 250, alignment: .topLeading)
                }
            }

            HStack {
                Text("Global shortcuts work from any app.")
                    .foregroundStyle(.secondary)
                Button("Customize…", action: onCustomize)
                    .buttonStyle(.link)
                Spacer()
                Text("esc to close")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11.5))
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .padding(.bottom, 22)
        .fixedSize()
    }

    private func column(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(group.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(group.items) { item in
                    HStack(alignment: .center, spacing: 10) {
                        Text(item.action)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        KeyCaps(keys: item.keys)
                    }
                }
            }
        }
    }

    // MARK: Content

    private var groups: [Group] {
        [
            Group(title: "Anywhere", subtitle: "Global — even when another app is in front", items: globalItems),
            Group(title: "Timer panel", subtitle: "Type what you're doing, then", items: [
                Item(keys: ["↩"], action: "Start countdown"),
                Item(keys: ["⌘", "↩"], action: "Start counting up"),
                Item(keys: ["↑", "↓"], action: "Suggestions as you type, else recent tasks"),
                Item(keys: ["⇥"], action: "Leave / return to task"),
                Item(keys: ["space"], action: "Start / pause"),
                Item(keys: ["U"], action: "Count up"),
                Item(keys: ["⌫"], action: "Stop and log"),
                Item(keys: ["←", "→"], action: "Minutes −/+ (⇧ for 5)"),
                Item(keys: ["1–8"], action: "Pick a preset"),
                Item(keys: ["F"], action: "Floating timer"),
                Item(keys: ["⌘", "T"], action: "Open timesheet"),
                Item(keys: ["esc"], action: "Close"),
            ]),
            Group(title: "Timesheet", subtitle: "Review and fix your day", items: [
                Item(keys: ["←", "→"], action: "Previous / next day"),
                Item(keys: ["⇧", "←", "→"], action: "Previous / next week"),
                Item(keys: ["T"], action: "Today"),
                Item(keys: ["↑", "↓"], action: "Select an entry"),
                Item(keys: ["↩"], action: "Edit entry"),
                Item(keys: ["⌫"], action: "Delete entry"),
                Item(keys: ["N"], action: "Add entry for the gap"),
                Item(keys: ["R"], action: "Rename task everywhere"),
                Item(keys: ["1–9"], action: "File entry's task in a category"),
                Item(keys: ["0"], action: "Move it to Unsorted"),
                Item(keys: ["W"], action: "Log: day / whole week"),
                Item(keys: ["⌘", "E"], action: "Export week as CSV"),
                Item(keys: ["esc"], action: "Close"),
            ]),
        ]
    }

    /// Reflects whatever the user has set in Settings.
    private var globalItems: [Item] {
        guard prefs.hotkeysEnabled else {
            return [Item(keys: ["off"], action: "Global shortcuts are turned off")]
        }
        return HotkeyAction.allCases.map { action in
            let keys = (prefs.hotkeys[action] ?? nil).map(Self.split) ?? ["—"]
            return Item(keys: keys, action: action.shortTitle)
        }
    }

    /// "⌃⌥P" → ["⌃", "⌥", "P"]
    private static func split(_ hotkey: Hotkey) -> [String] {
        let modifiers = hotkey.display.dropLast(hotkey.key.count).map(String.init)
        return modifiers + [hotkey.key]
    }
}

/// Little rounded key labels: ⌘ / .
struct KeyCaps: View {
    var keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(minWidth: 18)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14))
                    )
            }
        }
        .fixedSize()
    }
}

extension HotkeyAction {
    /// Compact label for the shortcuts sheet.
    var shortTitle: String {
        switch self {
        case .togglePanel: "Timer panel"
        case .startPause: "Start / pause"
        case .countUp: "Count up"
        case .stop: "Stop and log"
        case .timesheet: "Timesheet"
        case .floating: "Floating timer"
        }
    }
}
