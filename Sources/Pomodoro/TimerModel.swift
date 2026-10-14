import Foundation

/// Gets told about every running stretch so the time can be logged.
@MainActor
protocol SessionRecorder: AnyObject {
    func sessionStarted(mode: TimerModel.Mode, planned: TimeInterval?)
    func stretchStarted(at date: Date)
    func stretchEnded(at date: Date)
    func sessionEnded(completed: Bool)
}

/// The single source of truth for the timer, in both countdown and count-up modes.
///
/// Time is tracked as wall-clock running stretches rather than by counting ticks,
/// so it stays accurate across sleep/wake and busy run loops, and the exact
/// worked time (pauses excluded) can be logged to the timesheet.
@MainActor
final class TimerModel: ObservableObject {
    enum Phase: Equatable {
        case idle      // showing the selected duration, ready to start
        case running
        case paused
        case finished  // countdown hit 00:00, waiting to be acknowledged
    }

    enum Mode: String, Codable {
        case countdown
        case countUp
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var mode: Mode = .countdown
    /// The selected countdown duration, in seconds.
    @Published private(set) var duration: TimeInterval
    /// Time actually spent running in the current session (pauses excluded).
    @Published private(set) var elapsed: TimeInterval = 0

    weak var recorder: SessionRecorder?
    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?
    var onDurationChange: ((Int) -> Void)?

    /// Elapsed time banked from earlier running stretches.
    private var banked: TimeInterval = 0
    private var runningSince: Date?
    /// Countdown ends when `elapsed` reaches this.
    private var target: TimeInterval = 0
    private var ticker: Timer?

    init(minutes: Int) {
        duration = TimeInterval(max(1, minutes) * 60)
    }

    var minutes: Int { Int(duration / 60) }
    var isRunning: Bool { phase == .running }
    var isActive: Bool { phase == .running || phase == .paused }
    var isCountingUp: Bool { isActive && mode == .countUp }

    /// Seconds left on an active countdown.
    var remaining: TimeInterval { max(0, target - elapsed) }

    /// What the clocks should show right now.
    var displaySeconds: TimeInterval {
        switch phase {
        case .idle: duration
        case .finished: 0
        case .running, .paused: mode == .countUp ? elapsed : remaining
        }
    }

    // MARK: - Actions

    /// Changes the selected countdown duration. During an active countdown
    /// this also resets what's left to the new value, so dragging the slider
    /// mid-session works. A running count-up is unaffected.
    func setMinutes(_ minutes: Int) {
        duration = TimeInterval(max(1, minutes) * 60)
        switch phase {
        case .idle, .finished:
            phase = .idle
        case .running, .paused:
            if mode == .countdown { target = currentElapsed() + duration }
        }
        onDurationChange?(minutes)
    }

    /// Starts a countdown of the selected duration (or resumes if paused).
    func start() {
        if phase == .paused && mode == .countdown { resume(); return }
        if isActive { stop() }
        begin(.countdown)
    }

    /// Starts an open-ended stopwatch for tasks of unknown length.
    func startCountUp() {
        if isActive { stop() }
        begin(.countUp)
    }

    func pause() {
        guard phase == .running else { return }
        closeStretch(at: Date())
        phase = .paused
        stopTicker()
    }

    func resume() {
        guard phase == .paused else { return }
        openStretch()
        phase = .running
    }

    /// Ends the session (logging the time spent) and shows the selected duration again.
    func stop() {
        guard isActive else {
            acknowledgeFinish()
            return
        }
        if phase == .running { closeStretch(at: Date()) }
        stopTicker()
        recorder?.sessionEnded(completed: false)
        resetToIdle()
    }

    /// Start / pause / resume — whatever makes sense from the current phase.
    func toggle() {
        switch phase {
        case .idle, .finished: start()
        case .running: pause()
        case .paused: resume()
        }
    }

    func acknowledgeFinish() {
        guard phase == .finished else { return }
        resetToIdle()
    }

    // MARK: - Internals

    private func begin(_ newMode: Mode) {
        mode = newMode
        banked = 0
        elapsed = 0
        target = duration
        recorder?.sessionStarted(mode: newMode, planned: newMode == .countdown ? duration : nil)
        openStretch()
        phase = .running
        onStart?()
    }

    private func resetToIdle() {
        phase = .idle
        mode = .countdown
        banked = 0
        elapsed = 0
        runningSince = nil
    }

    private func openStretch() {
        let now = Date()
        runningSince = now
        recorder?.stretchStarted(at: now)
        startTicker()
    }

    private func closeStretch(at date: Date) {
        guard let runningSince else { return }
        banked += max(0, date.timeIntervalSince(runningSince))
        elapsed = banked
        self.runningSince = nil
        recorder?.stretchEnded(at: date)
    }

    private func currentElapsed(now: Date = Date()) -> TimeInterval {
        banked + (runningSince.map { now.timeIntervalSince($0) } ?? 0)
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        // .common so the clock keeps updating while menus are being tracked.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard phase == .running, let runningSince else { return }
        let now = Date()
        let current = currentElapsed(now: now)

        if mode == .countdown && current >= target {
            // Log exactly up to the moment it hit zero, not the tick after.
            let finishedAt = runningSince.addingTimeInterval(target - banked)
            closeStretch(at: min(finishedAt, now))
            stopTicker()
            elapsed = target
            phase = .finished
            recorder?.sessionEnded(completed: true)
            onFinish?()
            return
        }

        // Only publish when the visible second changes.
        let visible = mode == .countUp ? floor(current) : ceil(target - current)
        let shown = mode == .countUp ? floor(elapsed) : ceil(target - elapsed)
        if visible != shown { elapsed = current }
    }
}

enum TimeFormatter {
    /// 1500 → "25:00", 59 → "00:59", 7200 → "120:00". Count-up passes
    /// `roundUp: false` so it ticks 00:00 → 00:01 like a stopwatch.
    static func clock(_ seconds: TimeInterval, roundUp: Bool = true) -> String {
        let value = max(0, seconds)
        let total = Int(roundUp ? ceil(value) : floor(value))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// 1500 → "25m", 45 → "45s"
    static func compact(_ seconds: TimeInterval, roundUp: Bool = true) -> String {
        let value = max(0, seconds)
        let total = Int(roundUp ? ceil(value) : floor(value))
        if total < 60 { return "\(total)s" }
        let minutes = roundUp ? Int(ceil(Double(total) / 60)) : total / 60
        return "\(minutes)m"
    }

    /// Timesheet durations: 5400 → "1h 30m", 1500 → "25m", 20 → "<1m".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes == 0 { return seconds > 0 ? "<1m" : "0m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}

extension TimerModel {
    /// The clock string, rounded the right way for the current mode.
    var clockText: String {
        TimeFormatter.clock(displaySeconds, roundUp: !(isActive && mode == .countUp))
    }
}
