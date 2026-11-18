import Foundation

/// Maths for the Mac grid's drag-to-select band, kept free of AppKit so it is testable.
public enum MarqueeSelection {
    /// The rectangle between two points, clamped to the content bounds (the band stops at the grid's edges).
    public static func rect(from a: CGPoint, to b: CGPoint, within bounds: CGRect) -> CGRect {
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
        }
        let p = clamp(a), q = clamp(b)
        return CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y))
    }

    /// The selection while the band covers `touched`. Without a modifier the band replaces the selection;
    /// with Shift or Command it toggles the touched tiles against what was selected when the drag began (like Finder).
    public static func result(base: Set<String>, touched: Set<String>, toggle: Bool) -> Set<String> {
        toggle ? base.symmetricDifference(touched) : touched
    }

    /// Points to scroll per tick while the pointer is within `zone` of the top (negative) or bottom (positive) edge
    /// of the visible area; faster the closer to the edge. 0 when the pointer is clear of both edges.
    public static func autoScrollStep(pointerY: CGFloat, visibleMinY: CGFloat, visibleMaxY: CGFloat,
                                      zone: CGFloat = 60, maxStep: CGFloat = 30) -> CGFloat {
        guard zone > 0 else { return 0 }
        if pointerY < visibleMinY + zone {
            let depth = min(1, (visibleMinY + zone - pointerY) / zone)
            return -max(2, maxStep * depth * depth)
        }
        if pointerY > visibleMaxY - zone {
            let depth = min(1, (pointerY - (visibleMaxY - zone)) / zone)
            return max(2, maxStep * depth * depth)
        }
        return 0
    }
}
