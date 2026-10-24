import Foundation

/// A file stored in the Telegram chat.
public struct RemoteFile: Codable, Equatable, Hashable, Sendable {
    public var messageId: Int64
    public var fileId: String
    public var fileUniqueId: String
    /// Size of the uploaded bytes (ciphertext size when encrypted).
    public var size: Int64

    public init(messageId: Int64, fileId: String, fileUniqueId: String, size: Int64) {
        self.messageId = messageId
        self.fileId = fileId
        self.fileUniqueId = fileUniqueId
        self.size = size
    }

    public init(message: TGMessage) throws {
        guard let doc = message.document else { throw TelegramError.decoding("Message has no document") }
        self.init(messageId: message.messageId, fileId: doc.fileId, fileUniqueId: doc.fileUniqueId, size: doc.fileSize ?? 0)
    }
}

public enum MediaKind: String, Codable, Sendable {
    case photo, video, livePhoto
}

public enum ItemStatus: String, Codable, Sendable, CaseIterable {
    /// Selected for backup, waiting for a slot.
    case queued
    /// Upload tasks are in flight.
    case uploading
    /// Telegram confirmed every required message and returned file_ids.
    case backedUp
    /// Larger than the Bot API's 50 MB upload limit — needs version 2. Never counts as backed up.
    case tooLarge
    /// Gave up after retries; will be retried on the next run.
    case failed
}

/// Which file of an item an upload carries.
public enum UploadRole: String, Codable, Sendable {
    case original, pairedVideo, thumbnail, edited
}

/// Everything known about one photo/video, persisted locally and (when backed up) in the cloud index.
public struct MediaItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var localIdentifier: String?
    public var sha256: String
    public var filename: String
    public var kind: MediaKind
    public var uti: String?
    public var creationDate: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var duration: Double?
    /// Plaintext size of the original.
    public var fileSize: Int64
    public var encrypted: Bool
    public var original: RemoteFile?
    public var thumbnail: RemoteFile?
    public var pairedVideo: RemoteFile?
    public var pairedVideoFilename: String?
    public var pairedVideoSize: Int64?
    public var uploadedAt: Date?
    public var status: ItemStatus
    public var lastError: String?
    public var attempts: Int
    public var verifiedAt: Date?

    // Format 1 (TDLib, docs/CLOUD_FORMAT.md). Parts per caption role ("o", "pv", "t"), ordered by part index.
    public var cloudParts: [String: [RemoteFile]]?
    /// SHA-256 per role (the `h` caption field); `sha256` above is the original's.
    public var roleHashes: [String: String]?
    /// Expected part count per role (from the caption `p` field), to detect incomplete uploads.
    public var expectedParts: [String: Int]?
    public var codec: String?
    public var hdr: Int?
    public var tzOffsetMinutes: Int?
    public var albums: [String]?
    public var favorite: Bool?
    public var mimeType: String?
    /// Job queue: earliest time to retry (FLOOD_WAIT / backoff).
    public var notBefore: Date?
    /// Uploaded by the 1.0 Bot API app (not format 1).
    public var legacy: Bool?
    /// From the caption `l` field: the asset this was uploaded from (used to re-link after a reinstall).
    public var sourceLocalIdentifier: String?
    /// Queued because the user picked it (Back up on chosen photos, Retry). Runs that aren't "Back up now"
    /// upload only these, so picking a few photos never drains an older full queue.
    public var chosen: Bool?
    /// Edited in Photos (crop, filter, trim…): the rendered edit is stored as role `e` next to the original.
    public var hasEdit: Bool?
    public var editedFilename: String?
    public var editedSize: Int64?
    /// The asset's `modificationDate` when it was backed up; a later date with an edit means re-check the edit.
    public var assetModifiedAt: Date?
    /// Queued only to upload a newer edited version (the original is already in the cloud).
    public var editCheck: Bool?

    /// Ids are lowercase, like the caption `id` field, so a channel scan matches the local item.
    public init(id: String = UUID().uuidString.lowercased(), localIdentifier: String?, sha256: String, filename: String,
                kind: MediaKind, uti: String? = nil, creationDate: Date?, latitude: Double? = nil, longitude: Double? = nil,
                pixelWidth: Int = 0, pixelHeight: Int = 0, duration: Double? = nil, fileSize: Int64,
                encrypted: Bool = false, status: ItemStatus = .queued) {
        self.id = id
        self.localIdentifier = localIdentifier
        self.sha256 = sha256
        self.filename = filename
        self.kind = kind
        self.uti = uti
        self.creationDate = creationDate
        self.latitude = latitude
        self.longitude = longitude
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.fileSize = fileSize
        self.encrypted = encrypted
        self.status = status
        self.attempts = 0
    }

    /// Roles that must be confirmed before the item counts as backed up.
    public var requiredRoles: [UploadRole] {
        kind == .livePhoto ? [.original, .pairedVideo, .thumbnail] : [.original, .thumbnail]
    }

    public func remote(for role: UploadRole) -> RemoteFile? {
        switch role {
        case .original: return original
        case .pairedVideo: return pairedVideo
        case .thumbnail: return thumbnail
        case .edited: return nil // format 1 only (`cloudParts["e"]`)
        }
    }

    public mutating func setRemote(_ file: RemoteFile, for role: UploadRole) {
        switch role {
        case .original: original = file
        case .pairedVideo: pairedVideo = file
        case .thumbnail: thumbnail = file
        case .edited: break
        }
    }

    public var isFullyUploaded: Bool {
        if cloudParts != nil { return isCompleteInCloud }
        return requiredRoles.allSatisfy { remote(for: $0) != nil }
    }

    // MARK: Format 1

    public static func captionRole(_ role: UploadRole) -> String {
        switch role {
        case .original: return "o"
        case .pairedVideo: return "pv"
        case .thumbnail: return "t"
        case .edited: return "e"
        }
    }

    /// Roles that must exist in the cloud for a format-1 item (thumbnail only for E2E items).
    public var requiredCaptionRoles: [String] {
        var roles = kind == .livePhoto ? ["o", "pv"] : ["o"]
        if encrypted { roles.append("t") }
        if hasEdit == true { roles.append("e") }
        return roles
    }

    public func parts(_ role: String) -> [RemoteFile] { cloudParts?[role] ?? [] }

    /// Every required role present with all of its parts.
    public var isCompleteInCloud: Bool {
        requiredCaptionRoles.allSatisfy { role in
            let have = parts(role).count
            return have > 0 && have == (expectedParts?[role] ?? 1)
        }
    }

    public mutating func setParts(_ files: [RemoteFile], role: String, expected: Int) {
        var all = cloudParts ?? [:]
        all[role] = files
        cloudParts = all
        var exp = expectedParts ?? [:]
        exp[role] = expected
        expectedParts = exp
    }

    /// Every message ID belonging to this item (for deletion).
    public var allMessageIds: [Int64] {
        var ids = (cloudParts ?? [:]).values.flatMap { $0.map(\.messageId) }
        ids += [original, pairedVideo, thumbnail].compactMap { $0?.messageId }
        return Array(Set(ids)).sorted()
    }

    /// Total bytes stored in Telegram for the original(s).
    public var cloudBytes: Int64 {
        if let cloudParts { return cloudParts.values.flatMap { $0 }.reduce(0) { $0 + $1.size } }
        return (original?.size ?? 0) + (pairedVideo?.size ?? 0)
    }

    /// Job-queue view of `status`.
    public var job: JobStatus {
        get {
            let state: JobState
            switch status {
            case .queued: state = .pending
            case .uploading: state = .uploading
            case .backedUp: state = .verified
            case .failed, .tooLarge: state = .failed
            }
            return JobStatus(state: state, attempts: attempts, lastError: lastError, notBefore: notBefore)
        }
        set {
            switch newValue.state {
            case .pending: status = .queued
            case .uploading: status = .uploading
            case .verified: status = .backedUp
            case .failed: status = .failed
            }
            attempts = newValue.attempts
            lastError = newValue.lastError
            notBefore = newValue.notBefore
        }
    }

    /// Largest uploaded part, used against the Bot API's 20 MB download limit.
    public var largestUploadedSize: Int64 {
        max(original?.size ?? fileSize, pairedVideo?.size ?? pairedVideoSize ?? 0)
    }

    public var sizeClass: SizeClass {
        if status == .tooLarge { return .tooLargeToUpload }
        // Format-1 items are uploaded and downloaded through the user account: no Bot API size limits.
        if cloudParts != nil { return .normal }
        return SizePolicy.classify(largestUploadedSize)
    }

    /// Can the app download this original again?
    public var isViewableFromCloud: Bool { status == .backedUp && sizeClass == .normal }

    /// Caption written next to each upload so a future version can rebuild the index from chat history.
    public func caption(for role: UploadRole) -> String {
        var parts = ["#cloudgallery", "id:\(id)", "role:\(role.rawValue)"]
        if !encrypted {
            parts.append("sha256:\(sha256)")
            if let creationDate { parts.append("date:\(ISO8601DateFormatter().string(from: creationDate))") }
        } else {
            parts.append("e2e:1")
        }
        return parts.joined(separator: " ")
    }
}

public enum SizeClass: String, Codable, Sendable {
    /// ≤ 20 MB — upload, view and verify via the Bot API.
    case normal
    /// 20–50 MB — uploads, but the Bot API cannot download it back. Viewing needs version 2.
    case uploadOnly
    /// > 50 MB — the Bot API cannot upload it. Needs version 2.
    case tooLargeToUpload
}

public enum SizePolicy {
    public static func classify(_ bytes: Int64) -> SizeClass {
        if bytes > TelegramClient.maxUploadBytes { return .tooLargeToUpload }
        if bytes > TelegramClient.maxDownloadBytes { return .uploadOnly }
        return .normal
    }
}

/// The cloud index: every backed-up item, plus what is needed to decrypt E2E files.
public struct CloudIndex: Codable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var createdAt: Date
    public var deviceName: String
    /// Salt for deriving the E2E master key from the passphrase (nil if E2E was never enabled).
    public var fileKeySalt: Data?
    public var items: [MediaItem]

    public init(version: Int = CloudIndex.currentVersion, createdAt: Date = Date(), deviceName: String,
                fileKeySalt: Data?, items: [MediaItem]) {
        self.version = version
        self.createdAt = createdAt
        self.deviceName = deviceName
        self.fileKeySalt = fileKeySalt
        self.items = items
    }
}

/// Pinned when the encrypted index is larger than one Bot API download (20 MB).
public struct IndexManifest: Codable, Equatable {
    public var version: Int
    public var createdAt: Date
    public var totalSize: Int64
    public var sha256: String
    public var chunks: [RemoteFile]

    public init(version: Int = 1, createdAt: Date = Date(), totalSize: Int64, sha256: String, chunks: [RemoteFile]) {
        self.version = version
        self.createdAt = createdAt
        self.totalSize = totalSize
        self.sha256 = sha256
        self.chunks = chunks
    }
}
