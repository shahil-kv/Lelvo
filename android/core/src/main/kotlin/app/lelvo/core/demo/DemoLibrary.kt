package app.lelvo.core.demo

import app.lelvo.core.format.FieldException
import app.lelvo.core.format.JsonFields
import app.lelvo.core.format.JsonIO
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.index.RemoteFile
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * The sample library for the review demo, read from the same `iOS/DemoLibrary/manifest.json` the iPhone app bundles
 * (Shared/App/DemoMode.swift). Items, ids, hashes and dates come out the same as on the iPhone.
 */
object DemoLibrary {
    const val ID_PREFIX = "demo-"

    data class Entry(
        val file: String, val name: String, val kind: String, val daysAgo: Int, val minutes: Int, val w: Int, val h: Int,
        val size: Long, val duration: Double?, val pending: Boolean, val lat: Double?, val lon: Double?,
        val albums: List<String>, val favorite: Boolean,
    )

    /** An unreadable manifest gives an empty demo rather than a crash. */
    fun entries(manifestJson: String): List<Entry> = try {
        val root = JsonFields(JsonIO.parseObject(manifestJson) ?: return emptyList())
        root.objects("items").map {
            val f = JsonFields(it)
            Entry(
                file = f.string("file"), name = f.string("name"), kind = f.string("kind"), daysAgo = f.int("daysAgo"),
                minutes = f.int("minutes"), w = f.int("w"), h = f.int("h"), size = f.long("size"),
                duration = f.doubleOrNull("duration"), pending = f.boolOrNull("pending") ?: false,
                lat = f.doubleOrNull("lat"), lon = f.doubleOrNull("lon"), albums = f.stringsOrNull("albums") ?: emptyList(),
                favorite = f.boolOrNull("favorite") ?: false,
            )
        }
    } catch (_: FieldException) {
        emptyList()
    }

    /** Dates count back from today, so the demo always looks like a recent library. */
    fun item(e: Entry, today: LocalDate, zone: ZoneId, now: Instant): LibraryItem {
        val start = today.atStartOfDay(zone).toInstant()
        // Seconds, not calendar days, like the iPhone (`addingTimeInterval`).
        val date = start.plusSeconds(-e.daysAgo * 86_400L + (9 * 60 + e.minutes) * 60L).coerceAtMost(now).toEpochMilli()
        val hash = stableHash(e.file)
        val kind = if (e.kind == "video") ItemKind.Video else ItemKind.Photo
        val parts = buildMap {
            put("o", listOf(RemoteFile(java.lang.Long.remainderUnsigned(hash, 1_000_000), "demo", ID_PREFIX + e.file, e.size)))
            // Videos show the quality switch (original / fast version); the same clip plays for both.
            if (kind == ItemKind.Video) {
                put("sp", listOf(RemoteFile(java.lang.Long.remainderUnsigned(stableHash(e.file + "sp"), 1_000_000), "demo", ID_PREFIX + e.file + ".sp", e.size)))
            }
        }
        return LibraryItem(
            id = ID_PREFIX + e.file, localId = null, sha256 = "0".repeat(48) + "%016x".format(hash), filename = e.name, kind = kind,
            createdAt = date, latitude = e.lat, longitude = e.lon, width = e.w, height = e.h, duration = e.duration,
            fileSize = e.size, status = ItemStatus.BackedUp, favorite = e.favorite, uploadedAt = date, verifiedAt = date,
            albums = e.albums, parts = parts, expectedParts = parts.mapValues { 1 },
        )
    }

    /** The bundled file for a demo item; null for every real item. */
    fun assetName(item: LibraryItem): String? = item.id.takeIf { it.startsWith(ID_PREFIX) }?.removePrefix(ID_PREFIX)

    /** FNV-1a 64: the same number on every launch and on both platforms. */
    fun stableHash(s: String): Long {
        var h = -0x340d631b7bdddcdbL // 14695981039346656037
        for (b in s.toByteArray(Charsets.UTF_8)) h = (h xor (b.toLong() and 0xff)) * 0x100000001b3L
        return h
    }
}
