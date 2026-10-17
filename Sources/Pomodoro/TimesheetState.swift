import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Everything the timesheet window is showing, plus the actions behind both
/// its buttons and its keyboard shortcuts.
@MainActor
final class TimesheetState: ObservableObject {
    let log: TimeLog
    let categories: Categories

    @Published var weekStart = Date() {
        didSet {
            if !calendar.isDate(weekStart, equalTo: oldValue, toGranularity: .weekOfYear) {
                selectedDay = nil
                selectedSessionID = nil
            }
        }
    }
    /// Day shown in the breakdown and log (0 = first day of the week); nil = today / automatic.
    @Published var selectedDay: Int? { didSet { if selectedDay != oldValue { selectedSessionID = nil } } }
    @Published var showOvernight = false
    /// The log shows just the selected day unless this is on.
    @Published var logShowsWeek = false
    @Published var selectedSessionID: Session.ID?

    // Sheets and alerts
    @Published var editing: SessionDraft?
    @Published var renaming: String?
    @Published var renameText = ""
    @Published var pendingDelete: Session?
    @Published var exportedURL: URL?
    @Published var exportError: String?
    @Published var namingCategory: CategoryNaming?
    @Published var categoryNameText = ""
    @Published var pendingCategoryDelete: Categories.Category?

    enum CategoryNaming: Equatable {
        /// A new category, optionally filing a task into it straight away.
        case new(task: String?)
        case rename(Categories.Category)
    }

    var calendar: Calendar { .current }
    var onShowShortcuts: (() -> Void)?
    weak var presentingWindow: NSWindow?

    init(log: TimeLog, categories: Categories) {
        self.log = log
        self.categories = categories
    }

    // MARK: - Derived

    var week: DateInterval { TimesheetReport.week(containing: weekStart, calendar: calendar) }
    var isCurrentWeek: Bool { week.contains(Date()) }

    func report(now: Date = Date()) -> TimesheetReport {
        TimesheetReport(sessions: log.allSessions(now: now), week: week, calendar: calendar,
                        categories: categories.list, placement: categories.placement(for:))
    }

    /// Today if it's in this week, otherwise the last day with anything logged.
    func resolvedDay(_ report: TimesheetReport, now: Date = Date()) -> Int {
        if let selectedDay { return selectedDay }
        if let today = report.days.firstIndex(where: { $0.contains(now) }) { return today }
        return report.dayTotals.lastIndex(where: { $0 > 0 }) ?? 0
    }

    /// Days the log lists, newest first.
    func logDays(_ report: TimesheetReport, now: Date = Date()) -> [Int] {
        logShowsWeek ? Array((0..<7).reversed()) : [resolvedDay(report, now: now)]
    }

    /// Sessions in the order the log shows them, for ↑/↓ selection.
    func logSessions(_ report: TimesheetReport, now: Date = Date()) -> [Session] {
        logDays(report, now: now).flatMap { report.sessionsByDay[$0].reversed() }
    }

    // MARK: - Navigation

    func shiftDay(_ delta: Int) {
        let current = resolvedDay(report())
        let next = current + delta
        if next < 0 {
            shiftWeek(-1)
            selectedDay = 6
        } else if next > 6 {
            shiftWeek(1)
            selectedDay = 0
        } else {
            selectedDay = next
        }
    }

    func shiftWeek(_ delta: Int) {
        weekStart = calendar.date(byAdding: .weekOfYear, value: delta, to: weekStart) ?? weekStart
    }

    func goToToday() {
        weekStart = Date()
        selectedDay = nil
    }

    func moveSelection(_ delta: Int) {
        let sessions = logSessions(report())
        guard !sessions.isEmpty else { return }
        guard let current = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == current }) else {
            selectedSessionID = (delta > 0 ? sessions.first : sessions.last)?.id
            return
        }
        selectedSessionID = sessions[min(max(index + delta, 0), sessions.count - 1)].id
    }

    // MARK: - Actions

    private var selectedSession: Session? {
        guard let id = selectedSessionID, id != log.active?.id else { return nil }
        return log.sessions.first { $0.id == id }
    }

    func edit(_ session: Session) {
        guard session.id != log.active?.id else { return }
        editing = SessionDraft(session)
    }

    func editSelected() {
        if let session = selectedSession { edit(session) }
    }

    func requestDelete(_ session: Session) {
        guard session.id != log.active?.id else { return }
        pendingDelete = session
    }

    func deleteSelected() {
        if let session = selectedSession { requestDelete(session) }
    }

    func confirmDelete() {
        guard let session = pendingDelete else { return }
        // Keep the selection on a neighbour so you can keep going with ↑/↓.
        let sessions = logSessions(report())
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            let neighbour = sessions.indices.contains(index + 1) ? sessions[index + 1] : (index > 0 ? sessions[index - 1] : nil)
            selectedSessionID = neighbour?.id
        }
        log.delete(session.id)
        pendingDelete = nil
    }

    func rename(task: String) {
        renameText = TimeLog.displayName(task)
        renaming = renameText
    }

    func renameSelected() {
        if let session = selectedSession { rename(task: session.task) }
    }

    func commitRename() {
        if let renaming {
            log.renameTask(renaming, to: renameText)
            categories.taskRenamed(from: renaming, to: renameText)
        }
        renaming = nil
    }

    // MARK: - Categories

    /// Files a task (nil = unsorted) — the classifier learns from every one.
    func file(_ task: String, in categoryID: String?) {
        categories.assign(task, to: categoryID)
    }

    func newCategory(for task: String?) {
        categoryNameText = ""
        namingCategory = .new(task: task)
    }

    func renameCategory(_ category: Categories.Category) {
        categoryNameText = category.name
        namingCategory = .rename(category)
    }

    func commitCategoryName() {
        switch namingCategory {
        case .new(let task):
            if let id = categories.create(named: categoryNameText), let task { file(task, in: id) }
        case .rename(let category):
            categories.rename(category.id, to: categoryNameText)
        case nil:
            break
        }
        namingCategory = nil
    }

    func confirmCategoryDelete() {
        if let category = pendingCategoryDelete { categories.delete(category.id) }
        pendingCategoryDelete = nil
    }

    /// 1–9 files the selected entry's task into that category; 0 unsorts it.
    private func fileSelected(number: Int) {
        guard let id = selectedSessionID, let session = log.allSessions().first(where: { $0.id == id }) else { return }
        if number == 0 {
            file(session.task, in: nil)
        } else if categories.list.indices.contains(number - 1) {
            file(session.task, in: categories.list[number - 1].id)
        }
    }

    /// Viewing today: the untracked gap between the last entry and now.
    /// Any other day: 9:00 that day.
    func addEntry() {
        let report = report()
        let day = report.days[resolvedDay(report)]
        if day.contains(Date()) {
            let gap = log.untrackedGap()
            editing = SessionDraft(task: log.currentTask, start: gap.start, minutes: gap.minutes)
        } else {
            let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day.start) ?? day.start
            editing = SessionDraft(task: log.currentTask, start: start, minutes: 30)
        }
    }

    func save(_ session: Session) {
        if log.sessions.contains(where: { $0.id == session.id }) {
            log.update(session)
        } else {
            log.insert(session)
        }
        selectedSessionID = session.id
    }

    func exportWeek() {
        let sessions = log.sessions.filter { $0.end > week.start && $0.start < week.end }
        export(sessions, name: "Timesheet \(Self.fileDate(week.start))")
    }

    func exportAll() {
        export(log.sessions, name: "Timesheet (all)")
    }

    private func export(_ sessions: [Session], name: String) {
        let panel = NSSavePanel()
        panel.title = "Export Timesheet"
        panel.message = "Choose where to save your CSV file."
        panel.prompt = "Export"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(name).csv"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.log.csv(for: sessions, category: { [categories = self.categories] task in
                    categories.category(categories.placement(for: task)?.categoryID)?.name
                }).write(to: url, atomically: true, encoding: .utf8)
                self.exportedURL = url
            } catch {
                self.exportError = "Could not save “\(url.lastPathComponent)”. \(error.localizedDescription)"
            }
        }
        if let presentingWindow {
            panel.beginSheetModal(for: presentingWindow, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    func revealExportInFinder() {
        guard let exportedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
    }

    private static func fileDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Keyboard

    /// Returns true if the key was handled. Only called when no text field,
    /// sheet or alert has the keyboard.
    func handleKey(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) -> Bool {
        let command = flags.contains(.command), shift = flags.contains(.shift)
        if command {
            switch characters?.lowercased() {
            case "n": addEntry()
            case "e": shift ? exportAll() : exportWeek()
            case "/": onShowShortcuts?()
            default: return false
            }
            return true
        }
        switch keyCode {
        case 123: shift ? shiftWeek(-1) : shiftDay(-1)   // ←
        case 124: shift ? shiftWeek(1) : shiftDay(1)     // →
        case 126: moveSelection(-1)                      // ↑
        case 125: moveSelection(1)                       // ↓
        case 36, 76: editSelected()                      // return
        case 51, 117: deleteSelected()                   // delete
        default:
            switch characters?.lowercased() {
            case "t": goToToday()
            case "n", "a": addEntry()
            case "r": renameSelected()
            case "w": logShowsWeek.toggle()
            case "?": onShowShortcuts?()
            case "[": shiftWeek(-1)
            case "]": shiftWeek(1)
            case let digit? where digit.count == 1 && digit.first!.isWholeNumber:
                fileSelected(number: digit.first!.wholeNumberValue!)
            default: return false
            }
        }
        return true
    }
}
