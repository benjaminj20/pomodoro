import AppKit
import UserNotifications

/// Sound + notification when a timer reaches zero.
@MainActor
enum Completion {
    static let systemSounds: [String] = {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/System/Library/Sounds"),
            includingPropertiesForKeys: nil
        )) ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }()

    private static var currentSound: NSSound?

    static func timerFinished(minutes: Int, prefs: Preferences) {
        playSound(named: prefs.soundName)
        if prefs.showNotification { postNotification(minutes: minutes) }
    }

    static func playSound(named name: String) {
        guard !name.isEmpty else { return }
        currentSound?.stop()
        currentSound = NSSound(named: NSSound.Name(name))
        currentSound?.play()
    }

    /// UserNotifications only works from a real .app bundle (not `swift run`).
    private static var canNotify: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func postNotification(minutes: Int) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time's up"
        content.body = "Your \(minutes)-minute timer is done."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
