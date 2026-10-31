import Foundation
import CryptoKit
import Testing
@testable import LelvoCore

@Suite struct IndexSnapshotTests {
    func message(_ id: Int64, item: String, role: CaptionMeta.Role, part: [Int64]? = nil, name: String = "IMG_1.HEIC") -> CloudMessage {
        var meta = CaptionMeta(id: item, role: role, kind: .photo, sha256: String(repeating: "c", count: 64), name: name, size: 300)
        meta.p = part
        meta.t = 1_700_000_000
        return CloudMessage(messageId: id, meta: meta, fileId: "f\(id)", uniqueId: "u\(id)", size: part.map { _ in 150 } ?? 300)
    }

    var library: [CloudMessage] {
        [message(1, item: "0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10", role: .original),
         message(2, item: "0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10", role: .screenCopy, name: "IMG_1-screen.jpg"),
         message(3, item: "1b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10", role: .original, part: [0, 2, 150]),
         message(4, item: "1b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10", role: .original, part: [1, 2, 150])]
    }

    /// Rebuilding the index from a snapshot gives the same items as scanning the messages it was made from.
    @Test func snapshotRebuildsTheSameIndexAsAScan() throws {
        let scanned = LibraryIndexer.build(library).items
        let body = IndexSnapshot.body(items: scanned, upto: 4)
        let decoded = try IndexSnapshot.decode(try IndexSnapshot.encode(body))
        #expect(decoded == body)
        let rebuilt = LibraryIndexer.build(decoded.messages.map(\.message)).items
        func key(_ items: [MediaItem]) -> [String] {
            items.map { "\($0.id) \($0.status) \(($0.cloudParts ?? [:]).mapValues { $0.map(\.messageId) }.sorted { $0.key < $1.key })" }.sorted()
        }
        #expect(key(rebuilt) == key(scanned))
        #expect(rebuilt.first { $0.id.hasPrefix("1b7") }?.expectedParts?["o"] == 2)
    }

    @Test func onlyMessagesUpToTheSnapshot() {
        let items = LibraryIndexer.build(library).items
        #expect(IndexSnapshot.body(items: items, upto: 2).messages.map(\.m) == [1, 2])
    }

    @Test func captionsPlainAndEncrypted() throws {
        let caption = IndexSnapshot.Caption(upto: 42, n: 3, h: String(repeating: "a", count: 64))
        let plain = try IndexSnapshot.caption(caption, captionKey: nil)
        #expect(plain.hasPrefix("CGX1:"))
        #expect(IndexSnapshot.parseCaption(plain, captionKey: nil) == caption)
        let key = SymmetricKey(size: .bits256)
        let sealed = try IndexSnapshot.caption(caption, captionKey: key)
        #expect(sealed.hasPrefix("CGX1E:"))
        #expect(IndexSnapshot.parseCaption(sealed, captionKey: key) == caption)
        #expect(IndexSnapshot.parseCaption(sealed, captionKey: SymmetricKey(size: .bits256)) == nil)
        // A snapshot caption is never taken for an item caption, by this or older readers.
        #expect(!CaptionCodec.isLelvo(plain) && !CaptionCodec.isLelvo(sealed))
    }

    @Test func damagedSnapshotsAreRefused() {
        #expect(throws: (any Error).self) { try IndexSnapshot.decode(Data("not a snapshot".utf8)) }
        #expect(IndexSnapshot.parseCaption("CGX1:{nope", captionKey: nil) == nil)
    }
}
