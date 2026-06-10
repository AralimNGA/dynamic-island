import AppKit

/// Geometry of the physical notch (or a synthesized pill on non-notch displays).
struct NotchMetrics {
    let screen: NSScreen
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let notchCenterX: CGFloat   // global (bottom-left origin) screen coordinates
    let screenTopY: CGFloat     // global coordinates: frame.maxY
    let screenFrame: CGRect
    let hasNotch: Bool

    static func current() -> NotchMetrics {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first!

        let frame = screen.frame
        let inset = screen.safeAreaInsets.top
        let leftW = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightW = screen.auxiliaryTopRightArea?.width ?? 0

        var nWidth = frame.width - leftW - rightW
        let plausible = inset > 0 && nWidth > 60 && nWidth < frame.width * 0.6
        let hasNotch = plausible
        if !plausible {
            nWidth = 220   // fallback pill for external / non-notch displays
        }
        let nHeight = inset > 0 ? inset : 32

        return NotchMetrics(
            screen: screen,
            notchWidth: nWidth.rounded(),
            notchHeight: nHeight.rounded(),
            notchCenterX: frame.midX,
            screenTopY: frame.maxY,
            screenFrame: frame,
            hasNotch: hasNotch
        )
    }
}
