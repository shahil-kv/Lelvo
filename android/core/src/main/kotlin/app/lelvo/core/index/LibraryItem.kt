package app.lelvo.core.index

import app.lelvo.core.format.FieldException
import app.lelvo.core.format.JsonFields
import app.lelvo.core.format.JsonIO
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** A stored document message. Never log [fileId] or [uniqueId]. */
data class RemoteFile(val messageId: Long, val fileId: String, val uniqueId: String, val size: Long)

/** Same values as the iOS `MediaKind`. */
enum class ItemKind(val code: String) {
    Photo("photo"), Video("video"), LivePhoto("livePhoto");

    companion object {
        fun of(code: String): ItemKind = entries.firstOrNull { it.code == code } ?: Photo
    }
}

/** Same values as the iOS `ItemStatus`. Only [BackedUp] counts as backed up. */
enum class ItemStatus(val code: String) {
    Queued("queued"), Uploading("uploading"), BackedUp("backedUp"), TooLarge("tooLarge"), Failed("failed"), Trashed("trashed");

    companion object {
        // An unknown status is never read as backed up: that could let a photo be deleted from the phone.
        fun of(code: String): ItemStatus = entries.firstOrNull { it.code == code } ?: Failed
    }
}

/** One photo or video in the local index, a cache of what the channel holds (iOS `MediaItem`). */
data class LibraryItem(
    val id: String,
    /** MediaStore id of the copy on this phone, when there is one. */
    val localId: String?,
    /** SHA-256 of the original; empty when the channel has no original for it. */
    val sha256: String,
    val filename: String,
    val kind: ItemKind,
    /** Epoch milliseconds. */
    val createdAt: Long?,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val width: Int = 0,
    val height: Int = 0,
    val duration: Double? = null,
    /** Plaintext size of the original. */
    val fileSize: Long,
    val status: ItemStatus,
    val favorite: Boolean = false,
    val hidden: Boolean = false,
    val uploadedAt: Long? = null,
    val verifiedAt: Long? = null,
    val albums: List<String> = emptyList(),
    /** Parts per caption role (`o`, `pv`, `t`, `d`, `sp`…), in part order. */
    val parts: Map<String, List<RemoteFile>> = emptyMap(),
    /** Expected part count per role, from the caption `p` field. */
    val expectedParts: Map<String, Int> = emptyMap(),
    val encrypted: Boolean = false,
    val mimeType: String? = null,
    val codec: String? = null,
    val hdr: Int? = null,
    val tzOffsetMinutes: Int? = null,
    /** The caption `l` field: the asset this was uploaded from, on the device that uploaded it. */
    val sourceLocalId: String? = null,
    /** The original declares an edited version (`ed`), or one is in the channel. */
    val hasEdit: Boolean = false,
    /** SHA-256 per role (the `h` caption field). */
    val roleHashes: Map<String, String> = emptyMap(),
    /** File names of the extra roles (`ad`, `ad2`, `ra`, `epv`, `md`). */
    val roleNames: Map<String, String> = emptyMap(),
    val pairedVideoName: String? = null,
    val pairedVideoSize: Long? = null,
    val editedName: String? = null,
    val editedSize: Long? = null,
    val lastError: String? = null,
) {
    /** Roles that must be in the cloud, as iOS `requiredCaptionRoles`: the thumbnail for encrypted items, the edit when declared. */
    val requiredRoles: List<String>
        get() = buildList {
            add("o")
            if (kind == ItemKind.LivePhoto) add("pv")
            if (encrypted) add("t")
            if (hasEdit) add("e")
        }

    /** Every required role present with all of its parts (iOS `isCompleteInCloud`). */
    val isCompleteInCloud: Boolean
        get() = requiredRoles.all { role ->
            val have = parts[role]?.size ?: 0
            have > 0 && have == (expectedParts[role] ?: 1)
        }

    val allMessageIds: List<Long> get() = parts.values.flatten().map { it.messageId }.distinct().sorted()

    /** Bytes stored in Telegram for this item. */
    val cloudBytes: Long get() = parts.values.flatten().sumOf { it.size }
}

/** Everything of an item that isn't its own column, as one JSON column in the index. Local cache only, not the format. */
object ItemExtras {
    data class Extras(
        val albums: List<String> = emptyList(),
        val parts: Map<String, List<RemoteFile>> = emptyMap(),
        val expectedParts: Map<String, Int> = emptyMap(),
        val encrypted: Boolean = false,
        val mimeType: String? = null,
        val codec: String? = null,
        val hdr: Int? = null,
        val tzOffsetMinutes: Int? = null,
        val sourceLocalId: String? = null,
        val hasEdit: Boolean = false,
        val roleHashes: Map<String, String> = emptyMap(),
        val roleNames: Map<String, String> = emptyMap(),
        val pairedVideoName: String? = null,
        val pairedVideoSize: Long? = null,
        val editedName: String? = null,
        val editedSize: Long? = null,
        val lastError: String? = null,
    )

    private fun strings(map: Map<String, String>): JsonElement? = map.takeIf { it.isNotEmpty() }?.let { m -> JsonObject(m.mapValues { JsonIO.str(it.value)!! }) }

    fun encode(item: LibraryItem): String = JsonIO.obj(
        "a" to JsonIO.strings(item.albums.takeIf { it.isNotEmpty() }),
        "c" to JsonIO.str(item.codec),
        "e" to JsonObject(item.expectedParts.mapValues { JsonIO.num(it.value)!! }),
        "ed" to JsonIO.num(if (item.hasEdit) 1 else null),
        "en" to JsonIO.str(item.editedName),
        "enc" to JsonIO.num(if (item.encrypted) 1 else null),
        "err" to JsonIO.str(item.lastError),
        "es" to JsonIO.num(item.editedSize),
        "hdr" to JsonIO.num(item.hdr),
        "l" to JsonIO.str(item.sourceLocalId),
        "m" to JsonIO.str(item.mimeType),
        "p" to JsonObject(
            item.parts.mapValues { (_, files) ->
                JsonArray(files.map { JsonIO.obj("f" to JsonIO.str(it.fileId), "m" to JsonIO.num(it.messageId), "s" to JsonIO.num(it.size), "u" to JsonIO.str(it.uniqueId)) })
            },
        ),
        "pn" to JsonIO.str(item.pairedVideoName),
        "ps" to JsonIO.num(item.pairedVideoSize),
        "rh" to strings(item.roleHashes),
        "rn" to strings(item.roleNames),
        "tz" to JsonIO.num(item.tzOffsetMinutes),
    ).toString()

    /** A row that can't be read gives no parts: the item then looks incomplete and a scan fills it in again. */
    fun decode(text: String): Extras = try {
        val f = JsonFields(JsonIO.parseObject(text) ?: throw FieldException("extras"))
        val parts = (f.objOrNull("p") ?: JsonObject(emptyMap())).mapValues { (role, files) ->
            (files as? JsonArray ?: throw FieldException(role)).map {
                val r = JsonFields(it as? JsonObject ?: throw FieldException(role))
                RemoteFile(messageId = r.long("m"), fileId = r.string("f"), uniqueId = r.string("u"), size = r.long("s"))
            }
        }
        fun ints(key: String) = f.objOrNull(key)?.let { o -> JsonFields(o).let { of -> o.keys.associateWith { of.int(it) } } } ?: emptyMap()
        fun texts(key: String) = f.objOrNull(key)?.let { o -> JsonFields(o).let { of -> o.keys.associateWith { of.string(it) } } } ?: emptyMap()
        Extras(
            albums = f.stringsOrNull("a") ?: emptyList(), parts = parts, expectedParts = ints("e"),
            encrypted = f.intOrNull("enc") == 1, mimeType = f.stringOrNull("m"), codec = f.stringOrNull("c"), hdr = f.intOrNull("hdr"),
            tzOffsetMinutes = f.intOrNull("tz"), sourceLocalId = f.stringOrNull("l"), hasEdit = f.intOrNull("ed") == 1,
            roleHashes = texts("rh"), roleNames = texts("rn"), pairedVideoName = f.stringOrNull("pn"), pairedVideoSize = f.longOrNull("ps"),
            editedName = f.stringOrNull("en"), editedSize = f.longOrNull("es"), lastError = f.stringOrNull("err"),
        )
    } catch (_: FieldException) {
        Extras()
    }

    /** [item] with the fields that live in the extras column taken from [e]. */
    fun apply(item: LibraryItem, e: Extras): LibraryItem = item.copy(
        albums = e.albums, parts = e.parts, expectedParts = e.expectedParts, encrypted = e.encrypted, mimeType = e.mimeType,
        codec = e.codec, hdr = e.hdr, tzOffsetMinutes = e.tzOffsetMinutes, sourceLocalId = e.sourceLocalId, hasEdit = e.hasEdit,
        roleHashes = e.roleHashes, roleNames = e.roleNames, pairedVideoName = e.pairedVideoName, pairedVideoSize = e.pairedVideoSize,
        editedName = e.editedName, editedSize = e.editedSize, lastError = e.lastError,
    )
}
