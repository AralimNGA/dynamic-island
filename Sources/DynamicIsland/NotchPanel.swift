import AppKit
import SwiftUI
import CoreServices

/// A non-activating floating panel that hosts the island above the menu bar.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // needed so SwiftUI controls receive clicks
    override var canBecomeMain: Bool { false }
}

/// Hosting view that accepts the first click even when its window isn't key —
/// without this, the first click on a control in a non-activating panel is
/// swallowed to focus the window instead of triggering the control.
final class ClickableHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Proactively triggers the macOS Automation (Apple Events) permission prompt for
/// a target app. Running AppleScript from a background thread often fails silently
/// without ever prompting; this makes the prompt appear.
enum AutomationPermissions {
    private static let wildcard = AEEventClass(0x2A2A2A2A) // '****'

    static func ensure(bundleIdentifier: String) {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        if let desc = target.aeDesc {
            _ = AEDeterminePermissionToAutomateTarget(desc, wildcard, AEEventID(0x2A2A2A2A), true)
        }
    }
}

/// The panel's content view: hosts SwiftUI, drives hover via an always-active
/// tracking area, and makes the transparent area outside the island click-through.
final class IslandContainerView: NSView {
    let state: IslandState

    /// Returns the current island rect in this view's coordinate space.
    var islandRectProvider: (() -> CGRect)?

    private var collapseWork: DispatchWorkItem?

    init(state: IslandState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { evaluate(event) }
    override func mouseMoved(with event: NSEvent)   { evaluate(event) }
    override func mouseExited(with event: NSEvent)  { setHover(false) }

    private func evaluate(_ event: NSEvent) {
        guard let rect = islandRectProvider?() else { return }
        let p = convert(event.locationInWindow, from: nil)
        setHover(rect.insetBy(dx: -6, dy: -6).contains(p))
    }

    private func setHover(_ hover: Bool) {
        if hover {
            collapseWork?.cancel()
            collapseWork = nil
            if !state.hovering { state.hovering = true }
        } else {
            guard state.hovering || state.pinnedOpen else { return }
            collapseWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.state.hovering = false
                if !self.state.dragActive { self.state.pinnedOpen = false }
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }

    // MARK: Click-through

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let rect = islandRectProvider?() else { return nil }
        let local = convert(point, from: superview)
        return rect.contains(local) ? super.hitTest(point) : nil
    }
}

/// Owns the panel, its hosting view, and the geometry wiring.
final class IslandController {
    let panel: NotchPanel
    private let container: IslandContainerView
    private let hosting: NSView
    private let metrics: NotchMetrics
    private let state: IslandState
    private let media: MediaController
    private let timer: TimerModel

    init(state: IslandState, media: MediaController, battery: BatteryMonitor,
         timer: TimerModel, shelf: ShelfModel, calendar: CalendarService,
         claude: ClaudeService, camera: CameraController, recorder: AudioRecorder,
         todo: TodoModel, weather: WeatherService, stocks: StockService,
         deviceBattery: DeviceBatteryService, metrics: NotchMetrics) {
        self.state = state
        self.media = media
        self.timer = timer
        self.metrics = metrics

        let panelSize = IslandLayout.panelSize
        panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false

        container = IslandContainerView(state: state)
        container.autoresizingMask = [.width, .height]

        let root = IslandRootView(state: state, media: media, battery: battery,
                                  timer: timer, shelf: shelf, calendar: calendar,
                                  claude: claude, camera: camera, recorder: recorder,
                                  todo: todo, weather: weather, stocks: stocks,
                                  deviceBattery: deviceBattery, metrics: metrics)
        let hostingView = ClickableHostingView(rootView: root)
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
        hosting = hostingView

        container.addSubview(hostingView)
        panel.contentView = container

        container.islandRectProvider = { [weak self] in self?.currentIslandRect() ?? .zero }

        position()
        panel.orderFrontRegardless()
    }

    /// The interactive island rect in the container's (bottom-left origin) coords.
    private func currentIslandRect() -> CGRect {
        let size = IslandLayout.currentSize(state: state, metrics: metrics, media: media, timer: timer)
        let b = container.bounds
        let x = (b.width - size.width) / 2
        let y = b.height - size.height   // top-aligned
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    func position() {
        let size = IslandLayout.panelSize
        let origin = NSPoint(
            x: metrics.notchCenterX - size.width / 2,
            y: metrics.screenTopY - size.height
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// The hosting container — used by the snapshot test mode.
    var contentView: NSView { container }
}
