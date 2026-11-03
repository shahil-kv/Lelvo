import Foundation

/// Finds which ids still exist when a batch request only says "all of them" or "not all of them". Halving the batch means
/// one missing id costs a few requests instead of one per id.
public enum BatchProbe {
    public static func present<ID>(in ids: [ID],
                                   allThere: ([ID]) async throws -> Bool,
                                   isThere: (ID) async throws -> Bool) async throws -> [ID] {
        guard let first = ids.first else { return [] }
        if ids.count == 1 { return try await isThere(first) ? ids : [] }
        if try await allThere(ids) { return ids }
        let middle = ids.count / 2
        let left = try await present(in: Array(ids[..<middle]), allThere: allThere, isThere: isThere)
        let right = try await present(in: Array(ids[middle...]), allThere: allThere, isThere: isThere)
        return left + right
    }
}
