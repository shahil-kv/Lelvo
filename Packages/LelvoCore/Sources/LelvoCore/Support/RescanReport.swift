import Foundation

/// What a re-scan of the library found, in words for the person who tapped the button.
public struct RescanReport: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let upToDate: Bool

    /// `favoritesMatched`: photos whose favorite was brought in line between Photos and the Telegram library (#99).
    public init(itemsBefore: Int, itemsAfter: Int, incomplete: Int, duplicates: Int, favoritesMatched: Int = 0) {
        let change = itemsAfter - itemsBefore
        var notes: [String] = []
        if change > 0 { notes.append("\(change.formatted()) new item\(change == 1 ? "" : "s")") }
        if change < 0 { notes.append("\((-change).formatted()) item\(change == -1 ? "" : "s") gone") }
        if incomplete > 0 { notes.append("\(incomplete.formatted()) incomplete") }
        if duplicates > 0 { notes.append("\(duplicates.formatted()) duplicate upload\(duplicates == 1 ? "" : "s")") }
        if favoritesMatched > 0 { notes.append("\(favoritesMatched.formatted()) favorite\(favoritesMatched == 1 ? "" : "s") updated") }
        upToDate = notes.isEmpty
        if upToDate {
            title = "Everything is up to date"
            detail = "\(itemsAfter.formatted()) item\(itemsAfter == 1 ? "" : "s") in your Telegram library."
        } else {
            title = change == 0 ? "Library checked" : "Library updated"
            detail = notes.joined(separator: ", ") + "."
        }
    }
}
