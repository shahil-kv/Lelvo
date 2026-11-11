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
}
