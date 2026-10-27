import Foundation

/// Applies a change set to an array in PhotoKit's convention (`PHFetchResultChangeDetails`): removed indexes refer
/// to the array before the change, inserted and changed indexes to the array after it. Lets the timeline patch its
/// copy of the photo list instead of reading every asset again after each change.
public enum ArrayChanges {
    /// Nil when an index is out of range (the change set doesn't belong to this array); the caller then reloads.
    public static func apply<T>(to array: [T], removed: IndexSet, inserted: [(index: Int, element: T)],
                                changed: [(index: Int, element: T)]) -> [T]? {
        var out = array
        for index in removed.reversed() {
            guard index < out.count else { return nil }
            out.remove(at: index)
        }
        for (index, element) in inserted.sorted(by: { $0.index < $1.index }) {
            guard index <= out.count else { return nil }
            out.insert(element, at: index)
        }
        for (index, element) in changed {
            guard index < out.count else { return nil }
            out[index] = element
        }
        return out
    }
}
