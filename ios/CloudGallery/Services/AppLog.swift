import Foundation
import os
import CloudGalleryCore

/// Small on-device log (no analytics, never leaves the phone unless the user shares it).
/// Every line is redacted before it is written.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    enum Level: String { case info = "INFO", warn = "WARN", error = "ERROR" }

    private let queue = DispatchQueue(label: "cloudgallery.log")
    private let osLog = Logger(subsystem: "com.shahil-kv.cloudgallery", category: "app")
    private let maxBytes = 1_000_000
    let fileURL: URL
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let dir = AppPaths.support.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("cloudgallery.log")
    }

    private var secrets: [String] {
        [KeychainStore.string(for: .botToken), KeychainStore.string(for: .passphrase), KeychainStore.string(for: .chatId),
         KeychainStore.string(for: .tdApiHash), TDCredentials.bundled?.apiHash]
            .compactMap { $0 }
    }

    func log(_ message: String, level: Level = .info) {
        let clean = Redactor.redact(message, extraSecrets: secrets)
        osLog.log("\(level.rawValue, privacy: .public) \(clean, privacy: .private)")
        let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(clean)\n"
        #if DEBUG
        print(line, terminator: "") // visible in a live device console (devicectl --console)
        #endif
        queue.async { [self] in
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue, size > maxBytes {
                let old = fileURL.deletingPathExtension().appendingPathExtension("old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: fileURL, to: old)
            }
            if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: fileURL) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
                try? h.close()
            }
        }
    }

    func error(_ message: String) { log(message, level: .error) }
    func warn(_ message: String) { log(message, level: .warn) }

    /// Full log text, redacted again in case secrets changed since lines were written.
    func contents() -> String {
        queue.sync {
            let old = fileURL.deletingPathExtension().appendingPathExtension("old.log")
            let text = [old, fileURL].compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
            return Redactor.redact(text, extraSecrets: secrets)
        }
    }

    func exportFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CloudGallery-log.txt")
        do {
            try contents().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch { return nil }
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingPathExtension().appendingPathExtension("old.log"))
        }
    }
}

func appLog(_ message: String) { AppLog.shared.log(message) }

extension URL {
    /// A URL from a string literal known to be valid at compile time.
    static func literal(_ string: StaticString) -> URL {
        guard let url = URL(string: "\(string)") else { preconditionFailure("Invalid URL literal \(string)") }
        return url
    }
}

/// Where CloudGallery keeps its files. iOS apps are already in their own container; the Mac app isn't sandboxed,
/// so it uses its own folders (~/Library/Application Support/<bundle id>, ~/Library/Caches/<bundle id>).
enum AppPaths {
    static let support = scoped(.applicationSupportDirectory)
    static let caches = scoped(.cachesDirectory)

    private static func scoped(_ directory: FileManager.SearchPathDirectory) -> URL {
        let base = FileManager.default.urls(for: directory, in: .userDomainMask)[0]
        #if os(macOS)
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.shahil-kv.cloudgallery.mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
        #else
        return base
        #endif
    }
}
