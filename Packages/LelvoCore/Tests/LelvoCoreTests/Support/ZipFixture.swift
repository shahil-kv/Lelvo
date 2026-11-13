import Foundation
import Compression
@testable import LelvoCore

/// Writes small zips for tests, so no binary fixtures are committed: stored and DEFLATE entries, data descriptors
/// (general-purpose bit 3) and ZIP64 records.
enum ZipFixture {
    struct Entry {
        var name: String
        var data: Data
        var deflate = false
        var descriptor = false

        init(_ name: String, _ data: Data, deflate: Bool = false, descriptor: Bool = false) {
            self.name = name
            self.data = data
            self.deflate = deflate
            self.descriptor = descriptor
        }

        init(_ name: String, _ text: String, deflate: Bool = false) {
            self.init(name, Data(text.utf8), deflate: deflate)
        }
    }

    /// 2019-07-04 00:00 in MS-DOS format.
    static let dosDate: UInt16 = UInt16((2019 - 1980) << 9 | 7 << 5 | 4)

    static func make(_ entries: [Entry], zip64: Bool = false) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let payload = entry.deflate ? deflate(entry.data) : entry.data
            var crc = CRC32()
            crc.update(entry.data)
            let offset = UInt64(out.count)
            var flags: UInt16 = 1 << 11
            if entry.descriptor { flags |= 1 << 3 }
            let method: UInt16 = entry.deflate ? 8 : 0

            // Local header.
            var zip64Local = Data()
            if zip64 {
                zip64Local.le(UInt16(1)); zip64Local.le(UInt16(16))
                zip64Local.le(entry.descriptor ? 0 : UInt64(entry.data.count))
                zip64Local.le(entry.descriptor ? 0 : UInt64(payload.count))
            }
            out.le(UInt32(0x04034b50)); out.le(UInt16(zip64 ? 45 : 20)); out.le(flags); out.le(method)
            out.le(UInt16(0)); out.le(dosDate)
            out.le(entry.descriptor ? 0 : crc.value)
            out.le(zip64 ? 0xFFFF_FFFF : (entry.descriptor ? 0 : UInt32(payload.count)))
            out.le(zip64 ? 0xFFFF_FFFF : (entry.descriptor ? 0 : UInt32(entry.data.count)))
            out.le(UInt16(name.count)); out.le(UInt16(zip64Local.count))
            out.append(name); out.append(zip64Local)
            out.append(payload)
            if entry.descriptor {
                out.le(UInt32(0x08074b50)); out.le(crc.value)
                if zip64 { out.le(UInt64(payload.count)); out.le(UInt64(entry.data.count)) } else {
                    out.le(UInt32(payload.count)); out.le(UInt32(entry.data.count))
                }
            }

            // Central directory record.
            var zip64Central = Data()
            if zip64 {
                zip64Central.le(UInt16(1)); zip64Central.le(UInt16(24))
                zip64Central.le(UInt64(entry.data.count)); zip64Central.le(UInt64(payload.count)); zip64Central.le(offset)
            }
            central.le(UInt32(0x02014b50)); central.le(UInt16(zip64 ? 45 : 20)); central.le(UInt16(zip64 ? 45 : 20))
            central.le(flags); central.le(method); central.le(UInt16(0)); central.le(dosDate); central.le(crc.value)
            central.le(zip64 ? 0xFFFF_FFFF : UInt32(payload.count))
            central.le(zip64 ? 0xFFFF_FFFF : UInt32(entry.data.count))
            central.le(UInt16(name.count)); central.le(UInt16(zip64Central.count)); central.le(UInt16(0))
            central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt32(0))
            central.le(zip64 ? 0xFFFF_FFFF : UInt32(offset))
            central.append(name); central.append(zip64Central)
        }
        let centralOffset = UInt64(out.count)
        out.append(central)
        if zip64 {
            let recordOffset = UInt64(out.count)
            out.le(UInt32(0x06064b50)); out.le(UInt64(44)); out.le(UInt16(45)); out.le(UInt16(45))
            out.le(UInt32(0)); out.le(UInt32(0))
            out.le(UInt64(entries.count)); out.le(UInt64(entries.count))
            out.le(UInt64(central.count)); out.le(centralOffset)
            out.le(UInt32(0x07064b50)); out.le(UInt32(0)); out.le(recordOffset); out.le(UInt32(1))
        }
        out.le(UInt32(0x06054b50)); out.le(UInt16(0)); out.le(UInt16(0))
        out.le(zip64 ? 0xFFFF : UInt16(entries.count)); out.le(zip64 ? 0xFFFF : UInt16(entries.count))
        out.le(zip64 ? 0xFFFF_FFFF : UInt32(central.count))
        out.le(zip64 ? 0xFFFF_FFFF : UInt32(centralOffset))
        out.le(UInt16(0))
        return out
    }

    static func deflate(_ data: Data) -> Data {
        var out = Data()
        let filter = try! OutputFilter(.compress, using: .zlib) { chunk in if let chunk { out.append(chunk) } }
        try! filter.write(data)
        try! filter.finalize()
        return out
    }

    static func write(_ entries: [Entry], zip64: Bool = false, name: String = "takeout-001.zip") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try make(entries, zip64: zip64).write(to: url)
        return url
    }

    static func random(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }
}

extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
