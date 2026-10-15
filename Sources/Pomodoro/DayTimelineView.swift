import SwiftUI

/// How one day played out: a lane per task, with a block for every stretch of
/// work placed at the time it happened. Repeat tasks (e.g. two breaks) share a lane.
struct DayTimeline: View {
    var report: TimesheetReport
    var day: Int
    var now: Date
    var calendar: Calendar
    @Binding var showOvernight: Bool

    private let laneHeight: CGFloat = 28
    private let barHeight: CGFloat = 16
    private let labelWidth: CGFloat = 200
    private let columnGap: CGFloat = 14

    struct Block: Identifiable {
        let id: String
        let start: Date
        let end: Date
    }

    struct Lane: Identifiable {
        let id: String
        var name: String
        var slot: Int?
        var blocks: [Block]
        var total: TimeInterval
    }

    var body: some View {
        let lanes = makeLanes()
        if lanes.isEmpty {
            Text("Nothing logged on \(dayDate.formatted(.dateTime.weekday(.wide))).")
                .font(.system(size: 12))
                .foregroundStyle(ChartPalette.mutedInk)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            let compact = TimeAxis(lanes: lanes, day: report.days[day], now: now, calendar: calendar, showOvernight: false)
            let axis = showOvernight
                ? TimeAxis(lanes: lanes, day: report.days[day], now: now, calendar: calendar, showOvernight: true)
                : compact
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: columnGap) {
                    laneLabels(lanes)
                    GeometryReader { geo in
                        plot(lanes, axis: axis, width: geo.size.width)
                    }
                    .frame(height: CGFloat(lanes.count) * laneHeight)
                }
                HStack(spacing: columnGap) {
                    Color.clear.frame(width: labelWidth, height: 1)
                    GeometryReader { geo in
                        ForEach(axis.ticks, id: \.self) { tick in
                            Text(axis.label(tick))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(ChartPalette.mutedInk)
                                .fixedSize()
                                .position(x: axis.x(tick, width: geo.size.width), y: 7)
                        }
                    }
                    .frame(height: 14)
                }
                if compact.isCollapsed {
                    HStack {
                        Spacer()
                        Button(showOvernight ? "Hide 1–8 am" : "Show 1–8 am") { showOvernight.toggle() }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
            }
        }
    }

    private var dayDate: Date { report.days[day].start }

    // MARK: Pieces

    private func laneLabels(_ lanes: [Lane]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lanes) { lane in
                HStack(spacing: 8) {
                    Swatch(slot: lane.slot)
                    Text(lane.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(ChartPalette.primaryInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(TimeFormatter.duration(lane.total))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(ChartPalette.mutedInk)
                }
                .frame(height: laneHeight)
            }
        }
        .frame(width: labelWidth)
    }

    private func plot(_ lanes: [Lane], axis: TimeAxis, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Hour gridlines.
            Canvas { context, size in
                for tick in axis.ticks {
                    let x = axis.x(tick, width: size.width).rounded() - 0.5
                    context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(ChartPalette.gridline))
                }
            }

            ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                ForEach(lane.blocks) { block in
                    let x = axis.x(block.start, width: width)
                    let blockWidth = max(3, axis.x(block.end, width: width) - x)
                    RoundedRectangle(cornerRadius: min(4, blockWidth / 2), style: .continuous)
                        .fill(ChartPalette.series(lane.slot))
                        .frame(width: blockWidth, height: barHeight)
                        .help(tooltip(lane: lane, block: block))
                        .offset(x: x, y: CGFloat(index) * laneHeight + (laneHeight - barHeight) / 2)
                }
            }

            if let breakX = axis.breakX(width: width) {
                nightBreak(height: CGFloat(lanes.count) * laneHeight)
                    .offset(x: breakX)
            }

            if let nowX = axis.nowX(width: width) {
                Rectangle()
                    .fill(ChartPalette.secondaryInk)
                    .frame(width: 1, height: CGFloat(lanes.count) * laneHeight)
                    .offset(x: nowX)
                    .help("Now")
            }
        }
        .frame(width: width, alignment: .topLeading)
    }

    /// The collapsed 1–8 am window: a narrow band you can click to expand.
    private func nightBreak(height: CGFloat) -> some View {
        Button { showOvernight = true } label: {
            ZStack {
                Rectangle().fill(ChartPalette.surface)
                Rectangle().fill(Color.primary.opacity(0.045))
                Image(systemName: "moon.zzz")
                    .font(.system(size: 9))
                    .foregroundStyle(ChartPalette.mutedInk)
            }
            .frame(width: TimeAxis.breakWidth, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("1–8 am hidden — click to show")
    }

    private func tooltip(lane: Lane, block: Block) -> String {
        let start = block.start.formatted(date: .omitted, time: .shortened)
        let end = block.end.formatted(date: .omitted, time: .shortened)
        return "\(lane.name) · \(start)–\(end) · \(TimeFormatter.duration(block.end.timeIntervalSince(block.start)))"
    }

    // MARK: Data

    /// One lane per task, ordered by when it first happened that day.
    private func makeLanes() -> [Lane] {
        let interval = report.days[day]
        var lanes: [Lane] = []
        var indexByKey: [String: Int] = [:]

        for session in report.sessionsByDay[day] {
            let key = TimeLog.key(session.task)
            for (n, segment) in session.segments.enumerated() {
                let start = max(segment.start, interval.start)
                let end = min(segment.end, interval.end)
                guard end > start else { continue }
                let block = Block(id: "\(session.id)-\(n)", start: start, end: end)
                if let index = indexByKey[key] {
                    lanes[index].blocks.append(block)
                    lanes[index].total += end.timeIntervalSince(start)
                    lanes[index].name = session.displayTask
                } else {
                    indexByKey[key] = lanes.count
                    lanes.append(Lane(id: key, name: session.displayTask, slot: report.slot(for: session.task),
                                      blocks: [block], total: end.timeIntervalSince(start)))
                }
            }
        }
        return lanes.sorted { ($0.blocks.map(\.start).min() ?? .distantFuture) < ($1.blocks.map(\.start).min() ?? .distantFuture) }
    }
}

/// Clock-time x-axis spanning the day's activity, snapped to whole hours.
/// The quiet overnight window (1–8 am) collapses into a narrow break unless
/// something was logged in it or you ask to see it.
private struct TimeAxis {
    struct Range {
        let start: Date
        let end: Date
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    static let quietHours = (start: 1, end: 8)
    static let breakWidth: CGFloat = 22

    let ranges: [Range]
    let ticks: [Date]
    let now: Date?

    var isCollapsed: Bool { ranges.count == 2 }

    init(lanes: [DayTimeline.Lane], day: DateInterval, now: Date, calendar: Calendar, showOvernight: Bool) {
        let blocks = lanes.flatMap(\.blocks)
        let isToday = day.contains(now)
        let first = blocks.map(\.start).min() ?? day.start
        var last = blocks.map(\.end).max() ?? day.end
        if isToday { last = max(last, now) }

        var start = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        var end = calendar.dateInterval(of: .hour, for: last.addingTimeInterval(-1))?.end ?? last
        // At least a few hours wide so short days don't stretch into fat blocks.
        let minimumSpan: TimeInterval = 4 * 3600
        if end.timeIntervalSince(start) < minimumSpan {
            end = min(start.addingTimeInterval(minimumSpan), day.end)
            if end.timeIntervalSince(start) < minimumSpan { start = max(day.start, end.addingTimeInterval(-minimumSpan)) }
        }

        var ranges = [Range(start: start, end: end)]
        let quietStart = calendar.date(byAdding: .hour, value: Self.quietHours.start, to: day.start)!
        let quietEnd = calendar.date(byAdding: .hour, value: Self.quietHours.end, to: day.start)!
        let quietIsEmpty = !blocks.contains { $0.end > quietStart && $0.start < quietEnd }
            && !(isToday && now > quietStart && now < quietEnd)

        if !showOvernight && quietIsEmpty && start < quietEnd && end > quietStart {
            if start < quietStart && end > quietEnd {
                ranges = [Range(start: start, end: quietStart), Range(start: quietEnd, end: end)]
            } else if start < quietStart {
                ranges = [Range(start: start, end: quietStart)]
            } else {
                ranges = [Range(start: max(start, quietEnd), end: max(end, quietEnd.addingTimeInterval(3600)))]
            }
        }
        self.ranges = ranges

        let visibleStart = ranges.first!.start, visibleEnd = ranges.last!.end
        self.now = isToday && now >= visibleStart && now <= visibleEnd ? now : nil

        let visibleHours = ranges.reduce(0) { $0 + $1.duration } / 3600
        let step = visibleHours > 12 ? 2 : 1
        ticks = ranges.flatMap { range in
            let hours = Int((range.duration / 3600).rounded())
            return stride(from: 0, through: hours, by: step).compactMap {
                calendar.date(byAdding: .hour, value: $0, to: range.start)
            }
        }
    }

    /// Horizontal position, skipping the collapsed window.
    func x(_ date: Date, width: CGFloat) -> CGFloat {
        let usable = width - (isCollapsed ? Self.breakWidth : 0)
        let total = ranges.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return 0 }
        var offset: CGFloat = 0
        for (index, range) in ranges.enumerated() {
            let rangeWidth = usable * CGFloat(range.duration / total)
            if date <= range.end || index == ranges.count - 1 {
                let clamped = min(max(date, range.start), range.end)
                return offset + rangeWidth * CGFloat(clamped.timeIntervalSince(range.start) / range.duration)
            }
            offset += rangeWidth + Self.breakWidth
        }
        return offset
    }

    /// Left edge of the collapsed-night break, if there is one.
    func breakX(width: CGFloat) -> CGFloat? {
        isCollapsed ? x(ranges[0].end, width: width) : nil
    }

    func nowX(width: CGFloat) -> CGFloat? {
        now.map { x($0, width: width) }
    }

    func label(_ date: Date) -> String {
        date.formatted(.dateTime.hour())
    }
}
