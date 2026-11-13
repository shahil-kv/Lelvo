package app.lelvo.core.format

import app.lelvo.core.crypto.Bytes
import app.lelvo.core.crypto.CaptionBox
import app.lelvo.core.crypto.Hashing
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** The caption of a note message (§7.2, §7.3): the number of ids, and SHA-256 (hex) of the document's plaintext. */
data class NoteCaption(val n: Int, val h: String, val v: Int = 1) {
    companion object {
        fun of(document: ByteArray, idCount: Int): NoteCaption = NoteCaption(idCount, Hashing.sha256Hex(document))
    }
}

/**
 * Captions of notes and snapshots: `<PREFIX>:` + JSON in a plain library (read only), `<PREFIX>E:` + Base64 of the
 * sealed JSON in an encrypted one, with the encrypted prefix's name as authenticated data.
 */
internal class PrefixedCaption(name: String) {
    val plainPrefix = "$name:"
    val encryptedPrefix = "${name}E:"
    private val aad = "${name}E"

    fun matches(caption: String): Boolean = caption.startsWith(plainPrefix) || caption.startsWith(encryptedPrefix)

    fun seal(json: JsonObject, captionKey: ByteArray, nonce: ByteArray? = null): String {
        val bytes = JsonIO.utf8(json)
        val sealed = if (nonce != null) CaptionBox.seal(bytes, captionKey, aad, nonce) else CaptionBox.seal(bytes, captionKey, aad)
        return encryptedPrefix + Bytes.base64(sealed)
    }

    /** Null when it isn't this kind of caption, or the key doesn't open it. */
    fun open(text: String, captionKey: ByteArray?): JsonObject? = when {
        text.startsWith(plainPrefix) -> JsonIO.parseObject(text.substring(plainPrefix.length))
        text.startsWith(encryptedPrefix) && captionKey != null ->
            Bytes.base64OrNull(text.substring(encryptedPrefix.length))
                ?.let { CaptionBox.openOrNull(it, captionKey, aad) }
                ?.let(JsonIO::parseObject)
        else -> null
    }

    fun noteJson(caption: NoteCaption): JsonObject =
        JsonIO.obj("h" to JsonIO.str(caption.h), "n" to JsonIO.num(caption.n), "v" to JsonIO.num(caption.v))

    fun openNote(text: String, captionKey: ByteArray?): NoteCaption? {
        val obj = open(text, captionKey) ?: return null
        return try {
            val f = JsonFields(obj)
            NoteCaption(n = f.int("n"), h = f.string("h"), v = f.int("v")).takeIf { it.v == 1 }
        } catch (_: FieldException) {
            null
        }
    }
}

/**
 * Recently Deleted across devices (docs/CLOUD_FORMAT.md §7.2). Each delete or recover adds one small document to the
 * channel; messages are never edited, so two devices can't overwrite each other. Telegram's message ids order the
 * notes and its message dates start the 30 days, so a device's clock can't change the result.
 */
object TrashLog {
    private val captions = PrefixedCaption("CGT1")
    val PLAIN_PREFIX = captions.plainPrefix
    val ENCRYPTED_PREFIX = captions.encryptedPrefix

    enum class Op(val wire: String) {
        DELETE("del"), RECOVER("recover"),

        /** Never written. Test builds of the iPhone app did, so it's still read, and such a note is removed. */
        GONE("gone");

        companion object {
            fun of(wire: String): Op? = entries.firstOrNull { it.wire == wire }
        }
    }

    /** The document's content. */
    data class Body(val op: Op, val ids: List<String>, val v: Int = 1)

    /** A note as read from the channel. `date` is the message date Telegram gave it, in Unix seconds. */
    data class Note(val messageId: Long, val date: Long, val op: Op, val ids: List<String>)

    fun encode(body: Body): ByteArray {
        require(body.op != Op.GONE && body.v == 1)
        return JsonIO.utf8(JsonIO.obj("ids" to JsonIO.strings(body.ids), "op" to JsonIO.str(body.op.wire), "v" to JsonIO.num(body.v)))
    }

    /** Null for anything this version doesn't understand (a newer version, an unknown action): the note is ignored. */
    fun decode(data: ByteArray): Body? = try {
        JsonIO.parseObject(data)?.let(::JsonFields)?.let { f ->
            Body(op = Op.of(f.string("op")) ?: return null, ids = f.strings("ids"), v = f.int("v")).takeIf { it.v == 1 }
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

    /** Checks a downloaded (and decrypted) document against its caption. Null when anything is off: a damaged note changes nothing. */
    fun read(data: ByteArray, caption: NoteCaption): Body? {
        if (Hashing.sha256Hex(data) != caption.h) return null
        return decode(data)?.takeIf { it.ids.size == caption.n }
    }

    /** The newest note for each item: the highest message id wins, whichever device sent it. */
    fun latest(notes: List<Note>): Map<String, Note> {
        val result = HashMap<String, Note>()
        for (note in notes) {
            for (id in note.ids) if ((result[id]?.messageId ?: Long.MIN_VALUE) < note.messageId) result[id] = note
        }
        return result
    }

    sealed class Action {
        object None : Action()
        /** Into Recently Deleted from [atMs], the note's Telegram date. */
        data class Trash(val atMs: Long) : Action()
        object Recover : Action()
        /** The messages are gone: forget the item. */
        object Remove : Action()
    }

    /**
     * What the newest note means for [item] (iOS `action(for:note:messagesSeen:)`). Items still being uploaded wait:
     * the note is kept and applied once they're done. [messagesSeen]: a full scan just read this item's messages, so a
     * `gone` note can't be true (yet) and the item is only treated as deleted; when in doubt, keep data.
     */
    fun action(item: LibraryItem, note: Note, messagesSeen: Boolean): Action = when (note.op) {
        Op.DELETE -> trashAction(item, note)
        Op.RECOVER -> if (item.status == ItemStatus.Trashed) Action.Recover else Action.None
        Op.GONE -> when {
            messagesSeen -> trashAction(item, note)
            item.status == ItemStatus.BackedUp || item.status == ItemStatus.Trashed -> Action.Remove
            else -> Action.None
        }
    }

    private fun trashAction(item: LibraryItem, note: Note): Action {
        val at = note.date * 1000
        return when (item.status) {
            ItemStatus.BackedUp -> Action.Trash(at)
            ItemStatus.Trashed -> if (item.trashedAt == at) Action.None else Action.Trash(at)
            else -> if (item.isStrandedInCloud) Action.Trash(at) else Action.None
        }
    }

    /** [item] after an action other than [Action.Remove], or null when nothing changes. */
    fun apply(action: Action, item: LibraryItem): LibraryItem? = when (action) {
        // An item already in Recently Deleted takes the date all devices share.
        is Action.Trash -> item.copy(status = ItemStatus.Trashed, trashedAt = action.atMs)
        Action.Recover -> recover(item)
        Action.None, Action.Remove -> null
    }

    /** Out of Recently Deleted: backed up again when complete in the channel, otherwise failed (iOS `CloudTrash.recover`). */
    fun recover(item: LibraryItem): LibraryItem =
        if (item.status != ItemStatus.Trashed) item
        else item.copy(status = if (item.isCompleteInCloud) ItemStatus.BackedUp else ItemStatus.Failed, trashedAt = null)

    /** Items in Recently Deleted from before notes existed: they get a note once, and so a fresh 30 days. */
    fun itemsNeedingANote(trashed: List<LibraryItem>, notes: List<Note>, waiting: Set<String>): List<LibraryItem> {
        val newest = latest(notes)
        return trashed.filter { it.id !in waiting && newest[it.id]?.op != Op.DELETE && newest[it.id]?.op != Op.GONE }
    }

    /** The notes a phone must confirm are still in the channel: those that keep its items in Recently Deleted. */
    fun notesToConfirm(trashed: List<LibraryItem>, notes: List<Note>, waiting: Set<String>): Set<Long> {
        val newest = latest(notes)
        return trashed.filter { it.id !in waiting }.mapNotNull { newest[it.id]?.messageId }.toSet()
    }

    /**
     * Items in Recently Deleted that no note in the channel keeps there, because another device finished with the note
     * while this one wasn't listening. Telegram decides what they are: messages gone means deleted for good, messages
     * still there means recovered. They never get a new note: that could delete a photo the user recovered.
     */
    fun uncovered(trashed: List<LibraryItem>, notes: List<Note>, stillInChannel: Set<Long>, waiting: Set<String>): List<LibraryItem> {
        val newest = latest(notes.filter { it.messageId in stillInChannel })
        return trashed.filter { item ->
            item.id !in waiting && (newest[item.id]?.let { it.op != Op.DELETE && it.op != Op.GONE } ?: true)
        }
    }

    /**
     * Whether Telegram has none of the item's messages left. One message going isn't enough: the rest are still the
     * user's data. An item with no known messages says nothing, so it isn't gone.
     */
    fun allMessagesGone(item: LibraryItem, existing: Set<Long>): Boolean {
        val ids = item.allMessageIds
        return ids.isNotEmpty() && ids.none(existing::contains)
    }

    /**
     * Whether an expired item may really be deleted: its newest note must be a delete note, and nothing may be waiting
     * to be sent for it. Anything else keeps the photo.
     */
    fun mayPurge(item: LibraryItem, latest: Note?, waiting: Set<String>): Boolean =
        item.id !in waiting && latest != null && (latest.op == Op.DELETE || latest.op == Op.GONE)

    /**
     * Notes that have done their job, so nothing stays in the channel. A delete note is finished when each of its
     * items is deleted for good or has a newer note. A recover note is finished when no older delete note still lists
     * its items. `known`: the ids of the items in this device's index.
     */
    fun notesToRemove(notes: List<Note>, known: Set<String>): List<Note> {
        val newest = latest(notes)
        val unfinished = notes.filter { note ->
            note.op == Op.DELETE && note.ids.any { newest[it]?.messageId == note.messageId && it in known }
        }
        return notes.filter { note ->
            when (note.op) {
                Op.DELETE -> note !in unfinished
                Op.GONE -> true
                Op.RECOVER -> {
                    val ids = note.ids.toSet()
                    unfinished.none { it.messageId < note.messageId && it.ids.any(ids::contains) }
                }
            }
        }
    }

    /**
     * Pacing, in milliseconds: 5 seconds so a burst of changes shares one note, and at least 10 seconds between notes
     * however someone taps. Six notes a minute at most stays far below what Telegram allows a chat, and a `FLOOD_WAIT`
     * is still honoured exactly.
     */
    const val GROUPING_DELAY_MS = 5_000L
    const val MINIMUM_GAP_MS = 10_000L

    /** After a failed send (offline, Telegram busy), the next try waits a minute, not 10 seconds. */
    const val RETRY_AFTER_FAILURE_MS = 60_000L

    fun sendDelayMs(lastSentMs: Long?, nowMs: Long): Long =
        if (lastSentMs == null) GROUPING_DELAY_MS else maxOf(GROUPING_DELAY_MS, lastSentMs + MINIMUM_GAP_MS - nowMs)

    /** The `lastSentMs` to keep after a failed send, so `sendDelayMs` waits `RETRY_AFTER_FAILURE_MS`. */
    fun lastSentAfterFailureMs(nowMs: Long): Long = nowMs + RETRY_AFTER_FAILURE_MS - MINIMUM_GAP_MS

    /**
     * Notes go as soon as they're finished, so a device that wasn't listening can miss a delete altogether. Only
     * reading the whole channel finds that, so it does once a week.
     */
    const val FULL_SCAN_EVERY_MS = 7L * 24 * 3600 * 1000

    fun needsFullScan(lastFullScanMs: Long?, nowMs: Long): Boolean = lastFullScanMs == null || nowMs - lastFullScanMs > FULL_SCAN_EVERY_MS
}

/** A note's item ids as one JSON array, for the local index's note tables. Local cache only, not the format. */
object NoteIds {
    fun encode(ids: List<String>): String = JsonArray(ids.map { JsonPrimitive(it) }).toString()

    fun decode(text: String): List<String> =
        runCatching { (Json.parseToJsonElement(text) as JsonArray).map { (it as JsonPrimitive).content } }.getOrDefault(emptyList())
}
