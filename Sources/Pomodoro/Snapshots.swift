import AppKit

/// Developer tool: `make snapshots` launches the app with POMODORO_SNAPSHOT_DIR
/// set, renders each window to a PNG, then quits. Handy for reviewing UI
/// changes without screen-recording permission.
@MainActor
enum Snapshots {
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["POMODORO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func capture(_ window: NSWindow, name: String, background: NSColor = NSColor(calibratedRed: 0.22, green: 0.17, blue: 0.26, alpha: 1)) {
        guard let dir = outputDirectory, let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        write(rep, size: view.bounds.size, name: name, background: background, dir: dir)
    }

    static func capture(_ image: NSImage, name: String, background: NSColor) {
        guard let dir = outputDirectory, let rep = image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)) else { return }
        write(rep, size: image.size, name: name, background: background, dir: dir)
    }

    /// Composites over a solid backdrop, since blur materials don't render offscreen.
    private static func write(_ rep: NSBitmapImageRep, size: NSSize, name: String, background: NSColor, dir: URL) {
        let pad: CGFloat = 16
        let canvas = NSImage(size: NSSize(width: size.width + pad * 2, height: size.height + pad * 2), flipped: false) { rect in
            background.setFill()
            rect.fill()
            rep.draw(in: NSRect(x: pad, y: pad, width: size.width, height: size.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        guard let tiff = canvas.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}

extension Snapshots {
    /// Fills an empty (temporary) log with a plausible week so the timesheet
    /// snapshot has something to show. Only used by `make snapshots`.
    static func seedDemoData(into log: TimeLog) {
        guard log.sessions.isEmpty else { return }
        let calendar = Calendar.current
        let week = TimesheetReport.week(containing: Date(), calendar: calendar)
        let plan: [[(String, Double, Int, TimerModel.Mode)]] = [
            [("Email & Slack", 9, 30, .countUp), ("Q4 planning doc", 9.5, 90, .countdown), ("Break", 11, 15, .countUp),
             ("Code review", 11.25, 75, .countUp), ("Break", 12.5, 45, .countUp), ("1:1 with Sam", 13.5, 30, .countdown),
             ("Code review", 14, 60, .countUp), ("Break", 15, 15, .countUp), ("Q4 planning doc", 15.25, 90, .countdown)],
            [("Email & Slack", 9, 25, .countUp), ("Incident response", 9.5, 150, .countUp), ("Break", 12, 45, .countUp),
             ("Incident response", 12.75, 60, .countUp), ("Q4 planning doc", 15, 45, .countdown)],
            [("Email & Slack", 8.75, 20, .countUp), ("Q4 planning doc", 9.1, 100, .countdown), ("Break", 10.9, 15, .countUp),
             ("Hiring loop", 11.2, 45, .countdown), ("Email & Slack", 12, 10, .countUp)],
            [("Gifting prospects", 0.38, 20, .countUp), ("Email & Slack", 9, 30, .countUp), ("Roadmap sync", 11, 45, .countdown),
             ("Break", 11.75, 20, .countUp), ("Q4 planning doc", 13, 100, .countdown)],
            [("Code review", 10, 60, .countUp), ("Expenses", 14, 15, .countdown), ("Learning: Swift Charts", 15, 45, .countUp)],
        ]
        for (dayOffset, entries) in plan.enumerated() {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: week.start), day < Date() else { continue }
            for (task, hour, minutes, mode) in entries {
                let start = calendar.startOfDay(for: day).addingTimeInterval(hour * 3600)
                let end = start.addingTimeInterval(TimeInterval(minutes * 60))
                guard end < Date() else { continue }
                log.insert(Session(task: task, mode: mode, planned: mode == .countdown ? TimeInterval(minutes * 60) : nil,
                                   completed: mode == .countdown, segments: [Segment(start: start, end: end)]))
            }
        }
    }
}
