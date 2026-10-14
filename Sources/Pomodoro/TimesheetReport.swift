import Foundation

/// A week of sessions rolled up by day and by task.
struct TimesheetReport {
    struct Row: Identifiable {
        let id: String          // grouping key (lowercased task)
        var name: String        // most recent spelling
        var perDay: [TimeInterval]
        var total: TimeInterval
        /// Chart color slot; nil means it's folded into "Other".
        var slot: Int?
    }

    /// Categorical colors available before tasks fold into "Other".
    static let colorSlots = 7

    let week: DateInterval
    let days: [DateInterval]
    let rows: [Row]
    let dayTotals: [TimeInterval]
    let total: TimeInterval
    let sessionsByDay: [[Session]]
    let sessionCount: Int

    init(sessions: [Session], week: DateInterval, calendar: Calendar) {
        self.week = week
        days = (0..<7).map { offset in
            let start = calendar.date(byAdding: .day, value: offset, to: week.start)!
            let end = calendar.date(byAdding: .day, value: offset + 1, to: week.start)!
            return DateInterval(start: start, end: end)
        }

        var rowsByKey: [String: Row] = [:]
        var byDay = Array(repeating: [Session](), count: 7)
        var count = 0

        // Sessions arrive sorted by start, so later spellings win.
        for session in sessions where session.end > week.start && session.start < week.end {
            var counted = false
            let key = TimeLog.key(session.task)
            for (index, day) in days.enumerated() {
                let seconds = session.duration(in: day)
                guard seconds > 0 else { continue }
                var row = rowsByKey[key] ?? Row(id: key, name: session.displayTask, perDay: Array(repeating: 0, count: 7), total: 0)
                row.name = session.displayTask
                row.perDay[index] += seconds
                row.total += seconds
                rowsByKey[key] = row
                byDay[index].append(session)
                counted = true
            }
            if counted { count += 1 }
        }

        var sorted = rowsByKey.values.sorted {
            $0.total != $1.total ? $0.total > $1.total : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        for index in sorted.indices {
            sorted[index].slot = index < Self.colorSlots ? index : nil
        }

        rows = sorted
        dayTotals = (0..<7).map { day in sorted.reduce(0) { $0 + $1.perDay[day] } }
        total = dayTotals.reduce(0, +)
        sessionsByDay = byDay
        sessionCount = count
    }

    var activeDayCount: Int { dayTotals.filter { $0 > 0 }.count }

    func slot(for task: String) -> Int? {
        rows.first { $0.id == TimeLog.key(task) }?.slot
    }

    /// Stacked pieces for one day's column: colored tasks in row order, then "Other".
    func stack(forDay day: Int) -> [(name: String, slot: Int?, seconds: TimeInterval)] {
        var pieces: [(name: String, slot: Int?, seconds: TimeInterval)] = []
        var other: TimeInterval = 0
        for row in rows where row.perDay[day] > 0 {
            if let slot = row.slot {
                pieces.append((row.name, slot, row.perDay[day]))
            } else {
                other += row.perDay[day]
            }
        }
        if other > 0 { pieces.append(("Other", nil, other)) }
        return pieces
    }

    static func week(containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 7 * 86_400)
    }
}
