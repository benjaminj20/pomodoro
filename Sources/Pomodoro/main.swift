import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar only: no Dock icon, no app switcher entry.
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
