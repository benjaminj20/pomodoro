import AppKit
import Combine

/// Owns the menu bar item: renders the live time and routes clicks.
@MainActor
final class StatusItemController: NSObject {
    var onOpenPanel: (() -> Void)?
    var onShowFloating: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenTimesheet: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: TimerModel
    private let prefs: Preferences
    private let log: TimeLog
    private var cancellables = Set<AnyCancellable>()

    var button: NSStatusBarButton? { statusItem.button }

    init(model: TimerModel, prefs: Preferences, log: TimeLog) {
        self.model = model
        self.prefs = prefs
        self.log = log
        super.init()

        statusItem.behavior = []
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Pomodoro timer")
        }

        // @Published fires on willSet, so hop to the next runloop turn to read new values.
        model.objectWillChange
            .merge(with: prefs.objectWillChange, log.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.render() }
            .store(in: &cancellables)

        render()
    }

    func setHighlighted(_ highlighted: Bool) {
        statusItem.button?.highlight(highlighted)
    }

    // MARK: - Rendering

    private func render() {
        guard let button = statusItem.button else { return }

        let task = TimeLog.clean(log.currentTask)
        if prefs.menuBarShowsTask && model.isActive && !task.isEmpty {
            let short = task.count > 24 ? task.prefix(23) + "…" : Substring(task)
            button.title = String(short)
            button.imagePosition = .imageTrailing
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }

        if model.phase == .idle && prefs.iconWhenIdle {
            let image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Pomodoro")
            image?.isTemplate = true
            button.image = image
            return
        }

        let text = model.isCountingUp
            ? (prefs.menuBarFormat == .clock ? model.clockText : TimeFormatter.compact(model.displaySeconds, roundUp: false))
            : prefs.menuBarFormat.format(model.displaySeconds)
        // Bright while counting down or ringing, dimmed while idle or paused.
        let alpha: CGFloat = (model.phase == .running || model.phase == .finished) ? 1 : 0.5
        button.image = Self.image(text: text, boxed: prefs.menuBarStyle == .boxed, alpha: alpha)
        button.toolTip = toolTip
    }

    private var toolTip: String {
        let task = TimeLog.clean(log.currentTask)
        let status = switch model.phase {
        case .idle: "ready (\(TimeFormatter.clock(model.duration)))"
        case .running: model.mode == .countUp ? "\(model.clockText) elapsed" : "\(model.clockText) left"
        case .paused: "paused"
        case .finished: "done!"
        }
        return task.isEmpty ? "Pomodoro — \(status)" : "\(task) — \(status)"
    }

    /// Draws the time as a template image so it adapts to light/dark menu bars.
    static func image(text: String, boxed: Bool, alpha: CGFloat) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        let color = NSColor.black.withAlphaComponent(alpha)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = (text as NSString).size(withAttributes: attributes)

        let horizontalPadding: CGFloat = boxed ? 6 : 1
        let size = NSSize(width: ceil(textSize.width) + horizontalPadding * 2, height: 17)

        let image = NSImage(size: size, flipped: false) { rect in
            if boxed {
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 4.5, yRadius: 4.5)
                path.lineWidth = 1.5
                color.setStroke()
                path.stroke()
            }
            let origin = NSPoint(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2 + 0.5
            )
            (text as NSString).draw(at: origin, withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Clicks

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
            return
        }

        // ⌥-click performs whichever action isn't the default.
        var action = prefs.menuBarClick
        if event.modifierFlags.contains(.option) {
            action = action == .openPanel ? .toggleTimer : .openPanel
        }

        switch action {
        case .openPanel: onOpenPanel?()
        case .toggleTimer: model.toggle()
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()

        let task = TimeLog.clean(log.currentTask)
        if !task.isEmpty {
            let header = NSMenuItem(title: task, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }

        let toggleTitle = switch model.phase {
        case .idle, .finished: "Start \(TimeFormatter.clock(model.duration))"
        case .running: "Pause"
        case .paused: "Resume"
        }
        menu.addItem(item(toggleTitle, key: "") { [model] in model.toggle() })

        if model.isActive {
            menu.addItem(item("Stop", key: "") { [model] in model.stop() })
        } else {
            menu.addItem(item("Count Up", key: "") { [model] in model.startCountUp() })
        }

        menu.addItem(.separator())

        let presetsItem = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        let presetsMenu = NSMenu()
        for minutes in prefs.presets {
            let entry = item("\(minutes) min", key: "") { [model] in
                model.setMinutes(minutes)
                if !model.isActive { model.start() }
            }
            entry.state = model.minutes == minutes ? .on : .off
            presetsMenu.addItem(entry)
        }
        presetsItem.submenu = presetsMenu
        menu.addItem(presetsItem)

        menu.addItem(item("Open Timer Panel", key: "") { [weak self] in self?.onOpenPanel?() })
        menu.addItem(item("Show Floating Timer", key: "") { [weak self] in self?.onShowFloating?() })

        menu.addItem(.separator())
        menu.addItem(item("Timesheet…", key: "t") { [weak self] in self?.onOpenTimesheet?() })
        menu.addItem(item("Settings…", key: ",") { [weak self] in self?.onOpenSettings?() })
        menu.addItem(item("Quit Pomodoro", key: "q") { NSApp.terminate(nil) })

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    private func item(_ title: String, key: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: key, handler: action)
        return item
    }
}

/// NSMenuItem that runs a closure, so menus can be built inline.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}
