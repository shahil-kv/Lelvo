import Foundation

/// File names for files written on this device (export staging, Save to phone).
public enum FileNames {
    /// Most file systems allow 255 bytes per name. Staging adds a prefix (a UUID and a role), so a name is kept well below.
    public static let maxBytes = 160

    /// `name` with path and shell characters replaced, cut to `maxBytes` UTF-8 bytes with its extension kept. The full
    /// name stays in the caption: only the file on disk is shorter (I13, a 228-character name failed to export).
    public static func safe(_ name: String, maxBytes: Int = maxBytes) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")).joined(separator: "_")
        guard !cleaned.isEmpty else { return "file" }
        guard cleaned.utf8.count > maxBytes else { return cleaned }
        let ns = cleaned as NSString
        var ext = ns.pathExtension
        if ext.utf8.count > 16 { ext = "" }
        var base = ext.isEmpty ? cleaned : ns.deletingPathExtension
        let room = maxBytes - (ext.isEmpty ? 0 : ext.utf8.count + 1)
        // Drop whole characters, so an emoji or accented letter is never split.
        while base.utf8.count > room { base.removeLast() }
        if base.isEmpty { base = "file" }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }
}
