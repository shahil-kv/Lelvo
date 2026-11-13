package app.lelvo.core.format

import app.lelvo.core.crypto.Hashing
import app.lelvo.core.crypto.nfc

/**
 * Favorites and albums across devices (docs/CLOUD_FORMAT.md §7.3). A change made after an item was backed up adds one
 * small document to the channel, for many items at once. For each item, its favorite and its membership of each album
 * follow the note with the highest message id.
 */
object MetaLog {
    private val captions = PrefixedCaption("CGM1")
    val PLAIN_PREFIX = captions.plainPrefix
    val ENCRYPTED_PREFIX = captions.encryptedPrefix

    enum class Op(val wire: String) {
        FAVORITE("fav"), UNFAVORITE("unfav"), ALBUM_ADD("album-add"), ALBUM_REMOVE("album-remove");

        val isAlbum: Boolean get() = this == ALBUM_ADD || this == ALBUM_REMOVE

        /** What the note sets its key to. */
        val value: Boolean get() = this == FAVORITE || this == ALBUM_ADD

        companion object {
            fun of(wire: String): Op? = entries.firstOrNull { it.wire == wire }
        }
    }

    /** What a note sets: the favorite, or membership of one album (by name). */
    sealed class Key {
        object Favorite : Key()
        data class Album(val name: String) : Key()

        /** For the index's outbox. */
        val stored: String
            get() = when (this) {
                Favorite -> "fav"
                is Album -> "a:$name"
            }

        companion object {
            fun ofStored(stored: String): Key? = when {
                stored == "fav" -> Favorite
                stored.startsWith("a:") && stored.length > 2 -> Album(stored.substring(2))
                else -> null
            }
        }
    }

    /** The document's content. `album` only with the album ops. */
    data class Body(val op: Op, val ids: List<String>, val album: String? = null, val v: Int = 1) {
        /** What the note sets, null when it's malformed. */
        val key: Key? get() = keyOf(op, album)
    }

    /** A note as read from the channel. `date` is Telegram's message date, in Unix seconds. */
    data class Note(val messageId: Long, val date: Long, val op: Op, val ids: List<String>, val album: String? = null) {
        val key: Key? get() = keyOf(op, album)
    }

    private fun keyOf(op: Op, album: String?): Key? =
        if (op.isAlbum) album?.let(::albumName)?.let { Key.Album(it) } else if (album == null) Key.Favorite else null

    /**
     * Album names as Photos keeps them: surrounding spaces don't make a different album. Empty is no album. In NFC,
     * because the iPhone compares names by what they look like and Kotlin compares code units: "é" typed on two
     * keyboards must stay one album.
     */
    fun albumName(raw: String): String? = raw.trim { it.isWhitespace() || it == '\u0085' }.nfc().ifEmpty { null }

    fun encode(body: Body): ByteArray {
        require(body.key != null && body.v == 1 && body.ids.size <= MAX_IDS_PER_NOTE)
        return JsonIO.utf8(
            JsonIO.obj("album" to JsonIO.str(body.album), "ids" to JsonIO.strings(body.ids), "op" to JsonIO.str(body.op.wire), "v" to JsonIO.num(body.v)),
        )
    }

    /**
     * Null for anything this version doesn't understand (a newer version, an unknown action, an album op without an
     * album, an album on a favorite op): such a note is ignored, which changes nothing.
     */
    fun decode(data: ByteArray): Body? = try {
        JsonIO.parseObject(data)?.let(::JsonFields)?.let { f ->
            Body(op = Op.of(f.string("op")) ?: return null, ids = f.strings("ids"), album = f.stringOrNull("album"), v = f.int("v"))
                .takeIf { it.v == 1 && it.key != null }
        }
    } catch (_: FieldException) {
        null
    }

    fun caption(caption: NoteCaption, captionKey: ByteArray): String = captions.seal(captions.noteJson(caption), captionKey)

    internal fun caption(caption: NoteCaption, captionKey: ByteArray, nonce: ByteArray): String =
        captions.seal(captions.noteJson(caption), captionKey, nonce)

    internal fun captionJson(caption: NoteCaption): String = captions.noteJson(caption).toString()

    fun isNote(caption: String): Boolean = captions.matches(caption)

    /** Null when it isn't a note caption this version reads (or the key doesn't open it). */
    fun parseCaption(text: String, captionKey: ByteArray?): NoteCaption? = captions.openNote(text, captionKey)

    /** Checks a downloaded (and decrypted) document against its caption. Null when anything is off. */
    fun read(data: ByteArray, caption: NoteCaption): Body? {
        if (Hashing.sha256Hex(data) != caption.h) return null
        return decode(data)?.takeIf { it.ids.size == caption.n }
    }

    // Which note wins

    data class Decided(val value: Boolean, val messageId: Long)

    /** For each item and key, the value of the note with the highest message id, and that id. */
    fun latest(notes: List<Note>): Map<String, Map<Key, Decided>> {
        val result = HashMap<String, MutableMap<Key, Decided>>()
        for (note in notes) {
            val key = note.key ?: continue
            for (id in note.ids) {
                if ((result[id]?.get(key)?.messageId ?: Long.MIN_VALUE) < note.messageId) {
                    result.getOrPut(id) { HashMap() }[key] = Decided(note.op.value, note.messageId)
                }
            }
        }
        return result
    }

    /** What the notes say about one item, with changes this device hasn't sent yet on top: they're newer than any note. */
    fun values(id: String, latest: Map<String, Map<Key, Decided>>, waiting: Map<Key, Boolean>?): Map<Key, Boolean> {
        val values = HashMap<Key, Boolean>()
        latest[id]?.forEach { (key, decided) -> values[key] = decided.value }
        waiting?.let(values::putAll)
        return values
    }

    data class Applied(val favorite: Boolean?, val albums: List<String>?, val changed: Boolean)

    /**
     * An item's favorite and albums after `values`. Albums not named keep what the backup recorded (`albums` is the
     * caption's list, or the `md` resource's when the item has one).
     */
    fun apply(values: Map<Key, Boolean>, favorite: Boolean?, albums: List<String>?): Applied {
        var changed = false
        var fav = favorite
        val list = (albums ?: emptyList()).toMutableList()
        for ((key, value) in values.entries.sortedBy { it.key.stored }) {
            when (key) {
                Key.Favorite -> if (fav != value) {
                    fav = value
                    changed = true
                }
                is Key.Album -> {
                    val present = list.any { albumName(it) == key.name }
                    if (value && !present) {
                        list.add(key.name)
                        changed = true
                    }
                    if (!value && present) {
                        list.removeAll { albumName(it) == key.name }
                        changed = true
                    }
                }
            }
        }
        return if (changed) Applied(fav, list.ifEmpty { null }, true) else Applied(favorite, albums, false)
    }

    // Sending

    /** The most ids one note carries, so its document and caption stay small. A bigger change goes as several notes. */
    const val MAX_IDS_PER_NOTE = 2000

    /**
     * Turns waiting changes (item → key → value) into notes: one per action and album, ids sorted. Many photos
     * favorited in a minute share one note.
     */
    fun bodies(changes: Map<String, Map<Key, Boolean>>): List<Body> {
        val grouped = HashMap<Pair<Key, Boolean>, MutableList<String>>()
        for ((id, keys) in changes) {
            for ((key, value) in keys) grouped.getOrPut(key to value) { ArrayList() }.add(id)
        }
        val bodies = ArrayList<Body>()
        for ((group, ids) in grouped) {
            val (key, value) = group
            for (chunk in ids.sorted().chunked(MAX_IDS_PER_NOTE)) {
                bodies.add(
                    when (key) {
                        Key.Favorite -> Body(if (value) Op.FAVORITE else Op.UNFAVORITE, chunk)
                        is Key.Album -> Body(if (value) Op.ALBUM_ADD else Op.ALBUM_REMOVE, chunk, key.name)
                    },
                )
            }
        }
        return bodies.sortedWith(compareBy<Body>({ it.album ?: "" }, { it.op.wire }, { it.ids.firstOrNull() ?: "" }))
    }

    // Cleaning up

    /**
     * An item missing from the index this long after its note (seconds) was deleted for good (Recently Deleted keeps
     * items 30 days), so the note no longer decides anything for it.
     */
    const val GONE_AFTER_SECONDS = 31L * 24 * 3600

    /**
     * Notes that no longer decide anything, so deleting them changes nothing: every item they list has a newer note
     * for the same key, or is gone from the library (`known` is every item id in the index, right after the channel
     * was read) and the note is older than `GONE_AFTER_SECONDS`. A note that still decides one item stays, whole. A
     * newer note about an unknown item stays: that item may be uploading on another device.
     */
    fun notesToRemove(notes: List<Note>, known: Set<String>?, nowEpochSeconds: Long): List<Note> {
        val newest = latest(notes)
        return notes.filter { note ->
            val key = note.key ?: return@filter true
            val old = nowEpochSeconds - note.date > GONE_AFTER_SECONDS
            note.ids.all { id ->
                when {
                    (newest[id]?.get(key)?.messageId ?: Long.MIN_VALUE) > note.messageId -> true
                    known == null || !old -> false
                    else -> id !in known
                }
            }
        }
    }

    /** With this many notes left, a device writes the current state as fresh notes and removes the old ones. */
    const val COMPACT_ABOVE = 200

    /**
     * The current state as notes to send before removing `notes`: every item and key the notes still decide, for the
     * items still in the library (`known`), so items deleted for good don't live on in fresh notes.
     */
    fun compacted(notes: List<Note>, known: Set<String>?): List<Body> {
        val state = latest(notes)
            .filterKeys { known == null || it in known }
            .mapValues { (_, keys) -> keys.mapValues { it.value.value } }
        return bodies(state)
    }
}
