import SwiftUI

/// The morphing container: draws the black island and swaps its content between
/// hidden → lip → compact → banner → expanded, all driven by `IslandState`.
struct IslandRootView: View {
    let services: IslandServices
    @ObservedObject var state: IslandState
    @ObservedObject var media: MediaController
    @ObservedObject var timer: TimerModel
    @ObservedObject private var settings = AppSettings.shared

    /// Rang der zuletzt gezeigten Grösse – wächst die Island, federt sie,
    /// schrumpft sie, schliesst sie gedämpft.
    @State private var shownRank = 0
    /// Für Test-Renderings (ImageRenderer kann kein onDrop).
    var forSnapshot = false

    init(services: IslandServices, forSnapshot: Bool = false) {
        self.services = services
        self.forSnapshot = forSnapshot
        state = services.state
        media = services.media
        timer = services.timer
    }

    private var presentation: IslandPresentation {
        IslandLayout.presentation(state: state, media: media, timer: timer)
    }

    private var peek: IslandActivity {
        IslandLayout.resolvedPeek(state: state, media: media, timer: timer)
    }

    private func rank(_ p: IslandPresentation) -> Int {
        switch p {
        case .hidden: return 0
        case .lip: return 1
        case .compact: return 2
        case .banner: return 3
        case .expanded: return 4
        }
    }

    private func shape(for p: IslandPresentation) -> NotchShape {
        let bottom: CGFloat
        switch p {
        case .expanded: bottom = 26
        case .banner:   bottom = 22
        default:        bottom = min(13, state.metrics.notchHeight * 0.42)
        }
        return NotchShape(topRadius: CGFloat(settings.notchFlare), bottomRadius: bottom)
    }

    // MARK: Body

    var body: some View {
        let p = presentation
        let size = IslandLayout.size(for: p, state: state, media: media, timer: timer)
        let shape = shape(for: p)
        let growing = rank(p) >= shownRank

        ZStack(alignment: .top) {
            // Reines Schwarz wie auf dem iPhone – kein farbiger Leuchtrand (der
            // liess die Island bei Musik grau wirken, v. a. ohne Cover).
            shape.fill(Color.black)

            content(p, size: size)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .shadow(color: .black.opacity(p == .expanded ? 0.5 : (p == .banner ? 0.35 : 0)),
                radius: p == .expanded ? 16 : 10, y: 6)
        // Ruhezustand: gar nichts zeichnen. Die echte Notch ist ohnehin schwarz,
        // so taucht die Island auch in keinem Screenshot als Fleck auf.
        .opacity(p == .hidden ? 0 : 1)
        .animation(p == .hidden ? .linear(duration: 0.06).delay(0.32) : nil, value: p == .hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(growing ? .islandOpen : .islandClose, value: p)
        .animation(.islandSnappy, value: peek.kind)
        .onChange(of: p) { _, new in shownRank = rank(new) }
        .modifier(FileDrop(enabled: !forSnapshot, target: globalDropTarget, shelf: services.shelf))
        .tint(settings.accentColor)
    }

    @ViewBuilder
    private func content(_ p: IslandPresentation, size: CGSize) -> some View {
        switch p {
        case .expanded:
            // Fixed expanded size, top-anchored: as the island shrinks the content
            // is clipped away from the bottom (absorbed) instead of floating.
            ExpandedView(services: services, topInset: state.metrics.notchHeight)
                .frame(width: IslandLayout.expanded.width, height: IslandLayout.expanded.height, alignment: .top)
                .transition(.islandContent)
        case .banner:
            if let banner = state.banner {
                BannerView(banner: banner, media: media, topInset: state.metrics.notchHeight)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .transition(.islandContent)
            }
        case .compact:
            CompactPeek(kind: peek, media: media, battery: services.battery, timer: timer,
                        notchWidth: state.metrics.notchWidth, lobeHeight: state.metrics.notchHeight,
                        sidePadding: CGFloat(settings.notchFlare) + 12)
                .frame(width: size.width, height: size.height)
                .id(peek.kind)
                .transition(.islandContent)
        case .lip, .hidden:
            Color.clear
        }
    }

    /// Dragging a file over the notch expands straight into the Ablage tab.
    private var globalDropTarget: Binding<Bool> {
        Binding(
            get: { state.dragActive },
            set: { newValue in
                state.dragActive = newValue
                if newValue { state.open(.shelf) }
            }
        )
    }
}

private struct FileDrop: ViewModifier {
    let enabled: Bool
    let target: Binding<Bool>
    let shelf: ShelfModel

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [.fileURL], isTargeted: target) { providers in
                ShelfModel.loadURLs(from: providers) { urls in
                    if !urls.isEmpty { shelf.add(urls: urls) }
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Content transition

/// Inhalt blendet mit Unschärfe und leichtem Zoom ein – wie auf dem iPhone,
/// wo der Inhalt erst erscheint, wenn die Form schon fast offen ist.
private struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 8 : 0)
            .scaleEffect(active ? 0.94 : 1, anchor: .top)
            .opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
                .animation(.easeOut(duration: 0.26).delay(0.06)),
            removal: .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
                .animation(.easeIn(duration: 0.12))
        )
    }
}
