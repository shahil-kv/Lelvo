import Foundation
import Testing
@testable import LelvoCore

@Suite struct UploadOrderShortRunTests {
    private func item(_ kind: MediaKind, _ mb: Int64, _ name: String) -> MediaItem {
        MediaItem(localIdentifier: name, sha256: name, filename: name, kind: kind, creationDate: Date(), fileSize: mb * 1_048_576, status: .queued)
    }

    @Test func keepsPhotosOnly() {
        let items = [item(.video, 200, "big"), item(.photo, 5, "p"), item(.video, 10, "small"), item(.photo, 3, "q")]
        #expect(Set(UploadOrder.forShortRun(items).map(\.filename)) == ["p", "q"])
    }
}
