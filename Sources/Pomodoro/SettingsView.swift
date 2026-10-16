import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let prefs: Preferences
    private let log: TimeLog
    private var window: NSWindow?
    var onOpenTimesheet: (() -> Void)?
    var onShowShortcuts: (() -> Void)?

    init(prefs: Preferences, log: TimeLog) {
        self.prefs = prefs
        self.log = log
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(
                prefs: prefs,
                log: log,
                onOpenTimesheet: { [weak self] in self?.onOpenTimesheet?() },
                onShowShortcuts: { [weak self] in self?.onShowShortcuts?() }
            ))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Pomodoro Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("SettingsWindow")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Don't drop the cursor into the first preset field.
        window?.makeFirstResponder(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    var log: TimeLog
    var onOpenTimesheet: () -> Void
    var onShowShortcuts: () -> Void
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @ObservedObject private var hotkeyCenter = HotkeyCenter.shared

    var body: some View {
        Form {
            presetsSection
            keyboardSection
            interactionSection
            timesheetSection
            menuBarSection
            floatingSection
            completionSection
            generalSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 560, idealHeight: 720)
    }

    // MARK: Presets

    private var presetsSection: some View {
        Section {
            ForEach(prefs.presets.indices, id: \.self) { index in
                HStack {
                    Text("Preset \(index + 1)")
                    Spacer()
                    TextField("", value: presetBinding(index), format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Text("min").foregroundStyle(.secondary)
                    Stepper("", value: presetBinding(index), in: 1...999)
                        .labelsHidden()
                    Button {
                        prefs.removePreset(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red.opacity(0.85))
                    }
                    .buttonStyle(.borderless)
                    .help("Remove preset")
                }
            }
            HStack {
                Button("Add Preset") {
                    let next = (prefs.presets.max() ?? 15) + 15
                    prefs.presets.append(min(next, 999))
                }
                .disabled(prefs.presets.count >= Preferences.maxPresets)
                Button("Sort") { prefs.presets.sort() }
                    .disabled(prefs.presets == prefs.presets.sorted())
                Spacer()
                Button("Restore Defaults") { prefs.presets = Preferences.defaultPresets }
            }
        } header: {
            Text("Presets")
        } footer: {
            Text("Shown as quick picks in the timer panel. Up to \(Preferences.maxPresets). Press 1–\(Preferences.maxPresets) in the panel to pick one.")
                .settingsFootnote()
        }
    }

    private func presetBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { prefs.presets.indices.contains(index) ? prefs.presets[index] : 1 },
            set: { if prefs.presets.indices.contains(index) { prefs.presets[index] = $0 } }
        )
    }

    // MARK: Keyboard

    private var keyboardSection: some View {
        Section {
            Toggle("Global shortcuts (work from any app)", isOn: $prefs.hotkeysEnabled)
            ForEach(HotkeyAction.allCases) { action in
                LabeledContent(action.title) {
                    HotkeyRecorder(
                        hotkey: prefs.hotkeys[action] ?? nil,
                        conflict: prefs.hotkeysEnabled && hotkeyCenter.conflicts.contains(action),
                        onChange: { prefs.hotkeys[action] = .some($0) },
                        onRecordingChange: { recording in
                            recording ? HotkeyCenter.shared.suspend() : HotkeyCenter.shared.resume()
                        }
                    )
                }
                .disabled(!prefs.hotkeysEnabled)
            }
            HStack {
                Button("Show All Shortcuts…", action: onShowShortcuts)
                Spacer()
                Button("Restore Defaults") {
                    prefs.hotkeys = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0, $0.defaultHotkey) })
                }
            }
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Click a shortcut, then press the new keys (needs ⌃, ⌥ or ⌘). ⌫ clears it, esc cancels. Press ? or ⌘/ in the app to see every shortcut.")
                .settingsFootnote()
        }
    }

    // MARK: Interaction

    private var interactionSection: some View {
        Section {
            Picker("Clicking the menu bar timer", selection: $prefs.menuBarClick) {
                ForEach(MenuBarClickAction.allCases) { Text($0.title).tag($0) }
            }
            Picker("Clicking a preset", selection: $prefs.presetClick) {
                ForEach(PresetClickAction.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Close the panel when a timer starts", isOn: $prefs.closePanelOnStart)
            Picker("Slider range", selection: $prefs.sliderMaxMinutes) {
                ForEach(Preferences.sliderRanges, id: \.self) { Text("0 – \($0) min").tag($0) }
            }
        } header: {
            Text("Interaction")
        } footer: {
            Text("⌥-click the menu bar timer for the other action, right-click for a quick menu. Keyboard shortcuts are listed under Keyboard above.")
                .settingsFootnote()
        }
    }

    // MARK: Timesheet

    private var timesheetSection: some View {
        Section {
            Toggle("Put the cursor in the task field when the panel opens", isOn: $prefs.focusTaskOnOpen)
            Toggle("Pause count-up when the Mac sleeps", isOn: $prefs.pauseCountUpOnSleep)
            Toggle("Pause count-up when the screen locks", isOn: $prefs.pauseCountUpOnLock)
            HStack {
                Button("Open Timesheet", action: onOpenTimesheet)
                Button("Show Data File in Finder") { log.revealInFinder() }
                Spacer()
            }
        } header: {
            Text("Timesheet")
        } footer: {
            Text("Every countdown and count-up is logged with its task, excluding pauses. Sessions under \(Int(TimeLog.minimumDuration)) seconds are ignored. Data is stored as JSON in ~/Library/Application Support/Pomodoro.")
                .settingsFootnote()
        }
    }

    // MARK: Menu bar

    private var menuBarSection: some View {
        Section("Menu Bar") {
            Picker("Style", selection: $prefs.menuBarStyle) {
                ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
            }
            Picker("Time format", selection: $prefs.menuBarFormat) {
                ForEach(MenuBarTimeFormat.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show an icon instead of the time when idle", isOn: $prefs.iconWhenIdle)
            Toggle("Show the task name while a timer runs", isOn: $prefs.menuBarShowsTask)
            Toggle("Show a timesheet icon in the menu bar", isOn: $prefs.timesheetMenuBarIcon)
        }
    }

    // MARK: Floating timer

    private var floatingSection: some View {
        Section {
            Toggle("Show when a timer starts", isOn: $prefs.floatingOnStart)
            Toggle("Show when a timer finishes", isOn: $prefs.floatingOnFinish)
            Toggle("Show the task under the time", isOn: $prefs.floatingShowsTask)
            Picker("Size", selection: $prefs.floatingSize) {
                ForEach(FloatingSize.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Background opacity") {
                Slider(value: $prefs.floatingOpacity, in: 0.3...1)
                    .frame(width: 180)
            }
        } header: {
            Text("Floating Timer")
        } footer: {
            Text("Drag it anywhere. Double-click to pause or resume. Hover and click × to close.")
                .settingsFootnote()
        }
    }

    // MARK: Completion

    private var completionSection: some View {
        Section("When the Timer Ends") {
            Picker("Sound", selection: $prefs.soundName) {
                Text("None").tag("")
                Divider()
                ForEach(Completion.systemSounds, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: prefs.soundName) { _, name in Completion.playSound(named: name) }
            Toggle("Show a notification", isOn: $prefs.showNotification)
                .onChange(of: prefs.showNotification) { _, enabled in
                    if enabled { Completion.requestNotificationPermission() }
                }
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            if let launchAtLoginError {
                Text(launchAtLoginError).settingsFootnote().foregroundStyle(.red)
            }
            HStack {
                Text("Pomodoro \(Bundle.main.shortVersion)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit Pomodoro") { NSApp.terminate(nil) }
            }
        } header: {
            Text("General")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            // Rebuilding or deleting the .app while this copy runs leaves the process
            // pointing at a missing bundle, which SMAppService rejects as "Invalid argument".
            if !FileManager.default.fileExists(atPath: Bundle.main.bundlePath) {
                launchAtLoginError = "Couldn't update login item: this copy of Pomodoro was moved or deleted while running. Quit and reopen Pomodoro, then try again."
            } else {
                launchAtLoginError = "Couldn't update login item: \(error.localizedDescription)."
            }
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private extension Text {
    func settingsFootnote() -> some View {
        font(.footnote).foregroundStyle(.secondary)
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
