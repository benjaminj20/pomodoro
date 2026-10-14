import Foundation

enum MenuBarClickAction: String, CaseIterable, Identifiable {
    case openPanel
    case toggleTimer

    var id: String { rawValue }
    var title: String {
        switch self {
        case .openPanel: "Open the timer panel"
        case .toggleTimer: "Start / pause the timer"
        }
    }
}

enum PresetClickAction: String, CaseIterable, Identifiable {
    case setTime
    case setAndStart

    var id: String { rawValue }
    var title: String {
        switch self {
        case .setTime: "Set the time"
        case .setAndStart: "Set the time and start"
        }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case boxed
    case plain

    var id: String { rawValue }
    var title: String {
        switch self {
        case .boxed: "Outlined"
        case .plain: "Plain text"
        }
    }
}

enum MenuBarTimeFormat: String, CaseIterable, Identifiable {
    case clock
    case compact

    var id: String { rawValue }
    var title: String {
        switch self {
        case .clock: "25:00"
        case .compact: "25m"
        }
    }

    func format(_ seconds: TimeInterval) -> String {
        switch self {
        case .clock: TimeFormatter.clock(seconds)
        case .compact: TimeFormatter.compact(seconds)
        }
    }
}

enum FloatingSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scale: CGFloat {
        switch self {
        case .small: 0.75
        case .medium: 1
        case .large: 1.5
        }
    }
}

/// User settings, persisted to UserDefaults on every change.
@MainActor
final class Preferences: ObservableObject {
    static let defaultPresets = [5, 30, 45]
    static let maxPresets = 8
    static let sliderRanges = [60, 90, 120, 180, 240]

    private let defaults = UserDefaults.standard

    // Timer
    @Published var presets: [Int] {
        didSet {
            let clamped = presets.map { min(max($0, 1), 999) }
            if clamped != presets { presets = clamped }
            defaults.set(presets, forKey: Key.presets)
        }
    }
    @Published var lastMinutes: Int { didSet { defaults.set(lastMinutes, forKey: Key.lastMinutes) } }
    @Published var sliderMaxMinutes: Int { didSet { defaults.set(sliderMaxMinutes, forKey: Key.sliderMaxMinutes) } }

    // Interaction
    @Published var menuBarClick: MenuBarClickAction { didSet { defaults.set(menuBarClick.rawValue, forKey: Key.menuBarClick) } }
    @Published var presetClick: PresetClickAction { didSet { defaults.set(presetClick.rawValue, forKey: Key.presetClick) } }
    @Published var closePanelOnStart: Bool { didSet { defaults.set(closePanelOnStart, forKey: Key.closePanelOnStart) } }

    // Menu bar
    @Published var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: Key.menuBarStyle) } }
    @Published var menuBarFormat: MenuBarTimeFormat { didSet { defaults.set(menuBarFormat.rawValue, forKey: Key.menuBarFormat) } }
    @Published var iconWhenIdle: Bool { didSet { defaults.set(iconWhenIdle, forKey: Key.iconWhenIdle) } }

    // Floating timer
    @Published var floatingOnStart: Bool { didSet { defaults.set(floatingOnStart, forKey: Key.floatingOnStart) } }
    @Published var floatingOnFinish: Bool { didSet { defaults.set(floatingOnFinish, forKey: Key.floatingOnFinish) } }
    @Published var floatingSize: FloatingSize { didSet { defaults.set(floatingSize.rawValue, forKey: Key.floatingSize) } }
    @Published var floatingOpacity: Double { didSet { defaults.set(floatingOpacity, forKey: Key.floatingOpacity) } }

    // Timesheet
    @Published var focusTaskOnOpen: Bool { didSet { defaults.set(focusTaskOnOpen, forKey: Key.focusTaskOnOpen) } }
    @Published var floatingShowsTask: Bool { didSet { defaults.set(floatingShowsTask, forKey: Key.floatingShowsTask) } }
    @Published var menuBarShowsTask: Bool { didSet { defaults.set(menuBarShowsTask, forKey: Key.menuBarShowsTask) } }
    @Published var pauseCountUpOnSleep: Bool { didSet { defaults.set(pauseCountUpOnSleep, forKey: Key.pauseCountUpOnSleep) } }

    // Completion
    /// Empty string means no sound.
    @Published var soundName: String { didSet { defaults.set(soundName, forKey: Key.soundName) } }
    @Published var showNotification: Bool { didSet { defaults.set(showNotification, forKey: Key.showNotification) } }

    init() {
        let d = UserDefaults.standard
        presets = d.array(forKey: Key.presets) as? [Int] ?? Self.defaultPresets
        lastMinutes = d.object(forKey: Key.lastMinutes) as? Int ?? 30
        sliderMaxMinutes = d.object(forKey: Key.sliderMaxMinutes) as? Int ?? 120

        menuBarClick = Self.load(Key.menuBarClick, .openPanel)
        presetClick = Self.load(Key.presetClick, .setTime)
        closePanelOnStart = d.object(forKey: Key.closePanelOnStart) as? Bool ?? true

        menuBarStyle = Self.load(Key.menuBarStyle, .boxed)
        menuBarFormat = Self.load(Key.menuBarFormat, .clock)
        iconWhenIdle = d.object(forKey: Key.iconWhenIdle) as? Bool ?? false

        floatingOnStart = d.object(forKey: Key.floatingOnStart) as? Bool ?? true
        floatingOnFinish = d.object(forKey: Key.floatingOnFinish) as? Bool ?? true
        floatingSize = Self.load(Key.floatingSize, .medium)
        floatingOpacity = d.object(forKey: Key.floatingOpacity) as? Double ?? 1

        focusTaskOnOpen = d.object(forKey: Key.focusTaskOnOpen) as? Bool ?? true
        floatingShowsTask = d.object(forKey: Key.floatingShowsTask) as? Bool ?? true
        menuBarShowsTask = d.object(forKey: Key.menuBarShowsTask) as? Bool ?? false
        pauseCountUpOnSleep = d.object(forKey: Key.pauseCountUpOnSleep) as? Bool ?? true

        soundName = d.string(forKey: Key.soundName) ?? "Glass"
        showNotification = d.object(forKey: Key.showNotification) as? Bool ?? true
    }

    func addPreset(_ minutes: Int) {
        guard presets.count < Self.maxPresets, !presets.contains(minutes) else { return }
        presets.append(minutes)
        presets.sort()
    }

    func removePreset(at index: Int) {
        guard presets.indices.contains(index) else { return }
        presets.remove(at: index)
    }

    private static func load<E: RawRepresentable>(_ key: String, _ fallback: E) -> E where E.RawValue == String {
        UserDefaults.standard.string(forKey: key).flatMap(E.init(rawValue:)) ?? fallback
    }

    private enum Key {
        static let presets = "presets"
        static let lastMinutes = "lastMinutes"
        static let sliderMaxMinutes = "sliderMaxMinutes"
        static let menuBarClick = "menuBarClick"
        static let presetClick = "presetClick"
        static let closePanelOnStart = "closePanelOnStart"
        static let menuBarStyle = "menuBarStyle"
        static let menuBarFormat = "menuBarFormat"
        static let iconWhenIdle = "iconWhenIdle"
        static let floatingOnStart = "floatingOnStart"
        static let floatingOnFinish = "floatingOnFinish"
        static let floatingSize = "floatingSize"
        static let floatingOpacity = "floatingOpacity"
        static let focusTaskOnOpen = "focusTaskOnOpen"
        static let floatingShowsTask = "floatingShowsTask"
        static let menuBarShowsTask = "menuBarShowsTask"
        static let pauseCountUpOnSleep = "pauseCountUpOnSleep"
        static let soundName = "soundName"
        static let showNotification = "showNotification"
    }
}
