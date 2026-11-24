import Foundation

/// Decides how a channel scan moves from one page of search results to the next. TDLib says the end is
/// `next_from_message_id == 0`; a page can come back empty before that. Treating an empty page as the end made a full
/// scan look as if photos had vanished from the channel, and the app then queued them to be uploaded again.
public struct ScanPaging: Sendable {
    public enum Step: Equatable, Sendable {
        /// Ask for the next page from this message id.
        case next(Int64)
        /// Telegram said there are no more results: the scan covered the whole channel.
        case finished
        /// Stopped early (no progress, or too many empty pages in a row). The scan did NOT cover the whole channel.
        case gaveUp
    }

    public static let maxEmptyPagesInARow = 3
    private var emptyInARow = 0

    public init() {}

    public mutating func step(from: Int64, nextFromMessageId: Int64, pageWasEmpty: Bool) -> Step {
        if nextFromMessageId == 0 { return .finished }
        if nextFromMessageId == from { return .gaveUp }
        emptyInARow = pageWasEmpty ? emptyInARow + 1 : 0
        if emptyInARow > Self.maxEmptyPagesInARow { return .gaveUp }
        return .next(nextFromMessageId)
    }
}
