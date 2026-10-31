import Foundation

/// Every item, newest first (ties by id), kept in order as single items change. The timeline needs this order on
/// every refresh; sorting 50,000 items each time took about half a second, while moving a few changed items into
/// place takes a few milliseconds.
public struct OrderedItems: Sendable {
    public private(set) var items: [MediaItem]
    private var byId: [String: MediaItem]
    /// Items per photo, in order. Usually one; restores and re-imports can link two items to the same photo.
    private var byLocal: [String: [MediaItem]] = [:]

    public init(_ items: [MediaItem]) {
        var byId: [String: MediaItem] = [:]
        byId.reserveCapacity(items.count)
        for item in items where byId[item.id] == nil { byId[item.id] = item }
        self.byId = byId
        self.items = byId.values.sorted(by: Self.precedes)
        for item in self.items { if let local = item.localIdentifier { byLocal[local, default: []].append(item) } }
    }

    public func item(id: String) -> MediaItem? { byId[id] }

    /// The item shown for a photo: the first in order when more than one points at it.
    public func item(localIdentifier: String) -> MediaItem? {
        byLocal[localIdentifier]?.first
    }

    /// Newest first; items without a date last; equal dates by id, so the order never depends on how items arrived.
    public static func precedes(_ a: MediaItem, _ b: MediaItem) -> Bool {
        let da = a.creationDate ?? .distantPast, db = b.creationDate ?? .distantPast
        return da != db ? da > db : a.id < b.id
    }

    /// Replaces the items with these ids by `fresh`; ids missing from `fresh` were deleted.
    public mutating func update(ids: Set<String>, fresh: [MediaItem]) {
        let freshById = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in ids {
            if let old = byId.removeValue(forKey: id) {
                let at = Self.position(of: old, in: items)
                if at < items.count, items[at].id == id { items.remove(at: at) }
                if let local = old.localIdentifier {
                    byLocal[local]?.removeAll { $0.id == id }
                    if byLocal[local]?.isEmpty == true { byLocal[local] = nil }
                }
            }
            if let new = freshById[id] {
                byId[id] = new
                items.insert(new, at: Self.position(of: new, in: items))
                if let local = new.localIdentifier {
                    var list = byLocal[local] ?? []
                    list.insert(new, at: Self.position(of: new, in: list))
                    byLocal[local] = list
                }
            }
        }
    }

    /// Where `item` is or belongs in `list` (binary search; `list` is in order).
    private static func position(of item: MediaItem, in list: [MediaItem]) -> Int {
        var low = 0, high = list.count
        while low < high {
            let mid = (low + high) / 2
            if precedes(list[mid], item) { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
