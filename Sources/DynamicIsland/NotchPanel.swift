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

    init(state: IslandState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Click-through

    /// Only intercept clicks while the island is actually expanded (only then are
    /// there controls to click). Collapsed and peek are fully click-through, so the
    /// panel never blocks the menu bar, windows, or buttons underneath — no ghost.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard state.isExpanded, let rect = islandRectProvider?() else { return nil }
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
    private var hoverMonitors: [Any] = []
    private var collapseWork: DispatchWorkItem?

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
        startHoverTracking()
    }

    // MARK: Hover (global mouse tracking)

    /// Drive expand/collapse from a global mouse monitor instead of an NSTrackingArea.
    /// The monitor reports the cursor position reliably everywhere (other apps, other
    /// Spaces, fast moves), so the island can never get "stuck" expanded.
    private func startHoverTracking() {
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.evaluateHover() }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: handler) {
            hoverMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { event in
            handler(event); return event
        }) {
            hoverMonitors.append(l)
        }
        hlog("monitors registered: \(hoverMonitors.count), islandRect(collapsed)=\(islandScreenRect())")
    }

    private static let debug = ProcessInfo.processInfo.environment["ISLAND_DEBUG"] == "1"
    private func hlog(_ s: String) {
        if Self.debug { FileHandle.standardError.write(("‹hover› " + s + "\n").data(using: .utf8)!) }
    }

    private func evaluateHover() {
        let loc = NSEvent.mouseLocation                       // global, bottom-left
        let inside = islandScreenRect().insetBy(dx: -10, dy: -10).contains(loc)
        if inside {
            collapseWork?.cancel(); collapseWork = nil
            if !state.hovering { state.hovering = true; hlog("expand (cursor \(Int(loc.x)),\(Int(loc.y)))") }
        } else {
            // Outside: collapse after a short grace (hysteresis), unless already pending.
            guard state.hovering || state.pinnedOpen, collapseWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.state.hovering = false
                if !self.state.dragActive { self.state.pinnedOpen = false }
                self.collapseWork = nil
                self.hlog("collapse")
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    /// The island rect in global screen coordinates (matches the on-screen island).
    private func islandScreenRect() -> CGRect {
        let size = IslandLayout.currentSize(state: state, metrics: metrics, media: media, timer: timer)
        return CGRect(x: metrics.notchCenterX - size.width / 2,
                      y: metrics.screenTopY - size.height,
                      width: size.width, height: size.height)
    }

    deinit { hoverMonitors.forEach { NSEvent.removeMonitor($0) } }

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
