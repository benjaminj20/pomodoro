import AppKit
import Foundation

/// One stretch of uninterrupted running time.
struct Segment: Codable, Equatable {
    var start: Date
    var end: Date

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    func overlap(with interval: DateInterval) -> TimeInterval {
        let lower = max(start, interval.start), upper = min(end, interval.end)
        return max(0, upper.timeIntervalSince(lower))
    }
}

/// A logged block of work: what you were doing and when it was running.
struct Session: Codable, Identifiable, Equatable {
    var id = UUID()
    var task: String
    var mode: TimerModel.Mode
    /// Countdown length, if it was a countdown.
    var planned: TimeInterval?
    /// True if a countdown ran all the way to zero.
    var completed: Bool
    var segments: [Segment]
    /// Added by hand in the timesheet rather than timed.
    var isManual: Bool? = nil

    var start: Date { segments.first?.start ?? .distantPast }
    var end: Date { segments.last?.end ?? start }
    var duration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }

    var displayTask: String { TimeLog.displayName(task) }

    func duration(in interval: DateInterval) -> TimeInterval {
        segments.reduce(0) { $0 + $1.overlap(with: interval) }
    }
}

/// Records every timer session to disk so you can review where your time went.
///
/// Data lives in `~/Library/Application Support/Pomodoro/timesheet.json`.
/// The in-progress session is checkpointed separately so a crash or force-quit
/// loses at most a few seconds.
@MainActor
final class TimeLog: ObservableObject, SessionRecorder {
    /// Sessions shorter than this are treated as accidental starts.
    nonisolated static let minimumDuration: TimeInterval = 30
    nonisolated static let untitled = "Untitled"

    @Published private(set) var sessions: [Session] = []
    /// The session the timer is running right now (closed stretches only).
    @Published private(set) var active: Session?
    /// When the active session's current stretch began, if it's running.
    @Published private(set) var openSince: Date?

    /// The one-line description typed in the panel. Editing it while a timer
    /// is running renames the session in progress.
    @Published var currentTask: String {
        didSet {
            UserDefaults.app.set(currentTask, forKey: "currentTask")
            if active != nil {
                active?.task = Self.clean(currentTask)
                checkpoint()
            }
        }
    }

    let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("timesheet.json") }
    private var activeURL: URL { directory.appendingPathComponent("active-session.json") }
    private var checkpointTimer: Timer?

    init(directory: URL = TimeLog.defaultDirectory) {
        self.directory = directory
        currentTask = UserDefaults.app.string(forKey: "currentTask") ?? ""
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
        recoverCrashedSession()
    }

    nonisolated static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["POMODORO_DATA_DIR"] {
            return URL(fileURLWithPath: override)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Pomodoro", isDirectory: true)
    }

    // MARK: - SessionRecorder

    func sessionStarted(mode: TimerModel.Mode, planned: TimeInterval?) {
        active = Session(task: Self.clean(currentTask), mode: mode, planned: planned, completed: false, segments: [])
        startCheckpointing()
    }

    func stretchStarted(at date: Date) {
        openSince = date
        checkpoint()
    }

    func stretchEnded(at date: Date) {
        if let openSince, active != nil {
            active?.segments.append(Segment(start: openSince, end: max(date, openSince)))
        }
        openSince = nil
        checkpoint()
    }

    func sessionEnded(completed: Bool) {
        guard var session = active else { return }
        session.completed = completed
        active = nil
        openSince = nil
        stopCheckpointing()
        try? FileManager.default.removeItem(at: activeURL)
        if session.duration >= Self.minimumDuration {
            insert(session)
        }
    }

    // MARK: - Reading

    /// All sessions, including the one in progress up to `now`.
    func allSessions(now: Date = Date()) -> [Session] {
        guard let live = liveSession(now: now) else { return sessions }
        return sessions + [live]
    }

    func liveSession(now: Date = Date()) -> Session? {
        guard var session = active else { return nil }
        if let openSince { session.segments.append(Segment(start: openSince, end: max(now, openSince))) }
        return session.segments.isEmpty ? nil : session
    }

    /// Most recently used distinct task names, newest first.
    func recentTasks(limit: Int = 8) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for session in sessions.reversed() where !session.task.isEmpty {
            let key = Self.key(session.task)
            if seen.insert(key).inserted {
                result.append(session.task)
                if result.count == limit { break }
            }
        }
        return result
    }

    /// The default for a manual entry: from the minute after the last entry
    /// ended until now (or until the running timer started). Falls back to the
    /// last 30 minutes when nothing has been logged yet today.
    func untrackedGap(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, minutes: Int) {
        let end = liveSession(now: now)?.start ?? now
        let endMinute = calendar.dateInterval(of: .minute, for: end)?.start ?? end

        if let lastEnd = sessions.map(\.end).filter({ $0 <= end }).max(),
           calendar.isDate(lastEnd, inSameDayAs: end),
           let lastMinute = calendar.dateInterval(of: .minute, for: lastEnd)?.start {
            let start = lastMinute.addingTimeInterval(60)
            let minutes = Int(endMinute.timeIntervalSince(start) / 60)
            return (start, max(1, minutes))
        }
        return (endMinute.addingTimeInterval(-30 * 60), 30)
    }

    // MARK: - Editing

    func insert(_ session: Session) {
        sessions.append(session)
        sessions.sort { $0.start < $1.start }
        save()
    }

    func update(_ session: Session) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index] = session
        sessions.sort { $0.start < $1.start }
        save()
    }

    func delete(_ id: Session.ID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    /// Renames every session of a task (matching case-insensitively).
    func renameTask(_ old: String, to new: String) {
        let oldKey = Self.key(old), cleaned = Self.clean(new)
        for index in sessions.indices where Self.key(sessions[index].task) == oldKey {
            sessions[index].task = cleaned
        }
        save()
    }

    // MARK: - Export

    func csv(for sessions: [Session]) -> String {
        let date = Self.formatter("yyyy-MM-dd")
        let time = Self.formatter("HH:mm")
        var lines = ["Date,Start,End,Task,Minutes,Mode,Completed"]
        for s in sessions {
            let task = "\"" + s.displayTask.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let minutes = String(format: "%.1f", s.duration / 60)
            lines.append([date.string(from: s.start), time.string(from: s.start), time.string(from: s.end),
                          task, minutes, s.mode == .countUp ? "count up" : "countdown", s.completed ? "yes" : "no"]
                .joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: - Names

    nonisolated static func clean(_ task: String) -> String {
        task.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func displayName(_ task: String) -> String {
        let cleaned = clean(task)
        return cleaned.isEmpty ? untitled : cleaned
    }

    /// Grouping key: "Email", "email " and "EMAIL" are the same task.
    nonisolated static func key(_ task: String) -> String {
        displayName(task).lowercased()
    }

    // MARK: - Persistence

    private struct File: Codable {
        var version = 1
        var sessions: [Session]
    }

    private struct ActiveCheckpoint: Codable {
        var session: Session
        var openSince: Date?
        var lastSeen: Date
    }

    private nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(TimeLog.isoFormatter(fractional: true).string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = TimeLog.isoFormatter(fractional: true).date(from: string)
                ?? TimeLog.isoFormatter(fractional: false).date(from: string) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date: \(string)"))
        }
        return decoder
    }()

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            sessions = try Self.decoder.decode(File.self, from: data).sessions.sorted { $0.start < $1.start }
        } catch {
            // Never overwrite a file we couldn't read — keep a copy aside first.
            let backup = directory.appendingPathComponent("timesheet-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            NSLog("Pomodoro: couldn't read timesheet (\(error)); backed up to \(backup.path)")
        }
    }

    private func save() {
        do {
            let data = try Self.encoder.encode(File(sessions: sessions))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Pomodoro: couldn't save timesheet: \(error)")
        }
    }

    private func startCheckpointing() {
        stopCheckpointing()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkpoint() }
        }
        RunLoop.main.add(timer, forMode: .common)
        checkpointTimer = timer
    }

    private func stopCheckpointing() {
        checkpointTimer?.invalidate()
        checkpointTimer = nil
    }

    private func checkpoint() {
        guard let active else { return }
        let checkpoint = ActiveCheckpoint(session: active, openSince: openSince, lastSeen: Date())
        if let data = try? Self.encoder.encode(checkpoint) {
            try? data.write(to: activeURL, options: .atomic)
        }
    }

    /// If the app died mid-session, log it up to the last checkpoint.
    private func recoverCrashedSession() {
        guard let data = try? Data(contentsOf: activeURL),
              let checkpoint = try? Self.decoder.decode(ActiveCheckpoint.self, from: data) else { return }
        var session = checkpoint.session
        if let openSince = checkpoint.openSince {
            session.segments.append(Segment(start: openSince, end: max(checkpoint.lastSeen, openSince)))
        }
        try? FileManager.default.removeItem(at: activeURL)
        if session.duration >= Self.minimumDuration { insert(session) }
    }

    /// ISO 8601 with milliseconds, so reloaded sessions match exactly.
    private nonisolated static func isoFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
