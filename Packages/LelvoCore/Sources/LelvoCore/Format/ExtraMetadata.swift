import Foundation

/// The `md` resource (docs/CLOUD_FORMAT.md §2): metadata that doesn't fit the caption, as compact JSON. Readers merge
/// it into the original's caption metadata; its fields win.
public struct ExtraMetadata: Codable, Equatable, Sendable {
    /// Album names, all of them (the caption had to leave them out).
    public var a: [String]?

    public init(a: [String]? = nil) { self.a = a }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> ExtraMetadata { try JSONDecoder().decode(ExtraMetadata.self, from: data) }
}
