import AppKit
import Combine
import SwiftUI

/// Hover state shared between the AppKit container and the SwiftUI face.
@MainActor
final class FloatingHoverState: ObservableObject {
    @Published var isHovering = false
}

/// The always-on-top, draggable black timer.
@MainActor
final class FloatingTimerController {
    private let model: TimerModel
    private let prefs: Preferences
    private let hover = FloatingHoverState()
    private let panel: NSPanel
    private let container: FloatingContainerView
    private var cancellables = Set<AnyCancellable>()

    var isVisible: Bool { panel.isVisible }
    var window: NSWindow { panel }

    init(model: TimerModel, prefs: Preferences, log: TimeLog) {
        self.model = model
        self.prefs = prefs

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: FloatingTimerView(model: model, prefs: prefs, log: log, hover: hover))
        container = FloatingContainerView(hosting: hosting, hover: hover)
        panel.contentView = container

        container.onClose = { [weak self] in self?.close() }
        container.onDoubleClick = { [weak model] in model?.toggle() }

        // Grow/shrink to fit "05:00" vs "120:00" and the chosen size.
        model.$elapsed.map { _ in () }
            .merge(with: model.$phase.map { _ in () }, model.$duration.map { _ in () })
            .merge(with: prefs.$floatingSize.map { _ in () }, prefs.$floatingShowsTask.map { _ in () })
            .merge(with: log.$currentTask.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.resizeToFit() }
            .store(in: &cancellables)

        resizeToFit()
        restorePosition()
    }

    func show() {
        resizeToFit()
        panel.orderFrontRegardless()
    }

    func close() {
        model.acknowledgeFinish()
        panel.orderOut(nil)
    }

    private func resizeToFit() {
        let size = container.hosting.fittingSize
        guard size.width > 0, size != panel.frame.size else { return }
        // Keep the top-left corner pinned while the size changes.
        let frame = panel.frame
        let newFrame = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        panel.setFrame(newFrame, display: true)
    }

    private func restorePosition() {
        if !panel.setFrameUsingName(Self.autosaveName) {
            // First launch: top-right corner of the main screen.
            if let visible = NSScreen.main?.visibleFrame {
                let size = panel.frame.size
                panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24))
            }
        }
        panel.setFrameAutosaveName(Self.autosaveName)
    }

    private static let autosaveName = "FloatingTimer"
}

/// Catches all mouse input for the floating window: drag to move,
/// double-click to pause/resume, click the × (shown on hover) to close.
final class FloatingContainerView: NSView {
    let hosting: NSHostingView<FloatingTimerView>
    private let hover: FloatingHoverState
    var onClose: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    init(hosting: NSHostingView<FloatingTimerView>, hover: FloatingHoverState) {
        self.hosting = hosting
        self.hover = hover
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }

    // Route every click to this view rather than into SwiftUI.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        MainActor.assumeIsolated { hover.isHovering = true }
    }

    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated { hover.isHovering = false }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeButtonRect.contains(point) {
            onClose?()
            return
        }
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        window?.performDrag(with: event)
    }

    /// Generous hit target around the × in the top-left corner.
    private var closeButtonRect: NSRect {
        NSRect(x: 0, y: 0, width: 26, height: 26)
    }
}

struct FloatingTimerView: View {
    @ObservedObject var model: TimerModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var log: TimeLog
    @ObservedObject var hover: FloatingHoverState

    @State private var pulse = false

    var body: some View {
        let scale = prefs.floatingSize.scale
        let fontSize = 40 * scale

        let task = prefs.floatingShowsTask ? TimeLog.clean(log.currentTask) : ""

        Text(model.clockText)
            .font(.system(size: fontSize, weight: .regular))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(textOpacity))
            .fixedSize()
            .padding(.bottom, task.isEmpty ? 0 : 13 * scale)
            // The caption sits in an overlay so a long task never widens the window.
            .overlay(alignment: .bottom) {
                if !task.isEmpty {
                    Text(task)
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 18 * scale)
            .padding(.top, 6 * scale)
            .padding(.bottom, (task.isEmpty ? 6 : 9) * scale)
            .background(
                RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                    .fill(.black.opacity(prefs.floatingOpacity))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .overlay(alignment: .topLeading) {
                Image(systemName: "xmark")
                    .font(.system(size: 9 * max(scale, 1), weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(8 * max(scale, 1))
                    .opacity(hover.isHovering ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: hover.isHovering)
            }
            .onChange(of: model.phase, initial: true) { _, phase in
                if phase == .finished {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
                } else {
                    withAnimation(.default) { pulse = false }
                }
            }
    }

    private var textOpacity: Double {
        switch model.phase {
        case .paused: 0.45
        case .finished: pulse ? 0.25 : 1
        default: 1
        }
    }
}
