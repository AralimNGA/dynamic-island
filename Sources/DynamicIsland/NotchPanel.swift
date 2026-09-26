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

/// The panel's content view: hosts SwiftUI and makes the transparent area
/// outside the island click-through.
final class IslandContainerView: NSView {
    let state: IslandState

    /// Returns the current island rect in this view's coordinate space.
    var islandRectProvider: (() -> CGRect)?
    /// Klick auf die geschlossene Island (Notch, Aktivität, Banner).
    var onCollapsedClick: (() -> Void)?

    init(state: IslandState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Offen: SwiftUI bekommt die Klicks. Geschlossen: der Container fängt den
    /// Klick selbst ab und öffnet die Island. Ausserhalb: nichts (click-through).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let rect = islandRectProvider?() else { return nil }
        let local = convert(point, from: superview)
        guard rect.contains(local) else { return nil }
        return state.isExpanded ? super.hitTest(point) : self
    }

    override func mouseDown(with event: NSEvent) {
        if !state.isExpanded { onCollapsedClick?() } else { super.mouseDown(with: event) }
    }
}

/// Owns the panel, its hosting view, and the geometry wiring.
final class IslandController {
    let panel: NotchPanel
    private let container: IslandContainerView
    private let services: IslandServices
    private var state: IslandState { services.state }
    private var settings: AppSettings { .shared }
    private var monitors: [Any] = []
    private var collapseWork: DispatchWorkItem?
    private var intentWork: DispatchWorkItem?

    // Wischgesten
    private var scroll = CGVector.zero
    private var scrollConsumed = false

    init(services: IslandServices) {
        self.services = services

        panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: IslandLayout.panelSize),
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
        panel.ignoresMouseEvents = true   // click-through by default; toggled when the cursor is over the island
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        container = IslandContainerView(state: services.state)
        container.autoresizingMask = [.width, .height]

        let hostingView = ClickableHostingView(rootView: IslandRootView(services: services))
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.sizingOptions = []

        container.addSubview(hostingView)
        panel.contentView = container

        container.islandRectProvider = { [weak self] in self?.currentIslandRect() ?? .zero }
        container.onCollapsedClick = { [weak self] in self?.openFromClick() }

        applyCaptureSetting()
        position()
        panel.orderFrontRegardless()
        // Eigener Space: gleitet beim Schreibtisch-Wechsel nicht mit.
        PrivateSpace.shared.add(panel)
        startHoverTracking()
        startScrollGestures()
    }

    deinit { monitors.forEach { NSEvent.removeMonitor($0) } }

    // MARK: Geometrie

    /// Bildschirm neu vermessen (Monitor an/ab, Auflösung geändert, Deckel zu).
    func refreshMetrics() {
        state.metrics = NotchMetrics.current()
        position()
        PrivateSpace.shared.add(panel)
    }

    func position() {
        let m = state.metrics
        let size = IslandLayout.panelSize
        let origin = NSPoint(x: m.notchCenterX - size.width / 2, y: m.screenTopY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Nicht in Screenshots, Bildschirmaufnahmen und Bildschirmfreigaben zeigen.
    /// Unter macOS 26 respektieren screencapture und ScreenCaptureKit das
    /// (geprüft mit ⇧⌘3-Pfad und SCScreenshotManager).
    func applyCaptureSetting() {
        let forceVisible = ProcessInfo.processInfo.environment["ISLAND_CAPTURABLE"] == "1"
        panel.sharingType = settings.hideInScreenshots && !forceVisible ? .none : .readOnly
    }

    /// The island rect in global screen coordinates (matches the on-screen island).
    private func islandScreenRect() -> CGRect {
        let m = state.metrics
        let size = IslandLayout.currentSize(state: state, media: services.media, timer: services.timer)
        return CGRect(x: m.notchCenterX - size.width / 2, y: m.screenTopY - size.height,
                      width: size.width, height: size.height)
    }

    /// The interactive island rect in the container's (bottom-left origin) coords.
    private func currentIslandRect() -> CGRect {
        let size = IslandLayout.currentSize(state: state, media: services.media, timer: services.timer)
        let b = container.bounds
        return CGRect(x: (b.width - size.width) / 2, y: b.height - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: Hover

    /// Drive expand/collapse from a global mouse monitor instead of an NSTrackingArea.
    /// The monitor reports the cursor position reliably everywhere (other apps, other
    /// Spaces, fast moves), so the island can never get "stuck" expanded.
    private func startHoverTracking() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in self?.evaluateHover() }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] e in
            self?.evaluateHover(); return e
        }) {
            monitors.append(l)
        }
    }

    private func evaluateHover() {
        let loc = NSEvent.mouseLocation
        let rect = islandScreenRect()
        // Oben bis an den Bildschirmrand (Maus „stösst“ an), seitlich etwas Toleranz.
        let pad: CGFloat = state.isExpanded ? 10 : 6
        let hot = CGRect(x: rect.minX - pad, y: rect.minY - pad,
                         width: rect.width + 2 * pad, height: rect.height + pad + 2)
        let inside = hot.contains(loc)

        // The real click-through control: ignore mouse events unless the cursor is
        // actually over the island.
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }

        if inside {
            collapseWork?.cancel(); collapseWork = nil
            guard !state.isExpanded, !state.hoverIntent else { return }
            withAnimation(.islandOpen) { state.hoverIntent = true }
            guard settings.openOnHover else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state.hoverIntent else { return }
                self.expand()
            }
            intentWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.hoverDelay, execute: work)
        } else {
            intentWork?.cancel(); intentWork = nil
            if state.hoverIntent && !state.isExpanded {
                withAnimation(.islandClose) { state.hoverIntent = false }
            }
            guard state.isExpanded, collapseWork == nil, Date() > state.graceUntil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.collapseWork = nil
                if self.state.dragActive || self.state.holdOpen() { return }
                self.state.close()
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }
    }

    private func expand() {
        Haptics.tap()
        withAnimation(.islandOpen) {
            state.hovering = true
            state.hoverIntent = false
            state.banner = nil
        }
    }

    /// Klick auf die geschlossene Island: öffnet den Tab, der zur gerade
    /// sichtbaren Aktivität passt (wie Long-Press auf dem iPhone).
    private func openFromClick() {
        Haptics.tap()
        intentWork?.cancel()
        var tab: ExpandedTab?
        if let banner = state.banner {
            switch banner {
            case .track: tab = .nowPlaying
            case .device: tab = .devices
            case .message: tab = nil
            }
        } else {
            switch IslandLayout.resolvedPeek(state: state, media: services.media, timer: services.timer) {
            case .mediaPeek: tab = .nowPlaying
            case .timerRunning: tab = .timer
            case .charging, .lowBattery: tab = .devices
            case .fileDrop: tab = .shelf
            default: tab = nil
            }
        }
        if let t = tab, !settings.isEnabled(t) { tab = nil }
        state.hoverIntent = false
        state.open(tab)
    }

    // MARK: Wischgesten (Trackpad)

    /// - Geschlossen: zwei Finger nach unten ziehen → öffnen.
    /// - Musik-Aktivität: links/rechts wischen → nächster/vorheriger Titel.
    /// - Offen: links/rechts wischen → nächster/vorheriger Tab.
    private func startScrollGestures() {
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            guard let self, e.window === self.panel, e.hasPreciseScrollingDeltas else { return e }
            return self.handleScroll(e) ? nil : e
        }) {
            monitors.append(m)
        }
    }

    private func handleScroll(_ e: NSEvent) -> Bool {
        if !e.momentumPhase.isEmpty { return scrollConsumed }
        if e.phase == .began { scroll = .zero; scrollConsumed = false }
        if e.phase == .ended || e.phase == .cancelled {
            let consumed = scrollConsumed
            scroll = .zero; scrollConsumed = false
            return consumed
        }
        if scrollConsumed { return true }

        // Normalisiert: dx > 0 = Finger nach rechts, dy > 0 = Finger nach unten.
        let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        scroll.dx += e.scrollingDeltaX * sign
        scroll.dy += e.scrollingDeltaY * sign
        let dx = scroll.dx, dy = scroll.dy
        let horizontal = abs(dx) > 50 && abs(dx) > abs(dy) * 1.8

        if state.isExpanded {
            guard horizontal, state.selectedTab != .shelf else { return false }
            let tabs = settings.orderedEnabledTabs
            guard let i = tabs.firstIndex(of: state.selectedTab), tabs.count > 1 else { return false }
            let next = dx < 0 ? min(tabs.count - 1, i + 1) : max(0, i - 1)
            if next != i {
                Haptics.tap()
                withAnimation(.islandSnappy) { state.selectedTab = tabs[next] }
            }
            scrollConsumed = true
            return true
        }

        if dy > 26 && dy > abs(dx) * 1.5 {
            scrollConsumed = true
            intentWork?.cancel()
            expand()
            return true
        }
        let peek = IslandLayout.resolvedPeek(state: state, media: services.media, timer: services.timer)
        if horizontal, peek == .mediaPeek || state.banner == .track {
            scrollConsumed = true
            Haptics.tap()
            if dx < 0 { services.media.next() } else { services.media.previous() }
            return true
        }
        return false
    }

    /// The hosting container — used by the snapshot test mode.
    var contentView: NSView { container }
}

/// Trackpad-Haptik (nur spürbar, solange ein Finger auf dem Trackpad liegt).
enum Haptics {
    static func tap() {
        guard AppSettings.shared.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
