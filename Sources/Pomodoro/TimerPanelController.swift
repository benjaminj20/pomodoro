import AppKit
import SwiftUI

/// Borderless panel that can take keyboard focus without activating the app.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The dropdown that appears under the menu bar item: slider, presets, start/stop.
@MainActor
final class TimerPanelController: NSObject, NSWindowDelegate {
    var onOpenSettings: (() -> Void)?
    var onOpenTimesheet: (() -> Void)?
    var onToggleFloating: (() -> Void)?
    var onShowShortcuts: (() -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?

    private let model: TimerModel
    private let prefs: Preferences
    private let log: TimeLog
    private let state = PanelState()
    private var panel: KeyablePanel!
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    static let size = NSSize(width: 272, height: 178)
    private static let cornerRadius: CGFloat = 16

    var isVisible: Bool { panel.isVisible }
    var panelWindow: NSWindow { panel }

    init(model: TimerModel, prefs: Preferences, log: TimeLog) {
        self.model = model
        self.prefs = prefs
        self.log = log
        super.init()
        panel = makePanel()
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .vibrantDark)
        blur.maskImage = Self.roundedMask(radius: Self.cornerRadius)

        let view = PanelView(
            model: model,
            prefs: prefs,
            log: log,
            state: state,
            onStart: { [weak self] in self?.didStart() },
            onOpenSettings: { [weak self] in
                self?.close()
                self?.onOpenSettings?()
            },
            onOpenTimesheet: { [weak self] in
                self?.close()
                self?.onOpenTimesheet?()
            },
            onShowShortcuts: { [weak self] in
                self?.close()
                self?.onShowShortcuts?()
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = blur.bounds
        hosting.autoresizingMask = [.width, .height]
        blur.addSubview(hosting)

        panel.contentView = blur
        return panel
    }

    // MARK: - Show / hide

    func toggle(below button: NSStatusBarButton?) {
        if panel.isVisible { close() } else { show(below: button) }
    }

    func show(below button: NSStatusBarButton?) {
        model.acknowledgeFinish()
        position(below: button)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        installMonitors()
        onVisibilityChange?(true)
        // Ready to type what you're about to work on.
        if prefs.focusTaskOnOpen && !model.isActive {
            DispatchQueue.main.async { self.state.focusRequest += 1 }
        }
    }

    func close() {
        guard panel.isVisible else { return }
        removeMonitors()
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        onVisibilityChange?(false)
    }

    private func didStart() {
        if prefs.closePanelOnStart { close() }
    }

    private func position(below button: NSStatusBarButton?) {
        guard let button, let buttonWindow = button.window else {
            panel.center()
            return
        }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var origin = NSPoint(
            x: buttonRect.minX - 4,
            y: buttonRect.minY - Self.size.height - 6
        )
        // Keep fully on screen.
        origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - Self.size.width - 6)
        panel.setFrameOrigin(origin)
    }

    // MARK: - Event monitors

    private func installMonitors() {
        removeMonitors()
        // Any click in another app closes the panel, like a native popover.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let key = KeyPress(event)
            let handled = MainActor.assumeIsolated { self.panel.isKeyWindow && self.handleKey(key) }
            return handled ? nil : event
        }
    }

    private func removeMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }

    /// Everything in the panel works from the keyboard:
    /// - typing goes to the task field (focused on open); ↩ starts a countdown,
    ///   ⌘↩ counts up, ↑/↓ cycle recent tasks, ⇥ leaves the field
    /// - outside the field: space start/pause, U count up, ⌫ stop, ←/→ minutes,
    ///   1–8 presets, F floating timer, ? shortcuts, ⇥ back to the task field
    /// - anywhere: ⌘1–8 presets, ⌘T timesheet, ⌘/ shortcuts, ⌘, settings, esc close
    private func handleKey(_ key: KeyPress) -> Bool {
        let flags = key.flags
        let isEditing = panel.firstResponder is NSTextView

        if flags.contains(.command) {
            if key.keyCode == 36 || key.keyCode == 76 { // ⌘↩
                startCountUp()
                return true
            }
            if let digit = key.characters.flatMap(Int.init), selectPreset(digit) { return true }
            switch key.characters {
            case ",": close(); onOpenSettings?(); return true
            case "q": NSApp.terminate(nil); return true
            case "w": close(); return true
            case "t": close(); onOpenTimesheet?(); return true
            case "/": close(); onShowShortcuts?(); return true
            default: return false // ⌘C/⌘V/⌘A etc. go to the field
            }
        }

        if isEditing, handleSuggestionKey(key) { return true }

        if key.keyCode == 53 { // esc
            close()
            return true
        }
        if key.keyCode == 48 { // tab: in and out of the task field
            if isEditing { panel.makeFirstResponder(nil) } else { state.focusRequest += 1 }
            return true
        }

        // While typing a task, leave keys to the field (it handles ↩ itself),
        // except ↑/↓ which cycle through recent tasks.
        if isEditing {
            switch key.keyCode {
            case 126: cycleRecentTask(-1); return true
            case 125: cycleRecentTask(1); return true
            default: return false
            }
        }

        let step = flags.contains(.shift) ? 5 : 1
        switch key.keyCode {
        case 36, 76, 49: // return, enter, space
            let wasIdle = !model.isActive
            model.toggle()
            if wasIdle { didStart() }
        case 123, 125: // left, down
            model.setMinutes(max(1, model.minutes - step))
        case 124, 126: // right, up
            model.setMinutes(min(prefs.sliderMaxMinutes, model.minutes + step))
        case 51, 117: // delete: stop and get ready to type the next task
            model.stop()
            state.focusRequest += 1
        default:
            switch key.characters?.lowercased() {
            case "u": startCountUp()
            case "f": onToggleFloating?()
            case "?": close(); onShowShortcuts?()
            case "s": // also start/pause, for people who think "s for start"
                let wasIdle = !model.isActive
                model.toggle()
                if wasIdle { didStart() }
            default:
                if let digit = key.characters.flatMap(Int.init), selectPreset(digit) { return true }
                return false
            }
        }
        return true
    }

    private func startCountUp() {
        panel.makeFirstResponder(nil)
        model.startCountUp()
        didStart()
    }

    private func selectPreset(_ number: Int) -> Bool {
        guard number >= 1, number <= prefs.presets.count else { return false }
        model.setMinutes(prefs.presets[number - 1])
        return true
    }

    /// While suggestions are showing under the task field: ↓/↑ move through
    /// them, ↩ takes the highlighted one (with none highlighted it starts as
    /// usual), ⇥ takes the highlighted or top one, esc hides them.
    private func handleSuggestionKey(_ key: KeyPress) -> Bool {
        guard key.flags.isDisjoint(with: [.command, .control, .option]) else { return false }
        let suggestions = state.suggestions(in: log)
        guard !suggestions.isEmpty else { return false }
        let query = log.currentTask
        let highlighted = state.highlightedIndex(for: query, count: suggestions.count)

        switch key.keyCode {
        case 125: // down
            state.highlight = (query, min((highlighted ?? -1) + 1, suggestions.count - 1))
        case 126: // up: past the top goes back to just your text
            if let highlighted { state.highlight = highlighted > 0 ? (query, highlighted - 1) : nil }
        case 36, 76: // return, enter
            guard let highlighted else { return false }
            state.accept(suggestions[highlighted], in: log)
        case 48: // tab
            state.accept(suggestions[highlighted ?? 0], in: log)
        case 53: // esc
            state.dismissedQuery = query
            state.highlight = nil
        default:
            return false
        }
        return true
    }

    /// ↑ goes back through recent tasks (newest first), ↓ comes forward.
    private func cycleRecentTask(_ direction: Int) {
        let recent = log.recentTasks()
        guard !recent.isEmpty else { return }
        let current = recent.firstIndex { TimeLog.key($0) == TimeLog.key(log.currentTask) }
        let next: Int
        if let current {
            next = current - direction
        } else {
            next = direction < 0 ? 0 : recent.count - 1
        }
        guard recent.indices.contains(next) else { return }
        log.currentTask = recent[next]
    }

    /// Sendable snapshot of a key event.
    private struct KeyPress: Sendable {
        let keyCode: UInt16
        let characters: String?
        let flags: NSEvent.ModifierFlags

        init(_ event: NSEvent) {
            keyCode = event.keyCode
            characters = event.charactersIgnoringModifiers
            flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: - Helpers

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
