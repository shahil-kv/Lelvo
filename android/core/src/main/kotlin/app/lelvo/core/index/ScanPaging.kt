package app.lelvo.core.index

/**
 * Decides how a channel scan moves from one page of search results to the next (iOS `ScanPaging`). TDLib says the end is
 * `next_from_message_id == 0`; a page can come back empty before that. Treating an empty page as the end made a full
 * scan look as if photos had vanished from the channel, and the app then queued them to be uploaded again.
 */
class ScanPaging {
    sealed interface Step {
        /** Ask for the next page from this message id. */
        data class Next(val from: Long) : Step

        /** Telegram said there are no more results: the scan covered the whole channel. */
        data object Finished : Step

        /** Stopped early (no progress, or too many empty pages in a row). The scan did NOT cover the whole channel. */
        data object GaveUp : Step
    }

    private var emptyInARow = 0

    fun step(from: Long, nextFromMessageId: Long, pageWasEmpty: Boolean): Step {
        if (nextFromMessageId == 0L) return Step.Finished
        if (nextFromMessageId == from) return Step.GaveUp
        emptyInARow = if (pageWasEmpty) emptyInARow + 1 else 0
        if (emptyInARow > MAX_EMPTY_PAGES_IN_A_ROW) return Step.GaveUp
        return Step.Next(nextFromMessageId)
    }

    companion object {
        const val MAX_EMPTY_PAGES_IN_A_ROW = 3
    }
}
