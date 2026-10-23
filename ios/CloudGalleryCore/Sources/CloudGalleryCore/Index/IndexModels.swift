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
    case original, pairedVideo, thumbnail
}

/// Everything known about one photo/video, persisted locally and (when backed up) in the cloud index.
public struct LibraryItem: Codable, Equatable, Identifiable, Sendable {
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

    public init(id: String = UUID().uuidString, localIdentifier: String?, sha256: String, filename: String,
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
        }
    }

    public mutating func setRemote(_ file: RemoteFile, for role: UploadRole) {
        switch role {
        case .original: original = file
        case .pairedVideo: pairedVideo = file
        case .thumbnail: thumbnail = file
        }
    }

    public var isFullyUploaded: Bool { requiredRoles.allSatisfy { remote(for: $0) != nil } }

    /// Largest uploaded part, used against the Bot API's 20 MB download limit.
    public var largestUploadedSize: Int64 {
        max(original?.size ?? fileSize, pairedVideo?.size ?? pairedVideoSize ?? 0)
    }

    public var sizeClass: SizeClass {
        if status == .tooLarge { return .tooLargeToUpload }
        return SizePolicy.classify(largestUploadedSize)
    }

    /// Can the app download this original again through the Bot API?
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
    public var items: [LibraryItem]

    public init(version: Int = CloudIndex.currentVersion, createdAt: Date = Date(), deviceName: String,
                fileKeySalt: Data?, items: [LibraryItem]) {
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
