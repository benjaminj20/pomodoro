import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key combination, e.g. ⌃⌥P.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags raw value (only ⌃⌥⇧⌘ are kept).
    var modifiers: UInt
    /// What to show in the UI, e.g. "P".
    var key: String

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var display: String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + key
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    static let relevantFlags: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    static func controlOption(_ keyCode: Int, _ key: String) -> Hotkey {
        Hotkey(keyCode: UInt32(keyCode), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, key: key)
    }

    /// Human-readable key name for a recorded event.
    static func keyName(for event: NSEvent) -> String {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        if let name = named[Int(event.keyCode)] { return name }
        if let number = functionKeys[Int(event.keyCode)] { return "F\(number)" }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    private static let functionKeys: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8,
        kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15,
        kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
    ]
}

/// Things you can trigger from anywhere on the Mac.
enum HotkeyAction: String, CaseIterable, Identifiable, Codable {
    case togglePanel, startPause, countUp, stop, timesheet, floating

    var id: String { rawValue }

    var title: String {
        switch self {
        case .togglePanel: "Open / close the timer panel"
        case .startPause: "Start / pause the timer"
        case .countUp: "Start counting up"
        case .stop: "Stop and log the timer"
        case .timesheet: "Open / close the timesheet"
        case .floating: "Show / hide the floating timer"
        }
    }

    var defaultHotkey: Hotkey {
        switch self {
        case .togglePanel: .controlOption(kVK_ANSI_P, "P")
        case .startPause: .controlOption(kVK_ANSI_S, "S")
        case .countUp: .controlOption(kVK_ANSI_U, "U")
        case .stop: .controlOption(kVK_ANSI_X, "X")
        case .timesheet: .controlOption(kVK_ANSI_T, "T")
        case .floating: .controlOption(kVK_ANSI_F, "F")
        }
    }
}

/// Registers system-wide hotkeys with Carbon. Works without Accessibility
/// permission, and the combo is swallowed so it doesn't leak into other apps.
@MainActor
final class HotkeyCenter: ObservableObject {
    static let shared = HotkeyCenter()

    /// Actions whose combo couldn't be registered (usually taken by another app).
    @Published private(set) var conflicts: Set<HotkeyAction> = []

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: HotkeyAction] = [:]
    private var handler: ((HotkeyAction) -> Void)?
    private var eventHandler: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let number = id.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotkeyCenter.shared.fire(number) }
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    func setHandler(_ handler: @escaping (HotkeyAction) -> Void) {
        self.handler = handler
    }

    private var lastBindings: [HotkeyAction: Hotkey] = [:]

    /// Temporarily release everything (while recording a new shortcut).
    func suspend() { unregisterAll() }
    func resume() { register(lastBindings) }

    func register(_ bindings: [HotkeyAction: Hotkey]) {
        lastBindings = bindings
        unregisterAll()
        var failed: Set<HotkeyAction> = []
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let hotkey = bindings[action] else { continue }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers,
                                             EventHotKeyID(signature: OSType(0x504F4D4F), id: id), // 'POMO'
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id] = action
            } else {
                failed.insert(action)
            }
        }
        conflicts = failed
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    private func fire(_ id: UInt32) {
        if let action = actions[id] { handler?(action) }
    }
}

/// Click, then press the new shortcut. ⌫ clears it, esc cancels.
struct HotkeyRecorder: View {
    var hotkey: Hotkey?
    var conflict: Bool
    var onChange: (Hotkey?) -> Void
    var onRecordingChange: (Bool) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if conflict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Another app is using this shortcut — pick a different one")
            }
            Button(action: toggleRecording) {
                Text(isRecording ? "Type shortcut…" : (hotkey?.display ?? "None"))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(isRecording ? Color.accentColor : (hotkey == nil ? .secondary : .primary))
                    .frame(minWidth: 96)
            }
            .buttonStyle(.bordered)
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(Hotkey.relevantFlags)
            let keyCode = event.keyCode
            let name = Hotkey.keyName(for: event)
            MainActor.assumeIsolated {
                if keyCode == UInt16(kVK_Escape) {
                    stopRecording()
                } else if (keyCode == UInt16(kVK_Delete) || keyCode == UInt16(kVK_ForwardDelete)) && flags.isEmpty {
                    onChange(nil)
                    stopRecording()
                } else if !flags.intersection([.control, .option, .command]).isEmpty {
                    // Needs ⌃, ⌥ or ⌘ so it can't clash with normal typing.
                    onChange(Hotkey(keyCode: UInt32(keyCode), modifiers: flags.rawValue, key: name))
                    stopRecording()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording { onRecordingChange(false) }
        isRecording = false
    }
}
