import SwiftUI

/// The island silhouette: a flat top across the full width with small *concave*
/// fillets at the top corners (so it flares outward into the screen edge, like
/// the real notch), and large convex rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat      // concave fillet at the top corners
    var bottomRadius: CGFloat   // convex bottom corners

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tr = max(0, min(topRadius, rect.width / 2, rect.height / 2))
        let br = max(0, min(bottomRadius, rect.width / 2 - tr, rect.height - tr))

        // Flat top edge spans the full width (minX … maxX at y = minY).
        // Top-left concave fillet: from the screen edge down to the body.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
                       control: CGPoint(x: rect.minX + tr, y: rect.minY))
        // Left side down.
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        // Bottom-left convex corner.
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
                       control: CGPoint(x: rect.minX + tr, y: rect.maxY))
        // Bottom edge.
        p.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        // Bottom-right convex corner.
        p.addQuadCurve(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
                       control: CGPoint(x: rect.maxX - tr, y: rect.maxY))
        // Right side up.
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        // Top-right concave fillet out to the screen edge.
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
