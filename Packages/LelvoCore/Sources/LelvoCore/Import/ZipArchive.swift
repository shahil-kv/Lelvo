import Foundation
import Compression
import CryptoKit

/// One file in a zip, as its central directory describes it.
public struct ZipEntry: Sendable, Equatable, Hashable, Codable {
    public let path: String
    public let compressedSize: Int64
    public let size: Int64
    public let crc32: UInt32
    public let method: UInt16
    public let localHeaderOffset: Int64
    public let modified: Date?

    public init(path: String, compressedSize: Int64, size: Int64, crc32: UInt32, method: UInt16,
                localHeaderOffset: Int64, modified: Date?) {
        self.path = path
        self.compressedSize = compressedSize
        self.size = size
        self.crc32 = crc32
        self.method = method
        self.localHeaderOffset = localHeaderOffset
        self.modified = modified
    }
}

public enum ZipError: LocalizedError, Equatable {
    case notAZip, tgz, unsupportedMethod(UInt16), encrypted, crcMismatch(String), truncated, tooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .notAZip: return "This file isn't a zip file. Choose the zip files from Google Takeout."
        case .tgz: return "This file is a .tgz export. Request a new export from Google Takeout and choose .zip."
        case .unsupportedMethod: return "Lelvo can't read a file in this zip. Request a new export from Google Takeout."
        case .encrypted: return "This zip is protected with a password, so Lelvo can't read it."
        case .crcMismatch(let name): return "\(Self.fileName(name)) is damaged in this zip. Download the zip again from Google Takeout."
        case .truncated: return "This zip is incomplete. Download it again from Google Takeout."
        case .tooLarge(let name): return "\(Self.fileName(name)) is too large to read here."
        }
    }

    private static func fileName(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// Reads a zip without unzipping it: the central directory once, then one entry at a time, streamed. Handles stored and
/// DEFLATE entries, ZIP64 and data descriptors, which is everything Google Takeout writes.
public final class ZipArchive: @unchecked Sendable {
    public let entries: [ZipEntry]
    private let handle: FileHandle
    private let fileSize: Int64
    private let encrypted: Set<Int64>
    private let lock = NSLock()

    private static let chunkSize = 1 << 20

    public init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        let fileSize = Int64(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let magic = try handle.read(upToCount: 4) ?? Data()
        if magic.starts(with: [0x1F, 0x8B]) { throw ZipError.tgz }
        guard fileSize >= 22 else { throw ZipError.notAZip }

        // End of central directory: 22 bytes plus a comment of up to 65,535, at the very end.
        let tailLength = min(fileSize, 22 + 0xFFFF + 20)
        try handle.seek(toOffset: UInt64(fileSize - tailLength))
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
        guard let eocd = Self.lastIndex(of: 0x06054b50, in: tail, from: tail.count - 22) else { throw ZipError.notAZip }
        var count = Int64(tail.u16(eocd + 10))
        var centralSize = Int64(tail.u32(eocd + 12))
        var centralOffset = Int64(tail.u32(eocd + 16))

        if eocd >= 20, tail.u32(eocd - 20) == 0x07064b50 {
            try handle.seek(toOffset: tail.u64(eocd - 20 + 8))
            let record = try handle.read(upToCount: 56) ?? Data()
            guard record.count == 56, record.u32(0) == 0x06064b50 else { throw ZipError.truncated }
            count = Int64(record.u64(32))
            centralSize = Int64(record.u64(40))
            centralOffset = Int64(record.u64(48))
        }
        guard centralOffset >= 0, centralSize >= 0, centralOffset + centralSize <= fileSize else { throw ZipError.truncated }

        try handle.seek(toOffset: UInt64(centralOffset))
        let central = try handle.read(upToCount: Int(centralSize)) ?? Data()
        guard central.count == Int(centralSize) else { throw ZipError.truncated }

        var entries: [ZipEntry] = []
        var encrypted = Set<Int64>()
        entries.reserveCapacity(Int(min(count, 1_000_000)))
        var at = 0
        while at + 46 <= central.count, central.u32(at) == 0x02014b50 {
            let flags = central.u16(at + 8)
            let method = central.u16(at + 10)
            let dosTime = central.u16(at + 12), dosDate = central.u16(at + 14)
            let crc = central.u32(at + 16)
            var compressed = Int64(central.u32(at + 20))
            var size = Int64(central.u32(at + 24))
            let nameLength = Int(central.u16(at + 28)), extraLength = Int(central.u16(at + 30))
            let commentLength = Int(central.u16(at + 32))
            var offset = Int64(central.u32(at + 42))
            let nameStart = at + 46
            guard nameStart + nameLength + extraLength <= central.count else { throw ZipError.truncated }
            let nameData = central.subdata(in: (central.startIndex + nameStart)..<(central.startIndex + nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: Unicode.ASCII.self)
            var modified = Self.dosDate(dosDate, time: dosTime)

            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = central.u16(extra), length = Int(central.u16(extra + 2))
                var field = extra + 4
                let fieldEnd = min(field + length, extraEnd)
                if id == 0x0001 {
                    // ZIP64: only the fields whose 32-bit value is 0xFFFFFFFF, in this order.
                    if size == 0xFFFF_FFFF, field + 8 <= fieldEnd { size = Int64(central.u64(field)); field += 8 }
                    if compressed == 0xFFFF_FFFF, field + 8 <= fieldEnd { compressed = Int64(central.u64(field)); field += 8 }
                    if offset == 0xFFFF_FFFF, field + 8 <= fieldEnd { offset = Int64(central.u64(field)) }
                } else if id == 0x5455, length >= 5, central[central.startIndex + field] & 1 != 0 {
                    // Extended timestamp: the modification time in UTC, better than the zone-less MS-DOS time.
                    modified = Date(timeIntervalSince1970: TimeInterval(central.u32(field + 1)))
                }
                extra = extra + 4 + length
            }
            at = extraEnd + commentLength

            if name.hasSuffix("/") { continue }
            if flags & 1 != 0 { encrypted.insert(offset) }
            entries.append(ZipEntry(path: name, compressedSize: compressed, size: size, crc32: crc, method: method,
                                    localHeaderOffset: offset, modified: modified))
        }

        self.handle = handle
        self.fileSize = fileSize
        self.entries = entries
        self.encrypted = encrypted
    }

    deinit { try? handle.close() }

    /// Streams `entry` into a new file at `url`, checking its CRC-32. Returns the SHA-256 of the content (hex). On any
    /// failure the file at `url` is removed.
    @discardableResult
    public func extract(_ entry: ZipEntry, to url: URL, progress: ((Int64) -> Void)? = nil) throws -> String {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            var hasher = SHA256()
            var written: Int64 = 0
            try stream(entry) { chunk in
                try output.write(contentsOf: chunk)
                hasher.update(data: chunk)
                written += Int64(chunk.count)
                progress?(written)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
    }

    /// The whole content of a small entry (a JSON sidecar), refusing anything over `limit` bytes.
    public func data(_ entry: ZipEntry, limit: Int64) throws -> Data {
        guard entry.size <= limit else { throw ZipError.tooLarge(entry.path) }
        var out = Data(capacity: Int(entry.size))
        try stream(entry) { out.append($0) }
        return out
    }

    private func stream(_ entry: ZipEntry, into sink: (Data) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !encrypted.contains(entry.localHeaderOffset) else { throw ZipError.encrypted }
        guard entry.method == 0 || entry.method == 8 else { throw ZipError.unsupportedMethod(entry.method) }

        // Data starts after the local header, whose name and extra field lengths can differ from the central ones.
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        let header = try handle.read(upToCount: 30) ?? Data()
        guard header.count == 30, header.u32(0) == 0x04034b50 else { throw ZipError.truncated }
        let start = entry.localHeaderOffset + 30 + Int64(header.u16(26)) + Int64(header.u16(28))
        guard start + entry.compressedSize <= fileSize else { throw ZipError.truncated }
        try handle.seek(toOffset: UInt64(start))

        var crc = CRC32()
        var produced: Int64 = 0
        try withoutActuallyEscaping(sink) { sink in
            let emit: (Data) throws -> Void = { chunk in
                crc.update(chunk)
                produced += Int64(chunk.count)
                guard produced <= entry.size else { throw ZipError.crcMismatch(entry.path) }
                try sink(chunk)
            }
            let filter = entry.method == 8
                ? try OutputFilter(.decompress, using: .zlib, bufferCapacity: Self.chunkSize) { if let d = $0 { try emit(d) } }
                : nil
            var remaining = entry.compressedSize
            do {
                while remaining > 0 {
                    guard let chunk = try handle.read(upToCount: Int(min(remaining, Int64(Self.chunkSize)))),
                          !chunk.isEmpty else { throw ZipError.truncated }
                    remaining -= Int64(chunk.count)
                    if let filter { try filter.write(chunk) } else { try emit(chunk) }
                }
                try filter?.finalize()
            } catch is FilterError {
                throw ZipError.crcMismatch(entry.path)
            }
        }
        guard produced == entry.size, crc.value == entry.crc32 else { throw ZipError.crcMismatch(entry.path) }
    }

    private static func lastIndex(of signature: UInt32, in data: Data, from start: Int) -> Int? {
        var i = start
        while i >= 0 {
            if data.u32(i) == signature { return i }
            i -= 1
        }
        return nil
    }

    private static func dosDate(_ date: UInt16, time: UInt16) -> Date? {
        guard date != 0 else { return nil }
        var parts = DateComponents()
        parts.year = 1980 + Int(date >> 9)
        parts.month = Int(date >> 5 & 0xF)
        parts.day = Int(date & 0x1F)
        parts.hour = Int(time >> 11)
        parts.minute = Int(time >> 5 & 0x3F)
        parts.second = Int(time & 0x1F) * 2
        return Calendar(identifier: .gregorian).date(from: parts)
    }
}

/// CRC-32 (IEEE 802.3), as zip stores it.
public struct CRC32: Sendable {
    public private(set) var value: UInt32 = 0

    public init() {}

    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public mutating func update(_ data: Data) {
        var c = ~value
        Self.table.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for byte in bytes { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
            }
        }
        value = ~c
    }
}

private extension Data {
    func u16(_ at: Int) -> UInt16 {
        let i = startIndex + at
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func u32(_ at: Int) -> UInt32 {
        let i = startIndex + at
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func u64(_ at: Int) -> UInt64 {
        UInt64(u32(at)) | UInt64(u32(at + 4)) << 32
    }
}
