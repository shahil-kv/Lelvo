package app.lelvo.core.backup

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.time.Instant
import java.time.ZoneId

/** Where a backup run came from. Same idea as iOS `RunSource`, with Android's jobs instead of shortcuts. */
enum class RunSource { App, User, NewPhotos, AutoRun, SafetyNet, Overnight, Refresh }

/**
 * One finished backup run. Counts only: no names, ids or places.
 * Encoded by hand because `core` uses the JSON tree, not the serialization compiler plugin.
 */
data class RunRecord(
    val source: RunSource,
    val startedAt: Long,
    val seconds: Double,
    val uploaded: Int,
    val remaining: Int,
    val stop: String? = null,
)

/** What the automatic upload job may ask WorkManager for. Built in core so a bad mix is caught without a device. */
data class AutoRunPlan(
    val expedited: Boolean,
    val delayMs: Long,
    val unmetered: Boolean,
    val batteryNotLow: Boolean,
    val requiresCharging: Boolean,
)

/** Why background backup cannot run on this phone. First match wins. Phase 6 shows one card. */
enum class BackgroundIssue { PartialPhotoAccess, BackgroundRestricted, BatteryOptimized, RareBucket, ForceStopped, None }

/** The rules both apps share for "what ran" and "when is the next run". No Android imports. */
object BackgroundRuns {
    private const val DAY_MS = 86_400_000L
    private val REMINDER_DAYS = intArrayOf(2, 4, 8)

    /** The stop text for a run whose process ended before it could write its own record. */
    const val KILLED = "ended with the process"

    /**
     * Runs still marked as started when a new process begins. A run clears its mark when it ends, and only one
     * process exists at a time, so a mark left behind means Android (or a force stop) ended the process mid-run.
     * Marks are `"Source:startedAt"`; a damaged one is dropped.
     */
    fun killedRuns(marks: Collection<String>): List<RunRecord> = marks.mapNotNull { mark ->
        val source = runCatching { RunSource.valueOf(mark.substringBefore(':')) }.getOrNull() ?: return@mapNotNull null
        val startedAt = mark.substringAfter(':', "").toLongOrNull() ?: return@mapNotNull null
        RunRecord(source, startedAt, seconds = 0.0, uploaded = 0, remaining = 0, stop = KILLED)
    }.sortedBy { it.startedAt }

    fun mark(source: RunSource, startedAt: Long): String = "${source.name}:$startedAt"

    /** Keeps the newest [limit] records. */
    fun appending(r: RunRecord, list: List<RunRecord>, limit: Int = 200): List<RunRecord> {
        val all = list + r
        return if (all.size > limit) all.takeLast(limit) else all
    }

    /**
     * When the next automatic run should start. Null stops the chain: nothing left, or a rule
     * (paused, no access, Wi-Fi, power) will bring it back on its own.
     * A `FLOOD_WAIT` that ends later than the gap wins, so the next job does not send early.
     */
    fun nextAutoRun(
        remaining: Int,
        stoppedByTime: Boolean,
        blocked: Boolean,
        floodUntil: Long,
        now: Long,
        gapMs: Long = 15 * 60_000L,
    ): Long? {
        if (remaining == 0 || blocked) return null
        // Failures still retry after the gap. The caller stops after three runs with no progress.
        return maxOf(now + gapMs, floodUntil)
    }

    /** A user run has no deadline. A background run stops taking new items once [now] reaches it. */
    fun mayTakeNextItem(deadline: Long?, now: Long): Boolean = deadline == null || now < deadline

    /**
     * The automatic upload request. Expedited work accepts only network and storage constraints;
     * battery-not-low or charging makes WorkManager's `build()` throw. A run that must wait for
     * the charger is delayed instead, so it can keep those constraints.
     */
    fun autoRunPlan(wifiOnly: Boolean, chargingOnly: Boolean, delayMs: Long): AutoRunPlan {
        val expedited = delayMs == 0L && !chargingOnly
        return AutoRunPlan(
            expedited = expedited,
            delayMs = if (expedited) 0L else delayMs,
            unmetered = wifiOnly,
            batteryNotLow = !expedited,
            requiresCharging = chargingOnly,
        )
    }

    /**
     * Phase 3's empty-run counter. A saved part counts as progress: a large video takes several
     * 9-minute runs, and counting only finished items would stop the chain halfway through it.
     */
    fun emptyRunsAfter(previous: Int, uploaded: Int, partsSaved: Int, userRun: Boolean): Int = when {
        userRun || uploaded > 0 || partsSaved > 0 -> 0
        else -> previous + 1
    }

    /** The later of two deadlines. Telegram's wait must not move earlier when a second one arrives. */
    fun laterDeadline(existing: Long, candidate: Long): Long = maxOf(existing, candidate)

    /**
     * Stuck reminder: null if nothing is waiting. Otherwise 2 days after the last upload, then 4 more,
     * then 8 (and 8 after that). Same spacing as iOS.
     */
    fun nextReminder(lastUpload: Long?, waiting: Int, remindersSent: Int, now: Long): Long? {
        if (waiting <= 0) return null
        var offset = 0
        val sent = maxOf(remindersSent, 0)
        for (i in 0..sent) offset += REMINDER_DAYS[minOf(i, REMINDER_DAYS.lastIndex)]
        return (lastUpload ?: now) + offset * DAY_MS
    }

    /**
     * 07:30 on the morning that ends the night [after] belongs to. A run at 22:00 belongs to the next morning;
     * a run at 06:00 belongs to this morning.
     */
    fun morning(after: Long, zone: ZoneId): Long {
        val zoned = Instant.ofEpochMilli(after).atZone(zone)
        val day = if (zoned.hour >= 22) zoned.plusDays(1) else zoned
        return day.withHour(7).withMinute(30).withSecond(0).withNano(0).toInstant().toEpochMilli()
    }

    /** Runs between 22:00 and 07:00 local time count as overnight. */
    fun isOvernight(epochMs: Long, zone: ZoneId): Boolean {
        val hour = Instant.ofEpochMilli(epochMs).atZone(zone).hour
        return hour >= 22 || hour < 7
    }

    /** "312 photos and 4 videos backed up overnight." Null when nothing was uploaded. Same words as iOS. */
    fun summaryText(photos: Int, videos: Int, overnight: Boolean): String? {
        val parts = buildList {
            if (photos > 0) add("$photos photo${if (photos == 1) "" else "s"}")
            if (videos > 0) add("$videos video${if (videos == 1) "" else "s"}")
        }
        if (parts.isEmpty()) return null
        return parts.joinToString(" and ") + " backed up" + if (overnight) " overnight." else "."
    }

    /**
     * First match wins. Battery and a rare standby bucket are only mentioned after photos have waited
     * a day: many phones back up fine while optimized, and those should not be nagged.
     */
    fun backgroundIssue(
        partialAccess: Boolean,
        restricted: Boolean,
        optimized: Boolean,
        bucket: Int,
        lastExitForceStop: Boolean,
        lastAutoUpload: Long?,
        waiting: Int,
        now: Long,
    ): BackgroundIssue {
        if (partialAccess) return BackgroundIssue.PartialPhotoAccess
        if (restricted) return BackgroundIssue.BackgroundRestricted
        if (lastExitForceStop) return BackgroundIssue.ForceStopped
        val waitedADay = waiting > 0 && (lastAutoUpload == null || now - lastAutoUpload > DAY_MS)
        if (waitedADay && (bucket == STANDBY_RESTRICTED || bucket == STANDBY_RARE)) return BackgroundIssue.RareBucket
        if (waitedADay && optimized) return BackgroundIssue.BatteryOptimized
        return BackgroundIssue.None
    }

    /** UsageStatsManager buckets. Kept here so the rule can be tested without Android. */
    const val STANDBY_ACTIVE = 10
    const val STANDBY_WORKING_SET = 20
    const val STANDBY_FREQUENT = 30
    const val STANDBY_RARE = 40
    const val STANDBY_RESTRICTED = 45

    fun encode(list: List<RunRecord>): String = JsonArray(list.map { r ->
        JsonObject(buildMap {
            put("source", JsonPrimitive(r.source.name))
            put("startedAt", JsonPrimitive(r.startedAt))
            put("seconds", JsonPrimitive(r.seconds))
            put("uploaded", JsonPrimitive(r.uploaded))
            put("remaining", JsonPrimitive(r.remaining))
            if (r.stop != null) put("stop", JsonPrimitive(r.stop))
        })
    }).toString()

    /** A damaged record is dropped. The log is a convenience, not the backup. */
    fun decode(text: String?): List<RunRecord> {
        if (text.isNullOrBlank()) return emptyList()
        return runCatching {
            Json.parseToJsonElement(text).jsonArray.mapNotNull { element ->
                val o = element.jsonObject
                val source = runCatching { RunSource.valueOf(o.getValue("source").jsonPrimitive.content) }.getOrNull() ?: return@mapNotNull null
                RunRecord(
                    source = source,
                    startedAt = o["startedAt"]?.jsonPrimitive?.longOrNull ?: return@mapNotNull null,
                    seconds = o["seconds"]?.jsonPrimitive?.doubleOrNull ?: o["seconds"]?.jsonPrimitive?.longOrNull?.toDouble() ?: 0.0,
                    uploaded = o["uploaded"]?.jsonPrimitive?.intOrNull ?: 0,
                    remaining = o["remaining"]?.jsonPrimitive?.intOrNull ?: 0,
                    stop = o["stop"]?.jsonPrimitive?.content,
                )
            }
        }.getOrDefault(emptyList())
    }
}
