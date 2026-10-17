import AppKit
import SwiftUI
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let prefs = Preferences()
    private let log = TimeLog()
    private lazy var categories = Categories(directory: log.directory)
    private lazy var model = TimerModel(minutes: prefs.lastMinutes)

    private var statusItem: StatusItemController!
    private var panel: TimerPanelController!
    private var floating: FloatingTimerController!
    private var settings: SettingsWindowController!
    private var timesheet: TimesheetWindowController!
    private var timesheetIcon: TimesheetStatusItem?
    private var shortcuts: ShortcutsWindowController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()

        if Snapshots.outputDirectory != nil { Snapshots.seedDemoData(into: log) }
        model.recorder = log

        statusItem = StatusItemController(model: model, prefs: prefs, log: log)
        panel = TimerPanelController(model: model, prefs: prefs, log: log)
        floating = FloatingTimerController(model: model, prefs: prefs, log: log)
        settings = SettingsWindowController(prefs: prefs, log: log)
        timesheet = TimesheetWindowController(log: log, categories: categories)
        shortcuts = ShortcutsWindowController(prefs: prefs)
        shortcuts.onCustomize = { [weak self] in self?.openSettings() }

        statusItem.onOpenPanel = { [weak self] in
            guard let self else { return }
            self.panel.toggle(below: self.statusItem.button)
        }
        statusItem.onShowFloating = { [weak self] in self?.floating.show() }
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItem.onOpenTimesheet = { [weak self] in self?.openTimesheet() }

        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        panel.onOpenTimesheet = { [weak self] in self?.openTimesheet() }
        panel.onToggleFloating = { [weak self] in self?.perform(.floating) }
        panel.onShowShortcuts = { [weak self] in self?.shortcuts.show() }
        statusItem.onShowShortcuts = { [weak self] in self?.shortcuts.show() }
        timesheet.onShowShortcuts = { [weak self] in self?.shortcuts.toggle() }
        settings.onShowShortcuts = { [weak self] in self?.shortcuts.show() }
        settings.onOpenTimesheet = { [weak self] in self?.openTimesheet() }
        panel.onVisibilityChange = { [weak self] visible in self?.statusItem.setHighlighted(visible) }

        model.onDurationChange = { [weak self] minutes in self?.prefs.lastMinutes = minutes }
        model.onStart = { [weak self] in
            guard let self, self.prefs.floatingOnStart else { return }
            self.floating.show()
        }
        model.onFinish = { [weak self] in
            guard let self else { return }
            Completion.timerFinished(minutes: self.model.minutes, prefs: self.prefs)
            if self.prefs.floatingOnFinish { self.floating.show() }
        }

        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
            if prefs.showNotification { Completion.requestNotificationPermission() }
        }

        observeSleepAndLock()
        quitGracefullyOnSIGTERM()

        HotkeyCenter.shared.setHandler { [weak self] action in self?.perform(action) }
        prefs.$hotkeysEnabled
            .combineLatest(prefs.$hotkeys)
            .sink { enabled, hotkeys in
                // Snapshot runs sit alongside your real copy; don't steal its shortcuts.
                let active = enabled && Snapshots.outputDirectory == nil
                HotkeyCenter.shared.register(active ? hotkeys.compactMapValues { $0 } : [:])
            }
            .store(in: &cancellables)

        prefs.$timesheetMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] show in self?.setTimesheetIconVisible(show) }
            .store(in: &cancellables)

        if Snapshots.outputDirectory != nil { runSnapshots() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Log whatever is running so quitting never loses time.
        model.stop()
    }

    /// `pkill`, `make run` and logout send SIGTERM, which would otherwise kill
    /// the app without logging the running session. Route it through a normal quit.
    private var sigtermSource: DispatchSourceSignal?

    private func quitGracefullyOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigtermSource = source
    }

    /// A stopwatch left running overnight would wreck the timesheet, so pause it
    /// on sleep. Locking alone keeps it running by default (stepping out for lunch).
    private func observeSleepAndLock() {
        func pause(when enabled: @escaping @MainActor (Preferences) -> Bool) -> @Sendable (Notification) -> Void {
            { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, enabled(self.prefs), self.model.isCountingUp else { return }
                    self.model.pause()
                }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main,
                                                          using: pause { $0.pauseCountUpOnSleep })
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main,
                                                            using: pause { $0.pauseCountUpOnLock })
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .togglePanel:
            panel.toggle(below: statusItem.button)
        case .startPause:
            model.toggle()
        case .countUp:
            model.startCountUp()
        case .stop:
            model.stop()
        case .timesheet:
            if timesheet.isFrontmost { timesheet.close() } else { openTimesheet() }
        case .floating:
            if floating.isVisible { floating.close() } else { floating.show() }
        }
    }

    private func setTimesheetIconVisible(_ visible: Bool) {
        if visible, timesheetIcon == nil {
            timesheetIcon = TimesheetStatusItem { [weak self] in self?.openTimesheet() }
        } else if !visible {
            timesheetIcon?.remove()
            timesheetIcon = nil
        }
    }

    private func openTimesheet() {
        panel.close()
        timesheet.show()
    }

    private func runSnapshots() {
        let menuBar = NSColor(white: 0.2, alpha: 1)
        Snapshots.capture(StatusItemController.image(text: "45:00", boxed: true, alpha: 0.5), name: "1-menubar-idle", background: menuBar)
        Snapshots.capture(StatusItemController.image(text: "29:41", boxed: true, alpha: 1), name: "1-menubar-running", background: menuBar)

        model.setMinutes(45)
        log.currentTask = "Write Q4 planning doc"
        panel.show(below: statusItem.button)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            Snapshots.capture(panel.panelWindow, name: "2-panel-idle")
            log.currentTask = "e"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            Snapshots.capture(panel.panelWindow, name: "2b-panel-suggestions")
            log.currentTask = "Write Q4 planning doc"
            model.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [self] in
                Snapshots.capture(panel.panelWindow, name: "3-panel-running")
                panel.close()
                floating.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                    Snapshots.capture(floating.window, name: "4-floating", background: .white)
                    settings.show()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                        if let window = NSApp.windows.first(where: { $0.title == "Pomodoro Settings" }) {
                            Snapshots.capture(window, name: "5-settings", background: .white)
                        }
                        timesheet.show()
                        // Borderless offscreen copy, tall enough to include the session log.
                        let tall = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 920, height: 1500),
                                            styleMask: .borderless, backing: .buffered, defer: false)
                        tall.contentView = NSHostingView(rootView: TimesheetView(state: TimesheetState(log: log, categories: categories), log: log, categories: categories))
                        tall.orderFrontRegardless()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                            if let window = timesheet.nsWindow {
                                Snapshots.capture(window, name: "6-timesheet", background: .white)
                            }
                            Snapshots.capture(tall, name: "7-timesheet-full", background: .white)
                            tall.orderOut(nil)
                            shortcuts.show()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                                if let window = shortcuts.nsWindow {
                                    Snapshots.capture(window, name: "8-shortcuts", background: .white)
                                }
                                model.stop()
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
            }
        }
    }

    private func openSettings() {
        panel.close()
        settings.show()
    }

    // Show the banner even though we're technically the "active" app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Accessory apps have no visible menu bar, but this gives the settings
    /// window working ⌘W / ⌘Q and copy/paste in text fields.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Pomodoro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        return main
    }
}
