import Foundation
import Testing
@testable import LelvoCore

@Suite struct UploadOrderShortRunTests {
    private func item(_ kind: MediaKind, _ mb: Int64, _ name: String) -> MediaItem {
        MediaItem(localIdentifier: name, sha256: name, filename: name, kind: kind, creationDate: Date(), fileSize: mb * 1_048_576, status: .queued)
    }

    @Test func keepsPhotosAndSmallVideosDropsBigOnes() {
        let items = [item(.video, 200, "big"), item(.photo, 5, "p"), item(.video, 10, "small"), item(.video, 0, "unknown")]
        let names = UploadOrder.forShortRun(items).map(\.filename)
        #expect(names == ["p", "small"])
    }

    @Test func photosStillComeFirst() {
        let items = [item(.video, 10, "v"), item(.photo, 5, "p")]
        #expect(UploadOrder.forShortRun(items).map(\.filename) == ["p", "v"])
    }
}
