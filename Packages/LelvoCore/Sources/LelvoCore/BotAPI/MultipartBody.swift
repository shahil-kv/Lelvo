import Foundation

/// Streams a multipart/form-data body to disk so large files never sit fully in memory
/// and the result can be handed to a background `URLSession` upload task.
public struct MultipartBody {
    public let boundary: String
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public init(boundary: String = "Lelvo-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public struct FilePart {
        public let fieldName: String
        public let fileName: String
        public let mimeType: String
        public let fileURL: URL
        public init(fieldName: String, fileName: String, mimeType: String, fileURL: URL) {
            self.fieldName = fieldName
            self.fileName = fileName
            self.mimeType = mimeType
            self.fileURL = fileURL
        }
    }

    /// Writes the body to `destination` and returns its size in bytes.
    @discardableResult
    public func write(fields: [(String, String)], file: FilePart, to destination: URL) throws -> Int64 {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        fm.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }

        for (name, value) in fields {
            try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        let safeName = file.fileName.replacingOccurrences(of: "\"", with: "_")
        try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(safeName)\"\r\nContent-Type: \(file.mimeType)\r\n\r\n".utf8))

        let input = try FileHandle(forReadingFrom: file.fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return Int64(try out.offset())
    }

    /// In-memory variant for small payloads (index, manifest).
    public func data(fields: [(String, String)], fieldName: String, fileName: String, mimeType: String, fileData: Data) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
