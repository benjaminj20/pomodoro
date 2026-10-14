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

    /// Space/Return start-pause, U counts up, arrows nudge the time, Esc closes,
    /// ⌘T opens the timesheet, ⌘, opens settings.
    private func handleKey(_ key: KeyPress) -> Bool {
        let flags = key.flags
        if flags.contains(.command) {
            switch key.characters {
            case ",": close(); onOpenSettings?(); return true
            case "q": NSApp.terminate(nil); return true
            case "w": close(); return true
            case "t": close(); onOpenTimesheet?(); return true
            default: return false
            }
        }
        // While typing a task, leave keys to the text field (it handles Return itself).
        if panel.firstResponder is NSTextView {
            if key.keyCode == 53 { close(); return true }
            return false
        }
        let step = flags.contains(.shift) ? 5 : 1
        switch key.keyCode {
        case 53: // esc
            close()
        case 36, 76, 49: // return, enter, space
            let wasIdle = !model.isActive
            model.toggle()
            if wasIdle { didStart() }
        case 123, 125: // left, down
            model.setMinutes(max(1, model.minutes - step))
        case 124, 126: // right, up
            model.setMinutes(min(prefs.sliderMaxMinutes, model.minutes + step))
        case 51, 117: // delete
            model.stop()
        case 32: // u
            model.startCountUp()
            didStart()
        default:
            // 1–9 pick a preset by position.
            if let digit = key.characters.flatMap(Int.init), digit >= 1, digit <= prefs.presets.count {
                model.setMinutes(prefs.presets[digit - 1])
                return true
            }
            return false
        }
        return true
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
