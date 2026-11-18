#if DEBUG
import Foundation
import Photos
import UIKit
import LelvoCore
import CryptoKit

/// QA launch arguments for real-account tests on a simulator (docs/MANUAL_TEST_PLAN.md 1.20–1.22). Debug only.
///   -QADeleteNewest <n> <delay s>   deletes n photos still queued, after the delay (iOS asks first)
///   -QAEditNewestBackedUp           crops the newest backed-up photo, as an edit in Photos
///   -QADropNewestInTelegram         deletes the newest backed-up photo's messages as if from another device
enum QAHooks {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ name: String, _ offset: Int = 1) -> Int? {
            args.firstIndex(of: name).flatMap { args.indices.contains($0 + offset) ? Int(args[$0 + offset]) : nil }
        }
        if let n = value("-QADeleteNewest") {
            let delay = value("-QADeleteNewest", 2) ?? 15
            Task.detached {
                try? await Task.sleep(for: .seconds(delay))
                // Photos still waiting in the queue, so the delete lands mid-run.
                let queued = (try? AppEnvironment.shared.store.items(status: .queued)) ?? []
                let ids = Array(queued.compactMap(\.localIdentifier).suffix(n))
                do { try await AppEnvironment.shared.photos.deleteAssets(ids); appLog("QA: deleted \(ids.count) photos") }
                catch { appLog("QA: delete failed: \(error.localizedDescription)") }
            }
        }
        if args.contains("-QAVerifyAll") {
            Task.detached {
                let env = AppEnvironment.shared
                try? await Task.sleep(for: .seconds(10))
                try? await env.td.waitUntilReady(timeout: 90)
                let items = ((try? env.store.items(status: .backedUp)) ?? []).filter { $0.sizeClass == .normal }
                var ok = 0, bad: [String] = []
                for item in items { if await env.freeUpSpace.verify(item) { ok += 1 } else { bad.append(item.filename) } }
                appLog("QA: verified \(ok) of \(items.count) in Telegram (every part, size equal); not confirmed: \(bad.prefix(10).joined(separator: ", "))")
            }
        }
        if args.contains("-QARoundTrip") {
            Task.detached { await roundTrip() }
        }
        if args.contains("-QAEditNewestBackedUp") {
            Task.detached { await editNewestBackedUp() }
        }
        if args.contains("-QADropNewestInTelegram") {
            Task.detached {
                let env = AppEnvironment.shared
                for _ in 0..<60 where env.library.chatId == nil { try? await Task.sleep(for: .seconds(1)) }
                guard let chat = env.library.chatId, let item = newestBackedUp() else { appLog("QA: nothing to drop"); return }
                do {
                    try await env.td.waitUntilReady(timeout: 90)
                    try await env.td.qaDeleteAsIfElsewhere(chatId: chat, ids: item.allMessageIds)
                    appLog("QA: removed \(item.filename) in Telegram")
                } catch { appLog("QA: drop failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Saves every cloud-only photo and video back to Photos and compares the saved original's SHA-256 and date with
    /// the backup's. Logs one line per item: "QA: round trip <name>: bytes match/DIFFER, date match/DIFFER".
    private static func roundTrip() async {
        let env = AppEnvironment.shared
        try? await Task.sleep(for: .seconds(10))
        try? await env.td.waitUntilReady(timeout: 90)
        let items = ((try? env.store.items(status: .backedUp)) ?? []).filter {
            $0.kind != .livePhoto && ($0.localIdentifier.map { env.photos.asset(localIdentifier: $0) == nil } ?? true)
        }
        appLog("QA: round trip for \(items.count) cloud-only items")
        for item in items.prefix(4) {
            do {
                guard let id = try await GalleryActions.saveToPhotos(item),
                      let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
                      let res = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo || $0.type == .video }) else {
                    appLog("QA: round trip \(item.filename): not saved"); continue
                }
                let data: Data = try await withCheckedThrowingContinuation { c in
                    let buffer = NSMutableData()
                    PHAssetResourceManager.default().requestData(for: res, options: nil) { buffer.append($0) } completionHandler: { e in
                        if let e { c.resume(throwing: e) } else { c.resume(returning: buffer as Data) }
                    }
                }
                let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let sameDate = item.creationDate.map { abs(($0.timeIntervalSince(asset.creationDate ?? .distantPast))) < 1 } ?? true
                appLog("QA: round trip \(item.filename) (\(item.kind)): bytes \(sha == item.sha256 ? "match" : "DIFFER"), date \(sameDate ? "match" : "DIFFER"), \(data.count) bytes")
            } catch { appLog("QA: round trip \(item.filename) failed: \(error.localizedDescription)") }
        }
    }

    private static func newestBackedUp() -> MediaItem? {
        let items = (try? AppEnvironment.shared.store.items(status: .backedUp)) ?? []
        return items.filter { $0.localIdentifier != nil && $0.kind == .photo }
            .max { ($0.uploadedAt ?? .distantPast) < ($1.uploadedAt ?? .distantPast) }
    }

    private static func editNewestBackedUp() async {
        try? await Task.sleep(for: .seconds(8))
        guard let id = newestBackedUp()?.localIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            appLog("QA: nothing to edit"); return
        }
        let input: PHContentEditingInput? = await withCheckedContinuation { c in
            let o = PHContentEditingInputRequestOptions(); o.isNetworkAccessAllowed = true
            asset.requestContentEditingInput(with: o) { input, _ in c.resume(returning: input) }
        }
        guard let input, let url = input.fullSizeImageURL, let image = UIImage(contentsOfFile: url.path),
              let cg = image.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: image.cgImage!.width / 2, height: image.cgImage!.height / 2)),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.9) else { appLog("QA: edit input failed"); return }
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: "app.lelvo.qa", formatVersion: "1", data: Data("crop".utf8))
        do {
            try jpeg.write(to: output.renderedContentURL)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).contentEditingOutput = output
            }
            appLog("QA: cropped the newest backed-up photo")
        } catch { appLog("QA: edit failed: \(error.localizedDescription)") }
    }
}
#endif
