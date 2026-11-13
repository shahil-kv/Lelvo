package app.lelvo.core.format

import app.lelvo.core.crypto.Hashing
import kotlinx.serialization.json.JsonArray
import java.io.ByteArrayOutputStream
import java.util.zip.DataFormatException
import java.util.zip.Deflater
import java.util.zip.Inflater

/** One Lelvo document message read from the channel. */
data class CloudMessage(
    val messageId: Long,
    val meta: CaptionMeta,
    /** TDLib persistent remote file id and unique id. Never log them. */
    val fileId: String,
    val uniqueId: String,
    /** Size of the stored document (part size for split files). */
    val size: Long,
)

/**
 * A snapshot of the library index (docs/CLOUD_FORMAT.md §7.1): every Lelvo message up to `upto`, as a scan would read
 * it, in one document. A new device reads the channel from the newest message back to the first snapshot and takes the
 * rest from it. The channel stays the truth: a full scan afterwards corrects anything deleted since the snapshot.
 */
object IndexSnapshot {
    private val captions = PrefixedCaption("CGX1")
    val PLAIN_PREFIX = captions.plainPrefix
    val ENCRYPTED_PREFIX = captions.encryptedPrefix

    /** A snapshot bigger than this once inflated is refused: the size comes from the channel, the memory is the phone's. */
    const val MAXIMUM_INFLATED_BYTES = 256 shl 20

    data class Body(val upto: Long, val messages: List<CloudMessage>, val v: Int = 1)

    /** The snapshot message's caption: the number of records, and SHA-256 (hex) of the document's plaintext. */
    data class Caption(val upto: Long, val n: Int, val h: String, val v: Int = 1)

    /** The snapshot of `messages` (every message the index knows), up to `upto`. */
    fun body(messages: List<CloudMessage>, upto: Long): Body =
        Body(upto, messages.filter { it.messageId <= upto }.sortedBy { it.messageId })

    /** Compact JSON, compressed with raw DEFLATE (RFC 1951). In a library, CGFE-encrypt it before uploading. */
    fun encode(body: Body): ByteArray {
        val records = body.messages.map {
            JsonIO.obj(
                "c" to CaptionCodec.toJson(it.meta), "f" to JsonIO.str(it.fileId), "m" to JsonIO.num(it.messageId),
                "s" to JsonIO.num(it.size), "u" to JsonIO.str(it.uniqueId),
            )
        }
        val json = JsonIO.utf8(JsonIO.obj("messages" to JsonArray(records), "upto" to JsonIO.num(body.upto), "v" to JsonIO.num(body.v)))
        val deflater = Deflater(Deflater.DEFAULT_COMPRESSION, true)
        try {
            deflater.setInput(json)
            deflater.finish()
            val out = ByteArrayOutputStream(json.size / 4 + 64)
            val buffer = ByteArray(64 shl 10)
            while (!deflater.finished()) out.write(buffer, 0, deflater.deflate(buffer))
            return out.toByteArray()
        } finally {
            deflater.end()
        }
    }

    /** Null when the document isn't a snapshot this version reads; the reader scans the whole channel instead. */
    fun decode(data: ByteArray): Body? {
        val json = inflate(data) ?: return null
        return try {
            val f = JsonFields(JsonIO.parseObject(json) ?: return null)
            if (f.int("v") != 1) return null
            // One unreadable record refuses the whole snapshot: its count and checksum were made for all of them.
            val messages = f.objects("messages").map { record ->
                val r = JsonFields(record)
                CloudMessage(messageId = r.long("m"), meta = CaptionCodec.fromJson(r.obj("c")), fileId = r.string("f"), uniqueId = r.string("u"), size = r.long("s"))
            }
            Body(upto = f.long("upto"), messages = messages)
        } catch (_: FieldException) {
            null
        }
    }

    private fun inflate(data: ByteArray): ByteArray? {
        val inflater = Inflater(true)
        try {
            // Raw DEFLATE: older zlib wants one byte after the end of the stream.
            inflater.setInput(data + 0)
            val out = ByteArrayOutputStream(data.size * 4 + 64)
            val buffer = ByteArray(64 shl 10)
            while (!inflater.finished()) {
                val n = inflater.inflate(buffer)
                if (n == 0 && (inflater.needsInput() || inflater.needsDictionary())) return null
                out.write(buffer, 0, n)
                if (out.size() > MAXIMUM_INFLATED_BYTES) return null
            }
            return out.toByteArray()
        } catch (_: DataFormatException) {
            return null
        } finally {
            inflater.end()
        }
    }

    private fun json(caption: Caption) =
        JsonIO.obj("h" to JsonIO.str(caption.h), "n" to JsonIO.num(caption.n), "upto" to JsonIO.num(caption.upto), "v" to JsonIO.num(caption.v))

    fun caption(caption: Caption, captionKey: ByteArray): String = captions.seal(json(caption), captionKey)

    /** The caption for an encoded (not yet encrypted) snapshot document. */
    fun captionFor(document: ByteArray, body: Body): Caption = Caption(body.upto, body.messages.size, Hashing.sha256Hex(document))

    fun isSnapshot(caption: String): Boolean = captions.matches(caption)

    /** Null when it isn't a snapshot caption this version reads (or the key doesn't open it). */
    fun parseCaption(text: String, captionKey: ByteArray?): Caption? {
        val obj = captions.open(text, captionKey) ?: return null
        return try {
            val f = JsonFields(obj)
            Caption(upto = f.long("upto"), n = f.int("n"), h = f.string("h"), v = f.int("v")).takeIf { it.v == 1 }
        } catch (_: FieldException) {
            null
        }
    }

    /** Checks a downloaded (and decrypted) snapshot against its caption. Null when anything is off. */
    fun read(data: ByteArray, caption: Caption): Body? {
        if (Hashing.sha256Hex(data) != caption.h) return null
        return decode(data)?.takeIf { it.upto == caption.upto && it.messages.size == caption.n }
    }
}
