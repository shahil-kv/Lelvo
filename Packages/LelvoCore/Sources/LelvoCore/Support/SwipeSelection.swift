import Foundation

/// Swipe-to-select as in Photos. The first tile decides whether the swipe selects or deselects, and everything between
/// that tile and the finger follows, in timeline order. Tiles the finger leaves go back to what they were before the swipe.
public struct SwipeSelection {
    public let selecting: Bool
    public private(set) var selection: Set<String>
    private let order: [String]
    private let initial: Set<String>
    private let anchor: Int
    private var position: Int

    public init(order: [String], anchor: Int, selection: Set<String>) {
        self.order = order
        self.anchor = anchor
        position = anchor
        initial = selection
        self.selection = selection
        selecting = !selection.contains(order[anchor])
        set(order[anchor], selected: selecting)
    }

    /// Moves the finger to a place in `order`. Returns the ids whose state changed, so only those tiles are redrawn.
    @discardableResult
    public mutating func move(to target: Int) -> [String] {
        let target = min(order.count - 1, max(0, target))
        guard target != position else { return [] }
        let old = min(anchor, position)...max(anchor, position)
        let new = min(anchor, target)...max(anchor, target)
        position = target
        var changed: [String] = []
        for i in old where !new.contains(i) && set(order[i], selected: initial.contains(order[i])) { changed.append(order[i]) }
        for i in new where !old.contains(i) && set(order[i], selected: selecting) { changed.append(order[i]) }
        return changed
    }

    @discardableResult
    private mutating func set(_ id: String, selected: Bool) -> Bool {
        selected ? selection.insert(id).inserted : selection.remove(id) != nil
    }

    /// Points per second to scroll for a finger at `fingerY` in a visible area from `top` to `bottom`: negative is up.
    /// Zero until the finger is inside `zone` of an edge, then faster the nearer it gets.
    public static func autoScrollSpeed(fingerY: Double, top: Double, bottom: Double, zone: Double = 70, maxSpeed: Double = 1800) -> Double {
        let down = (fingerY - (bottom - zone)) / zone
        let up = ((top + zone) - fingerY) / zone
        let depth = min(1, max(0, max(down, up)))
        return (down > up ? 1 : -1) * maxSpeed * depth * depth
    }
}
