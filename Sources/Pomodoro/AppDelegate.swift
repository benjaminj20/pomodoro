import AppKit
import SwiftUI
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let prefs = Preferences()
    private let log = TimeLog()
    private lazy var model = TimerModel(minutes: prefs.lastMinutes)

    private var statusItem: StatusItemController!
    private var panel: TimerPanelController!
    private var floating: FloatingTimerController!
    private var settings: SettingsWindowController!
    private var timesheet: TimesheetWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()

        if Snapshots.outputDirectory != nil { Snapshots.seedDemoData(into: log) }
        model.recorder = log

        statusItem = StatusItemController(model: model, prefs: prefs, log: log)
        panel = TimerPanelController(model: model, prefs: prefs, log: log)
        floating = FloatingTimerController(model: model, prefs: prefs, log: log)
        settings = SettingsWindowController(prefs: prefs, log: log)
        timesheet = TimesheetWindowController(log: log)

        statusItem.onOpenPanel = { [weak self] in
            guard let self else { return }
            self.panel.toggle(below: self.statusItem.button)
        }
        statusItem.onShowFloating = { [weak self] in self?.floating.show() }
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItem.onOpenTimesheet = { [weak self] in self?.openTimesheet() }

        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        panel.onOpenTimesheet = { [weak self] in self?.openTimesheet() }
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

        if Snapshots.outputDirectory != nil { runSnapshots() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Log whatever is running so quitting never loses time.
        model.stop()
    }

    /// A stopwatch left running overnight would wreck the timesheet, so pause it.
    private func observeSleepAndLock() {
        let pause: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.prefs.pauseCountUpOnSleep, self.model.isCountingUp else { return }
                self.model.pause()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: pause)
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: pause)
    }

    private func openTimesheet() {
        panel.close()
        timesheet.show()
    }

    private func runSnapshots() {
        let menuBar = NSColor(white: 0.2, alpha: 1)
        Snapshots.capture(StatusItemController.image(text: "45:00", boxed: true, alpha: 0.5), name: "1-menubar-idle", background: menuBar)
        Snapshots.capture(StatusItemController.image(text: "29:41", boxed: true, alpha: 1), name: "1-menubar-running", background: menuBar)

        // Put the user's own task/duration back afterwards.
        let savedTask = log.currentTask, savedMinutes = prefs.lastMinutes
        model.setMinutes(45)
        log.currentTask = "Write Q4 planning doc"
        panel.show(below: statusItem.button)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            Snapshots.capture(panel.panelWindow, name: "2-panel-idle")
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
                        tall.contentView = NSHostingView(rootView: TimesheetView(log: log))
                        tall.orderFrontRegardless()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                            if let window = timesheet.nsWindow {
                                Snapshots.capture(window, name: "6-timesheet", background: .white)
                            }
                            Snapshots.capture(tall, name: "7-timesheet-full", background: .white)
                            tall.orderOut(nil)
                            model.stop()
                            log.currentTask = savedTask
                            prefs.lastMinutes = savedMinutes
                            NSApp.terminate(nil)
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
