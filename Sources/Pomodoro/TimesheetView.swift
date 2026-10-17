import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TimesheetWindowController: NSObject, NSWindowDelegate {
    private let log: TimeLog
    private lazy var state = TimesheetState(log: log)
    private var window: NSWindow?
    private var keyMonitor: Any?

    init(log: TimeLog) {
        self.log = log
    }

    var nsWindow: NSWindow? { window }
    var onShowShortcuts: (() -> Void)? {
        get { state.onShowShortcuts }
        set { state.onShowShortcuts = newValue }
    }
    var isFrontmost: Bool { window?.isKeyWindow == true && NSApp.isActive }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: TimesheetView(state: state, log: log))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Timesheet"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 920, height: 760))
            window.contentMinSize = NSSize(width: 780, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("TimesheetWindow")
            self.window = window
            state.presentingWindow = window
            installKeyMonitor()
        }
        // Always open on today.
        if !(window?.isVisible ?? false) { state.goToToday() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.performClose(nil)
    }

    /// Timesheet shortcuts, active whenever the window has the keyboard and
    /// you're not typing in a field or looking at a sheet/alert.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let characters = event.charactersIgnoringModifiers
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, window.isKeyWindow,
                      window.attachedSheet == nil, !(window.firstResponder is NSTextView) else { return false }
                if keyCode == 53 { // esc: clear selection, then close
                    if self.state.selectedSessionID != nil { self.state.selectedSessionID = nil } else { window.performClose(nil) }
                    return true
                }
                return self.state.handleKey(keyCode: keyCode, characters: characters, flags: flags)
            }
            return handled ? nil : event
        }
    }
}

// MARK: - Palette

/// Chart colors and ink, from the validated reference palette (light and dark
/// steps chosen separately, not flipped). Slot order is fixed — it's what keeps
/// adjacent stacked segments distinguishable under color-vision deficiency.
enum ChartPalette {
    private static let slots: [(light: UInt32, dark: UInt32)] = [
        (0x2A78D6, 0x3987E5), // blue
        (0xEB6834, 0xD95926), // orange
        (0x1BAF7A, 0x199E70), // aqua
        (0xEDA100, 0xC98500), // yellow
        (0xE87BA4, 0xD55181), // magenta
        (0x008300, 0x008300), // green
        (0x4A3AA7, 0x9085E9), // violet
    ]

    static func series(_ slot: Int?) -> Color {
        guard let slot, slots.indices.contains(slot) else { return other }
        return dynamic(slots[slot].light, slots[slot].dark)
    }

    static let other = dynamic(0xA9A8A1, 0x5F5E59)
    static let surface = dynamic(0xFCFCFB, 0x1A1A19)
    static let primaryInk = dynamic(0x0B0B0B, 0xFFFFFF)
    static let secondaryInk = dynamic(0x52514E, 0xC3C2B7)
    static let mutedInk = dynamic(0x898781, 0x898781)
    static let gridline = dynamic(0xE1E0D9, 0x2C2C2A)
    static let baseline = dynamic(0xC3C2B7, 0x383835)
    static let border = Color.primary.opacity(0.10)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Root

struct TimesheetView: View {
    @ObservedObject var state: TimesheetState
    @ObservedObject var log: TimeLog

    private var calendar: Calendar { state.calendar }

    var body: some View {
        // Re-render every 30s so a running session's time grows live.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let report = state.report(now: context.date)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            header
                            if let live = log.liveSession(now: context.date) {
                                Label("Tracking “\(live.displayTask)” — \(TimeFormatter.duration(live.duration)) so far", systemImage: "record.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(ChartPalette.secondaryInk)
                            }
                        }
                        StatTiles(report: report)
                        if report.total == 0 {
                            EmptyWeek()
                        } else {
                            let day = state.resolvedDay(report, now: context.date)
                            Card(title: "Day breakdown") {
                                DayTimeline(report: report, day: day, now: context.date, calendar: calendar,
                                            showOvernight: $state.showOvernight)
                            } accessory: {
                                dayPicker(report, selection: day)
                            }
                            Card(title: state.logShowsWeek ? "Log — whole week" : "Log") {
                                SessionLog(report: report, days: state.logDays(report, now: context.date),
                                           liveID: log.active?.id, selectedID: state.selectedSessionID,
                                           onSelect: { state.selectedSessionID = $0.id },
                                           onEdit: { state.edit($0) },
                                           onDelete: { state.requestDelete($0) })
                            } accessory: {
                                Picker("Log range", selection: $state.logShowsWeek) {
                                    Text("Day").tag(false)
                                    Text("Week").tag(true)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                                .help("Show this day or the whole week (W)")
                            }
                            Card(title: "Time by day") {
                                DayColumnsChart(report: report, calendar: calendar)
                            }
                            Card(title: "Tasks") {
                                TaskGrid(report: report, calendar: calendar) { row in
                                    state.rename(task: row.name)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 36)
                    .padding(.bottom, 28)
                }
                .onChange(of: state.selectedSessionID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let url = state.exportedURL {
                exportConfirmation(url)
            }
        }
        .sheet(item: $state.editing) { draft in
            SessionEditor(draft: draft, recentTasks: log.recentTasks(limit: 12)) { session in
                state.save(session)
            } onDelete: { id in
                log.delete(id)
            }
        }
        .alert("Rename Task", isPresented: Binding(get: { state.renaming != nil }, set: { if !$0 { state.renaming = nil } })) {
            TextField("Task", text: $state.renameText)
            Button("Rename") { state.commitRename() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { state.renaming = nil }
        } message: {
            Text("Renames every logged session of “\(state.renaming ?? "")”. Use an existing name to merge tasks.")
        }
        .alert("Delete this entry?", isPresented: Binding(get: { state.pendingDelete != nil }, set: { if !$0 { state.pendingDelete = nil } })) {
            Button("Delete", role: .destructive) { state.confirmDelete() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { state.pendingDelete = nil }
        } message: {
            if let session = state.pendingDelete {
                Text("“\(session.displayTask)”, \(session.start.formatted(date: .abbreviated, time: .shortened)), \(TimeFormatter.duration(session.duration)).")
            }
        }
        .alert("Export failed", isPresented: Binding(get: { state.exportError != nil }, set: { if !$0 { state.exportError = nil } })) {
            Button("OK") { state.exportError = nil }
        } message: {
            Text(state.exportError ?? "")
        }
    }

    private func exportConfirmation(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 3) {
                Text("Saved \(url.lastPathComponent)")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(url.path)
            .textSelection(.enabled)
            Spacer(minLength: 12)
            Button("Show in Finder") { state.revealExportInFinder() }
            Button { state.exportedURL = nil } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss export confirmation")
            .help("Dismiss export confirmation")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ControlGroup {
                    Button { state.shiftWeek(-1) } label: { Image(systemName: "chevron.left") }
                        .help("Previous week (⇧←)")
                    Button { state.shiftWeek(1) } label: { Image(systemName: "chevron.right") }
                        .help("Next week (⇧→)")
                }
                .fixedSize()
                Text(Self.weekTitle(state.week, calendar: calendar))
                    .font(.system(size: 20, weight: .semibold))
                if !state.isCurrentWeek || state.selectedDay != nil {
                    Button("Today") { state.goToToday() }
                        .help("Go to today (T)")
                }

                Spacer()

                Button { state.addEntry() } label: {
                    Label("Add Entry", systemImage: "plus")
                }
                .help("Add an entry for the untracked gap (N)")
                Menu {
                    Button("Export This Week as CSV…") { state.exportWeek() }
                    Button("Export Everything as CSV…") { state.exportAll() }
                    Divider()
                    Button("Show Data File in Finder") { log.revealInFinder() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
                .help("Export as CSV (⌘E)")
                Button { state.onShowShortcuts?() } label: {
                    Image(systemName: "keyboard")
                }
                .help("Keyboard shortcuts (?)")
            }
            .buttonStyle(.bordered)
        }
    }

    private func dayPicker(_ report: TimesheetReport, selection: Int) -> some View {
        Picker("Day", selection: Binding(get: { selection }, set: { state.selectedDay = $0 })) {
            ForEach(0..<7, id: \.self) { index in
                Text(report.days[index].start.formatted(.dateTime.weekday(.abbreviated).day())).tag(index)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Previous / next day (← →)")
    }

    static func weekTitle(_ week: DateInterval, calendar: Calendar) -> String {
        let last = calendar.date(byAdding: .day, value: -1, to: week.end) ?? week.end
        let formatter = DateIntervalFormatter()
        formatter.dateTemplate = "MMMdy"
        return formatter.string(from: week.start, to: last)
    }
}

// MARK: - Building blocks

private struct Card<Content: View, Accessory: View>: View {
    var title: String
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChartPalette.secondaryInk)
                Spacer()
                accessory
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ChartPalette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ChartPalette.border))
    }
}

extension Card where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content, accessory: { EmptyView() })
    }
}

private struct StatTiles: View {
    var report: TimesheetReport

    var body: some View {
        HStack(spacing: 12) {
            tile("Total this week", TimeFormatter.duration(report.total))
            tile("Daily average", report.activeDayCount == 0 ? "–" : TimeFormatter.duration(report.total / Double(report.activeDayCount)),
                 note: report.activeDayCount == 0 ? nil : "over \(report.activeDayCount) day\(report.activeDayCount == 1 ? "" : "s")")
            tile("Sessions", "\(report.sessionCount)")
            tile("Top task", report.rows.first?.name ?? "–",
                 note: report.rows.first.map { TimeFormatter.duration($0.total) })
        }
    }

    private func tile(_ label: String, _ value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(ChartPalette.secondaryInk)
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(ChartPalette.primaryInk)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(note ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(ChartPalette.mutedInk)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ChartPalette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ChartPalette.border))
    }
}

private struct EmptyWeek: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 30))
                .foregroundStyle(ChartPalette.mutedInk)
            Text("Nothing logged this week")
                .font(.system(size: 15, weight: .semibold))
            Text("Type what you're working on in the timer panel, then start a countdown or count up.\nEvery session lands here automatically.")
                .font(.system(size: 12))
                .foregroundStyle(ChartPalette.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ChartPalette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ChartPalette.border))
    }
}

struct Swatch: View {
    var slot: Int?
    var body: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(ChartPalette.series(slot))
            .frame(width: 10, height: 10)
    }
}

// MARK: - Chart

/// One stacked column per day, a segment per task.
private struct DayColumnsChart: View {
    var report: TimesheetReport
    var calendar: Calendar

    private let plotHeight: CGFloat = 190
    private let barWidth: CGFloat = 24
    private let gap: CGFloat = 2

    var body: some View {
        let scale = AxisScale(maxValue: report.dayTotals.max() ?? 0)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                yAxis(scale)
                VStack(spacing: 8) {
                    ZStack(alignment: .bottom) {
                        gridlines(scale)
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { day in
                                column(day: day, scale: scale)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(height: plotHeight)
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { day in
                            dayLabel(day).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            legend
        }
    }

    private func yAxis(_ scale: AxisScale) -> some View {
        ZStack(alignment: .topTrailing) {
            ForEach(scale.ticks, id: \.self) { tick in
                Text(scale.label(tick))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(ChartPalette.mutedInk)
                    .offset(y: plotHeight - CGFloat(tick / scale.top) * plotHeight - 6)
            }
        }
        .frame(width: 26, height: plotHeight, alignment: .topTrailing)
    }

    private func gridlines(_ scale: AxisScale) -> some View {
        Canvas { context, size in
            for tick in scale.ticks {
                let y = (size.height - CGFloat(tick / scale.top) * size.height).rounded() - 0.5
                let color = tick == 0 ? ChartPalette.baseline : ChartPalette.gridline
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(color))
            }
        }
    }

    private func column(day: Int, scale: AxisScale) -> some View {
        let pieces = report.stack(forDay: day)
        let total = report.dayTotals[day]
        return VStack(spacing: 4) {
            Spacer(minLength: 0)
            if total > 0 {
                Text(TimeFormatter.duration(total))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(ChartPalette.secondaryInk)
                    .fixedSize()
            }
            VStack(spacing: gap) {
                // Top of the stack first; the largest task sits on the baseline.
                ForEach(Array(pieces.enumerated().reversed()), id: \.offset) { index, piece in
                    let height = max(1.5, CGFloat(piece.seconds / scale.top) * plotHeight - gap)
                    UnevenRoundedRectangle(
                        topLeadingRadius: index == pieces.count - 1 ? 4 : 0,
                        topTrailingRadius: index == pieces.count - 1 ? 4 : 0,
                        style: .continuous
                    )
                    .fill(ChartPalette.series(piece.slot))
                    .frame(width: barWidth, height: height)
                    .help("\(piece.name) — \(TimeFormatter.duration(piece.seconds))")
                }
            }
        }
        .frame(height: plotHeight)
    }

    private func dayLabel(_ day: Int) -> some View {
        let date = report.days[day].start
        let isToday = calendar.isDateInToday(date)
        return VStack(spacing: 1) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: 11, weight: isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? ChartPalette.primaryInk : ChartPalette.secondaryInk)
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(ChartPalette.mutedInk)
        }
    }

    private var legend: some View {
        let colored = report.rows.filter { $0.slot != nil }
        let hasOther = report.rows.contains { $0.slot == nil }
        return FlowRow(spacing: 14) {
            ForEach(colored) { row in
                LegendItem(name: row.name, slot: row.slot)
            }
            if hasOther {
                LegendItem(name: "Other", slot: nil)
            }
        }
        .padding(.leading, 36)
    }
}

private struct LegendItem: View {
    var name: String
    var slot: Int?

    var body: some View {
        HStack(spacing: 6) {
            Swatch(slot: slot)
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(ChartPalette.secondaryInk)
                .lineLimit(1)
        }
    }
}

/// Hour-based y-axis with clean steps and headroom for the cap labels.
private struct AxisScale {
    let step: TimeInterval
    let top: TimeInterval

    init(maxValue: TimeInterval) {
        let steps: [TimeInterval] = [0.25, 0.5, 1, 2, 3, 4, 6, 12].map { $0 * 3600 }
        let padded = max(maxValue * 1.18, 900)
        let step = steps.first { padded / $0 <= 4 } ?? 12 * 3600
        self.step = step
        top = (padded / step).rounded(.up) * step
    }

    var ticks: [TimeInterval] {
        stride(from: 0, through: top + 1, by: step).map { $0 }
    }

    func label(_ seconds: TimeInterval) -> String {
        if seconds == 0 { return "0" }
        let hours = seconds / 3600
        return hours >= 1 ? "\(hours.formatted(.number.precision(.fractionLength(0...1))))h" : "\(Int(seconds / 60))m"
    }
}

/// Wraps children onto new lines like text.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: maxX, height: y + lineHeight), origins)
    }
}

// MARK: - Task × day grid

private struct TaskGrid: View {
    var report: TimesheetReport
    var calendar: Calendar
    var onRename: (TimesheetReport.Row) -> Void

    @State private var hovered: String?

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Text("Task").gridColumnAlignment(.leading)
                ForEach(0..<7, id: \.self) { day in
                    Text(report.days[day].start.formatted(.dateTime.weekday(.abbreviated)))
                }
                Text("Total")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ChartPalette.mutedInk)
            .padding(.bottom, 8)

            divider

            ForEach(report.rows) { row in
                GridRow {
                    HStack(spacing: 8) {
                        Swatch(slot: row.slot)
                        Text(row.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(ChartPalette.primaryInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(0..<7, id: \.self) { day in
                        cell(row.perDay[day])
                    }
                    cell(row.total, emphasized: true)
                }
                .font(.system(size: 12.5))
                .padding(.vertical, 7)
                .background(hovered == row.id ? Color.primary.opacity(0.04) : .clear)
                .onHover { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
                .contextMenu {
                    Button("Rename Task…") { onRename(row) }
                }
                divider
            }

            GridRow {
                Text("Total").gridColumnAlignment(.leading)
                ForEach(0..<7, id: \.self) { day in
                    cell(report.dayTotals[day], emphasized: true)
                }
                cell(report.total, emphasized: true)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(ChartPalette.primaryInk)
            .padding(.top, 8)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(ChartPalette.gridline)
            .frame(height: 1)
            .gridCellUnsizedAxes(.horizontal)
    }

    private func cell(_ seconds: TimeInterval, emphasized: Bool = false) -> some View {
        Text(seconds > 0 ? TimeFormatter.duration(seconds) : "–")
            .monospacedDigit()
            .foregroundStyle(seconds > 0 ? (emphasized ? ChartPalette.primaryInk : ChartPalette.secondaryInk) : ChartPalette.mutedInk)
            .frame(minWidth: 62, alignment: .trailing)
    }
}

// MARK: - Session log

private struct SessionLog: View {
    var report: TimesheetReport
    var days: [Int]
    var liveID: Session.ID?
    var selectedID: Session.ID?
    var onSelect: (Session) -> Void
    var onEdit: (Session) -> Void
    var onDelete: (Session) -> Void

    var body: some View {
        let shown = days.filter { !report.sessionsByDay[$0].isEmpty }
        VStack(alignment: .leading, spacing: 18) {
            if shown.isEmpty, let day = days.first {
                Text("Nothing logged on \(report.days[day].start.formatted(.dateTime.weekday(.wide))). Press N to add an entry.")
                    .font(.system(size: 12))
                    .foregroundStyle(ChartPalette.mutedInk)
            }
            ForEach(shown, id: \.self) { day in
                daySection(day)
            }
        }
    }

    private func daySection(_ day: Int) -> some View {
        let interval = report.days[day]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(interval.start.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(ChartPalette.primaryInk)
                Spacer()
                Text(TimeFormatter.duration(report.dayTotals[day]))
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ChartPalette.primaryInk)
            }
            .padding(.bottom, 2)
            ForEach(report.sessionsByDay[day].reversed()) { session in
                SessionRow(
                    session: session,
                    seconds: session.duration(in: interval),
                    slot: report.slot(for: session.task),
                    isLive: session.id == liveID,
                    isSelected: session.id == selectedID,
                    onSelect: { onSelect(session) },
                    onEdit: { onEdit(session) },
                    onDelete: { onDelete(session) }
                )
                .id(session.id)
            }
        }
    }
}

private struct SessionRow: View {
    var session: Session
    var seconds: TimeInterval
    var slot: Int?
    var isLive: Bool
    var isSelected: Bool
    var onSelect: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(timeRange)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(ChartPalette.mutedInk)
                .frame(width: 104, alignment: .leading)
            Swatch(slot: slot)
            Text(session.displayTask)
                .font(.system(size: 12.5))
                .foregroundStyle(ChartPalette.primaryInk)
                .lineLimit(1)
            modeBadge
            Spacer(minLength: 8)
            if isHovering && !isLive {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit")
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete")
            }
            Text(TimeFormatter.duration(seconds))
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(ChartPalette.secondaryInk)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { if !isLive { onEdit() } }
        .onTapGesture { onSelect() }
        .contextMenu {
            if !isLive {
                Button("Edit…", action: onEdit)
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }

    private var timeRange: String {
        let start = session.start.formatted(date: .omitted, time: .shortened)
        let end = isLive ? "now" : session.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    @ViewBuilder private var modeBadge: some View {
        if isLive {
            badge("live", systemImage: "record.circle")
        } else if session.isManual == true {
            badge("added manually", systemImage: "hand.point.up.left")
        } else if session.mode == .countUp {
            badge("count up", systemImage: "stopwatch")
        } else if let planned = session.planned {
            badge("\(Int(planned / 60))m timer" + (session.completed ? "" : " · stopped early"),
                  systemImage: session.completed ? "checkmark.circle" : "timer")
        }
    }

    private func badge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 10.5))
            .foregroundStyle(ChartPalette.mutedInk)
            .labelStyle(.titleAndIcon)
    }
}

// MARK: - Editor

struct SessionDraft: Identifiable {
    let id: UUID
    var original: Session?
    var task: String
    var start: Date
    var minutes: Int

    init(_ session: Session) {
        id = session.id
        original = session
        task = session.task
        start = session.start
        minutes = max(1, Int((session.duration / 60).rounded()))
    }

    init(task: String, start: Date, minutes: Int) {
        id = UUID()
        original = nil
        self.task = task
        self.start = start
        self.minutes = minutes
    }
}

private struct SessionEditor: View {
    @State var draft: SessionDraft
    var recentTasks: [String]
    var onSave: (Session) -> Void
    var onDelete: (Session.ID) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var taskFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.original == nil ? "Add Entry" : "Edit Entry")
                .font(.headline)
                .padding([.top, .horizontal], 20)

            Form {
                HStack {
                    TextField("Task", text: $draft.task, prompt: Text("What were you working on?"))
                        .focused($taskFocused)
                    if !recentTasks.isEmpty {
                        Menu {
                            ForEach(recentTasks, id: \.self) { task in
                                Button(task) { draft.task = task }
                            }
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Recent tasks")
                    }
                }
                DatePicker("Started", selection: $draft.start)
                HStack {
                    TextField("Duration", value: $draft.minutes, format: .number)
                        .frame(width: 140)
                    Text("min").foregroundStyle(.secondary)
                    Stepper("", value: $draft.minutes, in: 1...1440, step: 5).labelsHidden()
                }
                LabeledContent("Ends") {
                    Text(endDate.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            // ↩ in any field saves; the focused field eats the key before the default button sees it.
            .onSubmit(save)

            HStack {
                if let original = draft.original {
                    Button("Delete", role: .destructive) {
                        onDelete(original.id)
                        dismiss()
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help("⌘⌫")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.minutes < 1)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        .onAppear { taskFocused = true }
    }

    private func save() {
        guard draft.minutes >= 1 else { return }
        onSave(makeSession())
        dismiss()
    }

    private var endDate: Date { draft.start.addingTimeInterval(TimeInterval(max(1, draft.minutes) * 60)) }

    private func makeSession() -> Session {
        let task = TimeLog.clean(draft.task)
        if var session = draft.original {
            session.task = task
            // Keep the real stretches (and their pauses) unless the times were edited.
            let originalMinutes = max(1, Int((session.duration / 60).rounded()))
            if session.start != draft.start || originalMinutes != draft.minutes {
                session.segments = [Segment(start: draft.start, end: endDate)]
            }
            return session
        }
        return Session(id: draft.id, task: task, mode: .countUp, planned: nil, completed: false,
                       segments: [Segment(start: draft.start, end: endDate)], isManual: true)
    }
}
