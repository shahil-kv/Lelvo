package app.lelvo.core.backup

import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.session.TelegramErrors
import kotlin.math.min
import kotlin.math.pow

/** Upload job states (docs/ARCHITECTURE.md "Job queue state machine"), as iOS `JobState`. */
enum class JobState { Pending, Uploading, Verified, Failed }

data class JobStatus(
    val state: JobState = JobState.Pending,
    val attempts: Int = 0,
    val lastError: String? = null,
    /** Don't start before this time, epoch ms (FLOOD_WAIT or backoff). */
    val notBefore: Long? = null,
) {
    fun isRunnable(now: Long): Boolean = state == JobState.Pending && (notBefore?.let { it <= now } ?: true)
}

sealed interface JobEvent {
    data object Start : JobEvent
    /** Telegram confirmed the message; [sizeMatches] compares the stored document size. */
    data class Sent(val sizeMatches: Boolean) : JobEvent
    data class FloodWait(val seconds: Int) : JobEvent
    data class Error(val reason: String, val transient: Boolean) : JobEvent
    /** The app was killed or the work stopped mid-upload. */
    data object Interrupted : JobEvent
    data object Retry : JobEvent
}

/** Exponential backoff ceiling, as iOS `BackoffPolicy.ceiling` (no jitter: the job machine uses the ceiling). */
data class Backoff(val baseSeconds: Double = 5.0, val maxSeconds: Double = 30.0 * 60, val maxAttempts: Int = JobMachine.MAX_ATTEMPTS) {
    fun ceilingSeconds(attempt: Int): Double = min(maxSeconds, baseSeconds * 2.0.pow(min(attempt, 20)))
}

/** iOS `JobMachine`, the same transitions and words. */
object JobMachine {
    const val MAX_ATTEMPTS = 5

    fun reduce(job: JobStatus, event: JobEvent, now: Long = System.currentTimeMillis(), backoff: Backoff = Backoff()): JobStatus =
        when {
            job.state == JobState.Pending && event == JobEvent.Start -> job.copy(state = JobState.Uploading, notBefore = null)
            job.state == JobState.Uploading && event is JobEvent.Sent ->
                if (event.sizeMatches) job.copy(state = JobState.Verified, lastError = null, notBefore = null)
                else job.copy(
                    state = JobState.Failed, attempts = job.attempts + 1,
                    lastError = "Telegram stored a file with a different size than was uploaded.",
                )
            // Telegram's instruction, not our failure: wait exactly that long and try again without counting an attempt.
            job.state == JobState.Uploading && event is JobEvent.FloodWait -> job.copy(
                state = JobState.Pending, notBefore = now + maxOf(1, event.seconds) * 1000L,
                lastError = "Telegram asked to wait ${event.seconds} s (FLOOD_WAIT).",
            )
            job.state == JobState.Uploading && event is JobEvent.Error -> {
                val attempts = job.attempts + 1
                if (event.transient && attempts < MAX_ATTEMPTS) job.copy(
                    state = JobState.Pending, attempts = attempts, lastError = event.reason,
                    notBefore = now + (backoff.ceilingSeconds(attempts - 1) * 1000).toLong(),
                ) else job.copy(state = JobState.Failed, attempts = attempts, lastError = event.reason)
            }
            job.state == JobState.Uploading && event == JobEvent.Interrupted -> job.copy(state = JobState.Pending)
            job.state == JobState.Failed && event == JobEvent.Retry -> JobStatus()
            // Invalid transitions are ignored; verified is terminal.
            else -> job
        }
}

/** The job view of an item's status (iOS `MediaItem.job`). */
val LibraryItem.job: JobStatus
    get() = JobStatus(
        state = when (status) {
            ItemStatus.Queued -> JobState.Pending
            ItemStatus.Uploading -> JobState.Uploading
            ItemStatus.BackedUp, ItemStatus.Trashed -> JobState.Verified
            ItemStatus.Failed, ItemStatus.TooLarge -> JobState.Failed
        },
        attempts = attempts, lastError = lastError, notBefore = notBefore,
    )

fun LibraryItem.withJob(job: JobStatus): LibraryItem = copy(
    status = when (job.state) {
        JobState.Pending -> ItemStatus.Queued
        JobState.Uploading -> ItemStatus.Uploading
        JobState.Verified -> ItemStatus.BackedUp
        JobState.Failed -> ItemStatus.Failed
    },
    attempts = job.attempts, lastError = job.lastError, notBefore = job.notBefore,
)

/** An event the machine ignores changes nothing: a Trashed item (verified for the machine) must never become BackedUp. */
fun LibraryItem.reduced(event: JobEvent, now: Long = System.currentTimeMillis()): LibraryItem {
    val before = job
    val after = JobMachine.reduce(before, event, now)
    return if (after == before) this else withJob(after)
}

/** TDLib errors by what to do about them (iOS `TelegramErrorKind`). */
sealed interface TelegramErrorKind {
    data class FloodWait(val seconds: Int) : TelegramErrorKind
    data object Transient : TelegramErrorKind
    data object Auth : TelegramErrorKind
    data object Permanent : TelegramErrorKind
}

object TelegramErrorClassifier {
    fun classify(code: Int, message: String): TelegramErrorKind {
        val upper = message.uppercase()
        val seconds = TelegramErrors.floodWaitSeconds(message)
        if (seconds != null && (code == 429 || "FLOOD" in upper || "retry after" in message)) return TelegramErrorKind.FloodWait(seconds)
        if (code == 429) return TelegramErrorKind.FloodWait(5)
        if (code == 401 || "AUTH_KEY" in message || "SESSION_REVOKED" in message || "Unauthorized" in message) return TelegramErrorKind.Auth
        if (code >= 500 || (code == 406 && "TIMEOUT" in message) || code == -1) return TelegramErrorKind.Transient
        if ("NETWORK" in upper || "TIMEOUT" in upper || "CONNECTION" in upper || ("FILE_PART" in upper && "MISSING" in upper)) {
            return TelegramErrorKind.Transient
        }
        return TelegramErrorKind.Permanent
    }
}
