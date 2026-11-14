import Foundation

/// The suggested name for a new library: "Lelvo Library", or "Lelvo Library 2" (3, …) when that name is taken, so two
/// libraries never look the same in the list or in Telegram.
public enum LibraryNames {
    public static func unused(_ base: String, taken: [String]) -> String {
        let used = Set(taken.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        if !used.contains(base.lowercased()) { return base }
        var n = 2
        while used.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // The channel sits in the user's Telegram chat list next to their other chats. The warning around its name is
    // there so nobody clears it out by mistake; inside the app only the plain name shows.
    static let prefix = "🚨 "
    static let suffix = " · Do not delete 🚨"
    /// Telegram allows 128 characters in a channel title; this leaves room for the warning.
    public static let maxNameLength = 100

    /// The channel title in Telegram for a library name: "🚨 Lelvo Library · Do not delete 🚨".
    public static func channelTitle(_ name: String) -> String {
        prefix + String(plain(name).prefix(maxNameLength)) + suffix
    }

    /// The library name for a channel title, without the warning. Titles without it (older libraries, or a name the
    /// user changed in Telegram) come back as they are.
    public static func plain(_ title: String) -> String {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix(prefix), name.hasSuffix(suffix), name.count >= prefix.count + suffix.count {
            name = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
