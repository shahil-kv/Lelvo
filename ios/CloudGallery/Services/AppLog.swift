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
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("cloudgallery.log")
    }

    private var secrets: [String] {
        [KeychainStore.string(for: .botToken), KeychainStore.string(for: .passphrase), KeychainStore.string(for: .chatId)]
            .compactMap { $0 }
    }

    func log(_ message: String, level: Level = .info) {
        let clean = Redactor.redact(message, extraSecrets: secrets)
        osLog.log("\(level.rawValue, privacy: .public) \(clean, privacy: .private)")
        let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(clean)\n"
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
