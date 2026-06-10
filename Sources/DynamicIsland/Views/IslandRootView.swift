import SwiftUI

/// The morphing container: draws the black island and swaps its content between
/// collapsed → compact peek → expanded, all driven by `IslandState`.
struct IslandRootView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var media: MediaController
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var timer: TimerModel
    @ObservedObject var shelf: ShelfModel
    @ObservedObject var calendar: CalendarService
    @ObservedObject var claude: ClaudeService
    @ObservedObject var camera: CameraController
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var todo: TodoModel
    @ObservedObject var weather: WeatherService
    @ObservedObject var stocks: StockService
    @ObservedObject var deviceBattery: DeviceBatteryService
    @ObservedObject private var settings = AppSettings.shared
    let metrics: NotchMetrics

    // MARK: Sizes

    private var resolvedPeek: IslandActivity {
        IslandLayout.resolvedPeek(state: state, media: media, timer: timer)
    }

    private var currentSize: CGSize {
        IslandLayout.currentSize(state: state, metrics: metrics, media: media, timer: timer)
    }

    private var topRadius: CGFloat { CGFloat(settings.notchFlare) }
    private var bottomRadius: CGFloat {
        if state.isExpanded { return 26 }
        return min(13, metrics.notchHeight * 0.42)   // peek & collapsed share the notch radius
    }

    private var shape: NotchShape { NotchShape(topRadius: topRadius, bottomRadius: bottomRadius) }

    // MARK: Body

    var body: some View {
        let size = currentSize
        ZStack(alignment: .top) {
            shape.fill(Color.black)

            if state.isExpanded || resolvedPeek == .mediaPeek {
                shape
                    .stroke(media.accent.opacity(state.isExpanded ? 0.30 : 0.20), lineWidth: 1)
                    .blur(radius: 1.5)
                    .allowsHitTesting(false)
            }

            islandContent(size: size)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)            // clip everything to the morphing island
        .shadow(color: .black.opacity(state.isExpanded ? 0.55 : 0.0), radius: 14, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.island, value: state.isExpanded)
        .animation(.island, value: resolvedPeek)
        .onDrop(of: [.fileURL], isTargeted: globalDropTarget) { providers in
            ShelfModel.loadURLs(from: providers) { urls in
                if !urls.isEmpty { shelf.add(urls: urls) }
            }
        }
        .tint(settings.accentColor)
    }

    @ViewBuilder
    private func islandContent(size: CGSize) -> some View {
        if state.isExpanded {
            // Fixed expanded size, top-anchored: as the island shrinks the content
            // is clipped away from the bottom (absorbed) instead of floating + fading.
            ExpandedView(state: state, media: media, battery: battery,
                         timer: timer, shelf: shelf, calendar: calendar,
                         claude: claude, camera: camera, recorder: recorder,
                         todo: todo, weather: weather, stocks: stocks,
                         deviceBattery: deviceBattery, topInset: metrics.notchHeight)
                .frame(width: IslandLayout.expanded.width, height: IslandLayout.expanded.height, alignment: .top)
                .transition(.opacity.animation(.easeOut(duration: 0.14)))
        } else if resolvedPeek != .idle {
            CompactPeek(kind: resolvedPeek, media: media, battery: battery, timer: timer,
                        notchWidth: metrics.notchWidth, lobeHeight: metrics.notchHeight,
                        sidePadding: CGFloat(settings.notchFlare) + 14)
                .frame(width: size.width, height: size.height)
                .transition(.opacity.animation(.easeOut(duration: 0.14)))
        } else {
            Color.clear
        }
    }

    /// Dragging a file over the notch expands straight into the Ablage tab.
    private var globalDropTarget: Binding<Bool> {
        Binding(
            get: { state.dragActive },
            set: { newValue in
                state.dragActive = newValue
                if newValue {
                    withAnimation(.island) {
                        state.pinnedOpen = true
                        state.selectedTab = .shelf
                    }
                }
            }
        )
    }
}
