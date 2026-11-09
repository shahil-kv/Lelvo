import Foundation
import Photos
import LelvoCore

/// Keeps the favorite in Apple Photos and in the Telegram library the same for backed-up items still on this device
/// (#99): a favorite changed on another device reaches Photos here, and a heart changed in the Photos app reaches the
/// other devices as a note. `PhotosFavorite.decide` says which side changed; this does the work.
final class PhotosFavoriteSync: @unchecked Sendable {
    static let shared = PhotosFavoriteSync()

    private let lock = NSLock()
    private var running = false
    private var env: AppEnvironment { AppEnvironment.shared }

    /// What one check did, for the log and the re-scan message.
    struct Result: Equatable {
        var setInPhotos = 0
        var sent = 0
    }

    /// Only after the channel was read (on open, after another device's note, on re-scan): a note this device hasn't
    /// read yet would look like a change made in Photos, and be sent back over it.
    @discardableResult
    func run() async -> Result {
        // Full access only: with limited access, photos Lelvo can't see would look unfavorited.
        guard !DemoMode.isActive, env.isConfigured, env.library.isUnlocked, !env.library.needsRepairScan,
              PhotoLibraryService.authorizationStatus == .authorized, PhotoAvailability.isAvailable else { return Result() }
        guard lock.withLock({
            guard !running else { return false }
            running = true
            return true
        }) else { return Result() }
        defer { lock.withLock { running = false } }
        do {
            return try await check()
        } catch {
            AppLog.shared.warn("Favorites not matched with Photos, will try again: \(error.localizedDescription)")
            return Result()
        }
    }

    private func check() async throws -> Result {
        let store = env.store
        let items = try store.items(status: .backedUp).filter { $0.localIdentifier != nil }
        let lastSeen = try store.photosFavorites()
        let latest = MetaLog.latest(try store.metaNotes())
        let waiting = try env.library.chatId.map { try store.queuedMetaChanges(chatId: $0) } ?? [:]
        // One query for every favorite in Photos, however big the library: a set lookup per item after that.
        let favorites = Self.favoriteIdentifiers()

        var toPhotos: [Bool: [MediaItem]] = [:], toNote: [Bool: [MediaItem]] = [:]
        var remember: [String: Bool?] = [:]
        let linked = Set(items.map(\.id))
        for id in lastSeen.keys where !linked.contains(id) { remember[id] = .some(nil) }
        for item in items {
            guard let local = item.localIdentifier else { continue }
            let photos = favorites.contains(local)
            let noteDecides = latest[item.id]?[.favorite] != nil || waiting[item.id]?[.favorite] != nil
            switch PhotosFavorite.decide(photos: photos, lastSeen: lastSeen[item.id], library: item.favorite, noteDecides: noteDecides) {
            case .remember: if lastSeen[item.id] != photos { remember[item.id] = photos }
            case .setInPhotos(let value): toPhotos[value, default: []].append(item)
            case .sendNote(let value): toNote[value, default: []].append(item)
            }
        }

        var result = Result()
        for (value, group) in toPhotos {
            // Read again from the asset itself, right before writing: the photo may have gone, or changed since the query.
            let current = Self.favorites(of: group.compactMap(\.localIdentifier))
            let ready = group.filter { current[$0.localIdentifier!] == !value }
            guard !ready.isEmpty else { continue }
            // One change for the lot, so iOS asks at most once.
            try await env.photos.setFavorite(ready.compactMap(\.localIdentifier), value)
            for item in ready { remember[item.id] = value }
            result.setInPhotos += ready.count
        }
        for (value, group) in toNote {
            // Only photos really in Photos with that value: a link to a photo that's gone must not unfavorite it everywhere.
            let current = Self.favorites(of: group.compactMap(\.localIdentifier))
            let ready = group.filter { current[$0.localIdentifier!] == value }
            guard !ready.isEmpty else { continue }
            try MetaSync.shared.change(ready, key: .favorite, value: value)
            for item in ready { remember[item.id] = value }
            result.sent += ready.count
        }
        try store.setPhotosFavorites(remember)
        if result.setInPhotos > 0 || result.sent > 0 {
            appLog("Favorites matched with Photos: \(result.setInPhotos) changed in Photos, \(result.sent) sent to your other devices")
        }
        return result
    }

    /// Local identifiers of every favorite in Photos.
    private static func favoriteIdentifiers() -> Set<String> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "favorite == YES")
        options.includeHiddenAssets = true
        let assets = PHAsset.fetchAssets(with: options)
        var ids = Set<String>()
        ids.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        return ids
    }

    /// The favorite of each asset still in Photos.
    private static func favorites(of identifiers: [String]) -> [String: Bool] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        var result: [String: Bool] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: options).enumerateObjects { asset, _, _ in
            result[asset.localIdentifier] = asset.isFavorite
        }
        return result
    }
}
