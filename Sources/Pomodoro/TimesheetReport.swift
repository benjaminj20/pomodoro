import Foundation

/// A week of sessions rolled up by day and by task — and by category, once
/// you have any.
struct TimesheetReport {
    struct Row: Identifiable {
        let id: String          // grouping key (lowercased task)
        var name: String        // most recent spelling
        var perDay: [TimeInterval]
        var total: TimeInterval
        /// Chart color slot; nil means it's folded into "Other".
        var slot: Int?
        /// Where the task is filed; nil = unsorted.
        var placement: TaskClassifier.Placement?
    }

    /// A category's tasks for the week, or the unsorted ones.
    struct Group: Identifiable {
        let id: String          // category ID, or `unsortedID`
        var name: String
        var slot: Int?
        var perDay: [TimeInterval]
        var total: TimeInterval
        var rows: [Row]

        var isUnsorted: Bool { id == TimesheetReport.unsortedID }
        var isPersonal: Bool { id == DefaultCategories.personalID }
    }

    /// Categorical colors available before tasks fold into "Other".
    static let colorSlots = 7
    static let unsortedID = "unsorted"

    let week: DateInterval
    let days: [DateInterval]
    let rows: [Row]
    /// Empty until you create a category; then every task sits in one group.
    let groups: [Group]
    let dayTotals: [TimeInterval]
    let total: TimeInterval
    let sessionsByDay: [[Session]]
    let sessionCount: Int

    init(sessions: [Session], week: DateInterval, calendar: Calendar,
         categories: [Categories.Category] = [],
         placement: (String) -> TaskClassifier.Placement? = { _ in nil }) {
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

        if categories.isEmpty {
            for index in sorted.indices {
                sorted[index].slot = index < Self.colorSlots ? index : nil
            }
            groups = []
        } else {
            let known = Set(categories.map(\.id))
            for index in sorted.indices {
                let placement = placement(sorted[index].name)
                sorted[index].placement = placement.flatMap { known.contains($0.categoryID) ? $0 : nil }
            }
            // Colors follow the category, not the task: this week's biggest work
            // categories get them first, then personal time; the rest are "Other".
            var totals: [String: TimeInterval] = [:]
            for row in sorted { if let id = row.placement?.categoryID { totals[id, default: 0] += row.total } }
            let colored = categories.filter { totals[$0.id] != nil }.sorted {
                let personal0 = $0.id == DefaultCategories.personalID, personal1 = $1.id == DefaultCategories.personalID
                if personal0 != personal1 { return personal1 }
                return totals[$0.id]! > totals[$1.id]!
            }
            let slots = Dictionary(uniqueKeysWithValues: colored.enumerated().map {
                ($0.element.id, $0.offset < Self.colorSlots ? $0.offset : nil)
            })
            var groupsByID: [String: Group] = [:]
            for index in sorted.indices {
                let id = sorted[index].placement?.categoryID ?? Self.unsortedID
                sorted[index].slot = slots[id] ?? nil
                let name = categories.first { $0.id == id }?.name ?? "Unsorted"
                var group = groupsByID[id] ?? Group(id: id, name: name, slot: slots[id] ?? nil,
                                                    perDay: Array(repeating: 0, count: 7), total: 0, rows: [])
                group.rows.append(sorted[index])
                for day in 0..<7 { group.perDay[day] += sorted[index].perDay[day] }
                group.total += sorted[index].total
                groupsByID[id] = group
            }
            // Biggest first, but personal time and Unsorted sit at the bottom.
            groups = groupsByID.values.sorted {
                if $0.isUnsorted != $1.isUnsorted { return $1.isUnsorted }
                if $0.isPersonal != $1.isPersonal { return $1.isPersonal }
                return $0.total != $1.total ? $0.total > $1.total : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }

        rows = sorted
        dayTotals = (0..<7).map { day in sorted.reduce(0) { $0 + $1.perDay[day] } }
        total = dayTotals.reduce(0, +)
        sessionsByDay = byDay
        sessionCount = count
    }

    var activeDayCount: Int { dayTotals.filter { $0 > 0 }.count }
    var usesCategories: Bool { !groups.isEmpty }

    /// The biggest work category (or task, without categories), for the stat tile.
    var top: (name: String, total: TimeInterval)? {
        if usesCategories {
            return groups.first { !$0.isUnsorted && !$0.isPersonal }.map { ($0.name, $0.total) }
        }
        return rows.first.map { ($0.name, $0.total) }
    }

    func slot(for task: String) -> Int? {
        rows.first { $0.id == TimeLog.key(task) }?.slot
    }

    /// What the chart stacks and the legend lists: categories, or tasks without them.
    var series: [(name: String, slot: Int?, perDay: [TimeInterval])] {
        usesCategories ? groups.map { ($0.name, $0.slot, $0.perDay) } : rows.map { ($0.name, $0.slot, $0.perDay) }
    }

    /// Name for everything without a color of its own.
    var otherName: String {
        usesCategories && series.allSatisfy({ $0.slot != nil || $0.name == "Unsorted" }) ? "Unsorted" : "Other"
    }

    /// Stacked pieces for one day's column: colored series in order, then "Other".
    func stack(forDay day: Int) -> [(name: String, slot: Int?, seconds: TimeInterval)] {
        var pieces: [(name: String, slot: Int?, seconds: TimeInterval)] = []
        var other: TimeInterval = 0
        for item in series where item.perDay[day] > 0 {
            if let slot = item.slot {
                pieces.append((item.name, slot, item.perDay[day]))
            } else {
                other += item.perDay[day]
            }
        }
        if other > 0 { pieces.append((otherName, nil, other)) }
        return pieces
    }

    static func week(containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 7 * 86_400)
    }
}
