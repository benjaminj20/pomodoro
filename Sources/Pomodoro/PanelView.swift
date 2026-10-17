import AppKit
import SwiftUI

/// Lets the panel controller poke the SwiftUI view (e.g. focus the task field).
@MainActor
final class PanelState: ObservableObject {
    @Published var focusRequest = 0
    /// Suggestion row picked with ↑/↓, remembered with the text it was picked
    /// for so typing anything else drops it.
    @Published var highlight: (query: String, index: Int)?
    /// Text the suggestions were dismissed for (esc, or one was just accepted).
    @Published var dismissedQuery: String?

    static let maxSuggestions = 4

    func suggestions(in log: TimeLog) -> [String] {
        guard dismissedQuery != log.currentTask else { return [] }
        return log.suggestedTasks(for: log.currentTask, limit: Self.maxSuggestions)
    }

    func highlightedIndex(for query: String, count: Int) -> Int? {
        guard let highlight, highlight.query == query, highlight.index < count else { return nil }
        return highlight.index
    }

    func accept(_ task: String, in log: TimeLog) {
        log.currentTask = task
        dismissedQuery = task
        highlight = nil
    }
}

struct PanelView: View {
    @ObservedObject var model: TimerModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var log: TimeLog
    @ObservedObject var state: PanelState
    var onStart: () -> Void
    var onOpenSettings: () -> Void
    var onOpenTimesheet: () -> Void
    var onShowShortcuts: () -> Void

    @FocusState private var taskFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            taskField
                .padding(.bottom, 12)

            TickSlider(
                fraction: model.displaySeconds / Double(prefs.sliderMaxMinutes * 60),
                dimmed: model.isCountingUp,
                onScrub: { fraction in
                    // The slider sets countdown length; it doesn't apply to a stopwatch.
                    guard !model.isCountingUp else { return }
                    let minutes = Int((fraction * Double(prefs.sliderMaxMinutes)).rounded())
                    let clamped = min(max(minutes, 1), prefs.sliderMaxMinutes)
                    if clamped != model.minutes || model.phase == .finished { model.setMinutes(clamped) }
                }
            )
            .frame(height: 18)

            HStack(spacing: 4) {
                ForEach(Array(prefs.presets.enumerated()), id: \.offset) { index, minutes in
                    PresetChip(minutes: minutes, isSelected: model.minutes == minutes) {
                        selectPreset(minutes)
                    }
                    .contextMenu {
                        Button("Remove \(minutes)m Preset") { prefs.removePreset(at: index) }
                    }
                }
                Spacer(minLength: 0)
                timesheetButton
                moreMenu
            }
            .padding(.top, 13)
            .padding(.horizontal, -6)

            Spacer(minLength: 0)

            HStack(alignment: .lastTextBaseline, spacing: 0) {
                HStack(spacing: 2) {
                    TextButton(primaryTitle, action: toggle)
                    if model.isActive {
                        TextButton("stop", secondary: true) { model.stop() }
                    } else {
                        TextButton("count up", secondary: true, action: startCountUp)
                            .help("Start a stopwatch for a task of unknown length")
                    }
                }
                .padding(.leading, -6)

                Spacer(minLength: 8)

                Text(model.clockText)
                    .font(.system(size: 50, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(model.phase == .paused ? 0.55 : 1))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText(countsDown: !model.isCountingUp))
                    .animation(.snappy(duration: 0.25), value: Int(ceil(model.displaySeconds)))
                    .onTapGesture(perform: toggle)
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .frame(width: TimerPanelController.size.width, height: TimerPanelController.size.height)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            if taskFocused { suggestionList }
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: state.focusRequest) { _, _ in taskFocused = true }
    }

    /// One-line description of what you're doing; logged with the session.
    private var taskField: some View {
        HStack(spacing: 6) {
            Image(systemName: model.isActive ? "record.circle" : "pencil.line")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(model.isActive ? 0.8 : 0.4))
                .frame(width: 14)
            TextField("", text: $log.currentTask, prompt: Text("What are you working on?").foregroundStyle(.white.opacity(0.38)))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.95))
                .focused($taskFocused)
                .onSubmit {
                    taskFocused = false
                    if !model.isActive {
                        model.start()
                        onStart()
                    }
                }
            recentTasksMenu
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(taskFocused ? 0.1 : 0.06))
        )
        .padding(.horizontal, -4)
    }

    /// Past tasks matching what's typed, dropped down over the slider.
    /// ↓/↑ pick one, ↩ or ⇥ takes it; clicking works too.
    @ViewBuilder
    private var suggestionList: some View {
        let suggestions = state.suggestions(in: log)
        if !suggestions.isEmpty {
            let highlighted = state.highlightedIndex(for: log.currentTask, count: suggestions.count)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element) { index, task in
                    SuggestionRow(task: task, query: log.currentTask, isHighlighted: index == highlighted) {
                        state.accept(task, in: log)
                    }
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(white: 0.16))
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .padding(.top, 14 + 28 + 3)
            .padding(.horizontal, 10)
        }
    }

    private var recentTasksMenu: some View {
        let recent = log.recentTasks()
        return Menu {
            if recent.isEmpty {
                Text("No recent tasks yet")
            }
            ForEach(recent, id: \.self) { task in
                Button(task) { log.currentTask = task }
            }
            if !log.currentTask.isEmpty {
                Divider()
                Button("Clear") { log.currentTask = "" }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recent tasks")
    }

    private var primaryTitle: String {
        switch model.phase {
        case .idle, .finished: "start"
        case .running: "pause"
        case .paused: "resume"
        }
    }

    private func startCountUp() {
        model.startCountUp()
        onStart()
    }

    private func toggle() {
        let wasIdle = !model.isActive
        model.toggle()
        if wasIdle { onStart() }
    }

    private func selectPreset(_ minutes: Int) {
        model.setMinutes(minutes)
        guard prefs.presetClick == .setAndStart else { return }
        switch (model.phase, model.mode) {
        case (.running, .countdown):
            break // setMinutes already restarted the countdown from the new length
        case (.paused, .countdown):
            model.resume()
        default:
            model.start()
            onStart()
        }
    }

    private var timesheetButton: some View {
        Button(action: onOpenTimesheet) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Timesheet (⌘T) — press ⌘/ for all shortcuts")
    }

    private var moreMenu: some View {
        Menu {
            let current = model.minutes
            Button("Save \(current)m as Preset") { prefs.addPreset(current) }
                .disabled(prefs.presets.contains(current) || prefs.presets.count >= Preferences.maxPresets)
            Divider()
            Button("Timesheet…", action: onOpenTimesheet)
            Button("Keyboard Shortcuts…", action: onShowShortcuts)
            Button("Settings…", action: onOpenSettings)
            Button("Quit Pomodoro") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// A row of fine vertical ticks with a bright playhead you can drag.
struct TickSlider: View {
    var fraction: Double
    var dimmed = false
    var onScrub: (Double) -> Void

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var pushedCursor = false

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let spacing: CGFloat = 3
                let tickColor = Color.white.opacity(dimmed ? 0.12 : (isHovering || isDragging ? 0.32 : 0.24))
                var x: CGFloat = 0
                while x <= size.width - 1 {
                    context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(tickColor))
                    x += spacing
                }
                let clamped = min(max(fraction, 0), 1)
                let headX = (size.width - 2) * clamped
                context.fill(
                    Path(roundedRect: CGRect(x: headX, y: -2, width: 2, height: size.height + 4), cornerRadius: 1),
                    with: .color(.white.opacity(dimmed ? 0.5 : 1))
                )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        onScrub(min(max(value.location.x / geo.size.width, 0), 1))
                    }
                    .onEnded { _ in isDragging = false }
            )
            .onHover { hovering in
                isHovering = hovering
                if hovering && !dimmed && !pushedCursor {
                    NSCursor.resizeLeftRight.push()
                    pushedCursor = true
                } else if !hovering && pushedCursor {
                    NSCursor.pop()
                    pushedCursor = false
                }
            }
        }
    }
}

struct PresetChip: View {
    var minutes: Int
    var isSelected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text("\(minutes)m")
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(isSelected ? 1 : 0.82))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(isHovering ? 0.12 : (isSelected ? 0.07 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Lowercase text-only button, like "start" in the bottom-left corner.
struct TextButton: View {
    var title: String
    var secondary: Bool
    var action: () -> Void

    @State private var isHovering = false

    init(_ title: String, secondary: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.secondary = secondary
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(secondary ? 0.5 : 0.95))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(isHovering ? 0.12 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// One suggestion, with the part you've typed in full strength.
private struct SuggestionRow: View {
    var task: String
    var query: String
    var isHighlighted: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHighlighted ? Color.accentColor.opacity(0.85) : .white.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var label: Text {
        let typed = TimeLog.clean(query)
        guard let range = task.range(of: typed, options: [.caseInsensitive, .anchored])
                ?? task.range(of: " " + typed, options: .caseInsensitive) else {
            return Text(task).foregroundColor(.white.opacity(0.9))
        }
        return Text(task[..<range.lowerBound]).foregroundColor(.white.opacity(0.6))
            + Text(task[range]).foregroundColor(.white)
            + Text(task[range.upperBound...]).foregroundColor(.white.opacity(0.6))
    }
}
