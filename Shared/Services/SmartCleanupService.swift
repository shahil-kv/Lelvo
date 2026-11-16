import Foundation
import Photos
import LelvoCore

/// Smart cleanup (#16C): screenshots, large videos, and low-quality shots on this device, plus a cheap burst
/// estimate for the paywall teaser. Exact Telegram/phone duplicates stay in `DuplicatesView` (free). Nothing is
/// deleted here — the view selects and confirms.
final class SmartCleanupService: @unchecked Sendable {
    /// Videos at least this long, or this large, count as "large" for cleanup.
    static let largeVideoSeconds: TimeInterval = 90
    static let largeVideoBytes: Int64 = 50_000_000
    /// Vision aesthetics under this (iOS 18 / macOS 15) count as blurry / low quality.
    static let blurryScoreCeiling: Double = -0.25

    struct Item: Identifiable, Sendable {
        let id: String
        let asset: PHAsset
        let bytes: Int64
        let subtitle: String
    }

    struct Report: Sendable {
        var screenshots: [Item] = []
        var largeVideos: [Item] = []
        var blurry: [Item] = []
        /// Time-clustered burst extras (no Vision) — count and rough bytes for Free estimate before Pro similar scan.
        var burstExtras: Int = 0
        var burstBytes: Int64 = 0

        var proBytes: Int64 {
            screenshots.reduce(0) { $0 + $1.bytes }
                + largeVideos.reduce(0) { $0 + $1.bytes }
                + blurry.reduce(0) { $0 + $1.bytes }
                + burstBytes
        }

        var isEmpty: Bool {
            screenshots.isEmpty && largeVideos.isEmpty && blurry.isEmpty && burstExtras == 0
        }
    }

    private let photos: PhotoLibraryService
    private let store: LibraryStore

    init(photos: PhotoLibraryService, store: LibraryStore) {
        self.photos = photos
        self.store = store
    }

    /// Scans the phone library off the main thread. Safe to call often; Photos fetch is the cost.
    func scan() -> Report {
        guard PhotoLibraryService.hasAccess else { return Report() }
        var report = Report()
        let facts = (try? store.photoFacts()) ?? [:]
        var imageCandidates: [SimilarPhotos.Candidate] = []
        var sizes: [String: Int64] = [:]

        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            let id = asset.localIdentifier
            let bytes = Self.bytes(of: asset)
            sizes[id] = bytes

            if asset.mediaSubtypes.contains(.photoScreenshot) {
                report.screenshots.append(Item(id: id, asset: asset, bytes: bytes,
                                               subtitle: Format.bytes(bytes)))
                return
            }

            if asset.mediaType == .video {
                let long = asset.duration >= Self.largeVideoSeconds
                let heavy = bytes >= Self.largeVideoBytes
                if long || heavy {
                    report.largeVideos.append(Item(id: id, asset: asset, bytes: bytes,
                                                   subtitle: "\(Self.clock(asset.duration)) · \(Format.bytes(bytes))"))
                }
                return
            }

            if asset.mediaType == .image, let date = asset.creationDate {
                imageCandidates.append(.init(id: id, date: date,
                                             pixels: asset.pixelWidth * asset.pixelHeight,
                                             favorite: asset.isFavorite))
                if let score = facts[id]?.score, score < Self.blurryScoreCeiling, facts[id]?.utility != true {
                    report.blurry.append(Item(id: id, asset: asset, bytes: bytes,
                                              subtitle: "Low quality · \(Format.bytes(bytes))"))
                }
            }
        }

        // Biggest first so the list feels useful immediately.
        report.screenshots.sort { $0.bytes > $1.bytes }
        report.largeVideos.sort { $0.bytes > $1.bytes }
        report.blurry.sort { $0.bytes > $1.bytes }

        // Burst teaser without Vision: every photo after the first in a time run is an "extra".
        for run in SimilarPhotos.runs(imageCandidates) {
            guard run.count > 1 else { continue }
            let extras = run.dropFirst()
            report.burstExtras += extras.count
            report.burstBytes += extras.reduce(0) { $0 + (sizes[$1.id] ?? 0) }
        }

        return report
    }

    private static func bytes(of asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        var total: Int64 = 0
        for r in resources {
            total += (r.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
        }
        return total
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
