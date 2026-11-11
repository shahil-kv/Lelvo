package app.lelvo.core.format

import app.lelvo.core.LelvoFormat
import app.lelvo.core.crypto.Bytes
import app.lelvo.core.crypto.CaptionBox
import kotlinx.serialization.json.JsonObject

/** Resource roles (docs/CLOUD_FORMAT.md §2). A message with a role not listed here is skipped, never guessed at. */
enum class Role(val wire: String) {
    ORIGINAL("o"), PAIRED_VIDEO("pv"), THUMBNAIL("t"), SMOOTH_PREVIEW("sp"), EDITED("e"),

    /** Screen copy of a big photo. */
    SCREEN_COPY("d"),

    /** The edit's adjustment data as Photos keeps it, and its secondary data. */
    ADJUSTMENT("ad"), ADJUSTMENT_SECONDARY("ad2"),

    /** The RAW of a RAW + JPEG pair; the edited video of an edited Live Photo; metadata that doesn't fit the caption. */
    RAW_ALTERNATE("ra"), EDITED_PAIRED_VIDEO("epv"), METADATA("md");

    /** Roles that only accompany an original; on their own they are leftovers of a delete by an older reader (§7). */
    val isOptionalOnly: Boolean get() = this != ORIGINAL && this != PAIRED_VIDEO && this != EDITED

    companion object {
        fun of(wire: String): Role? = entries.firstOrNull { it.wire == wire }
    }
}

enum class Kind(val wire: String) {
    PHOTO("p"), VIDEO("v"), LIVE("l");

    /** What an item of this kind needs to be complete. */
    val requiredRoles: Set<Role> get() = if (this == LIVE) setOf(Role.ORIGINAL, Role.PAIRED_VIDEO) else setOf(Role.ORIGINAL)

    companion object {
        fun of(wire: String): Kind? = entries.firstOrNull { it.wire == wire }
    }
}

/** Caption metadata (docs/CLOUD_FORMAT.md §3.1). Property names are the wire keys. */
data class CaptionMeta(
    val id: String,
    val r: Role,
    val k: Kind,
    val h: String,
    val n: String,
    val s: Long,
    val v: Int = LelvoFormat.CAPTION_VERSION,
    val m: String? = null,
    val t: Long? = null,
    val tz: Int? = null,
    val g: List<Double>? = null,
    val wh: List<Int>? = null,
    val d: Double? = null,
    val c: String? = null,
    val hdr: Int? = null,
    val a: List<String>? = null,
    val fav: Int? = null,
    val p: List<Long>? = null,
    val e: Int? = null,
    val src: String? = null,
    /** Local id of the source asset on the uploading device. */
    val l: String? = null,
    /** On the original: 1 when the item also has an edited version (role `e`), so a restore can tell it's missing. */
    val ed: Int? = null,
    /** 1 when the item was hidden in Photos: not shown in the timeline, restored hidden. */
    val hid: Int? = null,
) {
    data class Part(val index: Int, val count: Int, val size: Long)

    /** Split info, if this message is one part of a split resource. */
    val part: Part?
        get() {
            val p = p ?: return null
            if (p.size != 3 || p[0] !in 0..Int.MAX_VALUE || p[1] !in 0..Int.MAX_VALUE) return null
            return Part(p[0].toInt(), p[1].toInt(), p[2])
        }

    val isEncrypted: Boolean get() = e == 1
    val latitude: Double? get() = g?.takeIf { it.size >= 2 }?.get(0)
    val longitude: Double? get() = g?.takeIf { it.size >= 2 }?.get(1)

    companion object {
        /** Latitude and longitude to 6 decimal places, altitude to 0.1 m. */
        fun roundedGps(latitude: Double, longitude: Double, altitude: Double? = null): List<Double> {
            fun r6(x: Double) = Math.round(x * 1_000_000) / 1_000_000.0
            val out = mutableListOf(r6(latitude), r6(longitude))
            if (altitude != null) out.add(Math.round(altitude * 10) / 10.0)
            return out
        }
    }
}

sealed class CaptionException(message: String) : Exception(message) {
    /** Not a Lelvo item caption: another message in the channel, a note or a snapshot. */
    class NotLelvo : CaptionException("Not a Lelvo caption")

    /** Also a role or kind this version doesn't know, and an encrypted caption the key doesn't open. */
    class Malformed : CaptionException("Unreadable caption")
    class UnsupportedVersion(val version: Int) : CaptionException("Caption version $version")
    class EncryptedNeedsKey : CaptionException("Encrypted caption without a key")

    /** Writing only: the metadata doesn't fit in 1000 characters even after everything optional went. */
    class TooLong : CaptionException("Caption too long")
}

/** Encodes and decodes captions: `CG1:{json}` (plain, read only) or `CG1E:base64(nonce|ct|tag)` (E2E). */
object CaptionCodec {
    const val PLAIN_PREFIX = "CG1:"
    const val ENCRYPTED_PREFIX = "CG1E:"
    const val MAX_LENGTH = 1000
    private const val AAD = "CG1E"
    private val UUID = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    /** The caption's JSON: compact, keys sorted, strings in NFC. */
    fun json(meta: CaptionMeta): String = toJson(meta).toString()

    internal fun toJson(meta: CaptionMeta): JsonObject = JsonIO.obj(
        "v" to JsonIO.num(meta.v), "id" to JsonIO.str(meta.id), "r" to JsonIO.str(meta.r.wire), "k" to JsonIO.str(meta.k.wire),
        "h" to JsonIO.str(meta.h), "n" to JsonIO.str(meta.n), "m" to JsonIO.str(meta.m), "s" to JsonIO.num(meta.s),
        "t" to JsonIO.num(meta.t), "tz" to JsonIO.num(meta.tz), "g" to JsonIO.doubles(meta.g), "wh" to JsonIO.ints(meta.wh),
        "d" to JsonIO.num(meta.d), "c" to JsonIO.str(meta.c), "hdr" to JsonIO.num(meta.hdr), "a" to JsonIO.strings(meta.a),
        "fav" to JsonIO.num(meta.fav), "p" to JsonIO.longs(meta.p), "e" to JsonIO.num(meta.e), "src" to JsonIO.str(meta.src),
        "l" to JsonIO.str(meta.l), "ed" to JsonIO.num(meta.ed), "hid" to JsonIO.num(meta.hid),
    )

    /**
     * Whether the caption keeps all of `meta.a` (the album names). When it doesn't, the writer stores them in an `md`
     * resource (`ExtraMetadata`) instead of letting `encode` drop them.
     */
    fun keepsAlbums(meta: CaptionMeta, captionKey: ByteArray): Boolean =
        meta.a == null || render(meta, captionKey, null).length <= MAX_LENGTH

    /**
     * Builds the caption of a resource in an encrypted library, dropping optional fields until it fits in
     * `MAX_LENGTH` characters (§3.1): albums, codec, local id, then the file name is cut keeping its extension.
     * There is no plain form: Android never writes a plain resource.
     */
    fun encode(meta: CaptionMeta, captionKey: ByteArray): String = encode(meta, captionKey, null)

    internal fun encode(meta: CaptionMeta, captionKey: ByteArray, nonce: ByteArray?): String {
        require(meta.e == 1) { "Every file of an encrypted library is CGFE: e must be 1" }
        require(meta.v == LelvoFormat.CAPTION_VERSION)
        var m = meta.copy(id = meta.id.lowercase())
        for (step in 0..4) {
            val caption = render(m, captionKey, nonce)
            if (caption.length <= MAX_LENGTH) return caption
            m = when (step) {
                0 -> m.copy(a = null)
                1 -> m.copy(c = null)
                2 -> m.copy(l = null)
                3 -> m.copy(n = truncatedName(m.n, caption.length - MAX_LENGTH + 8))
                // Telegram refuses a longer caption, and the upload with it; say so here instead.
                else -> throw CaptionException.TooLong()
            }
        }
        throw CaptionException.TooLong()
    }

    private fun render(meta: CaptionMeta, captionKey: ByteArray, nonce: ByteArray?): String {
        val json = JsonIO.utf8(toJson(meta))
        val sealed = if (nonce != null) CaptionBox.seal(json, captionKey, AAD, nonce) else CaptionBox.seal(json, captionKey, AAD)
        return ENCRYPTED_PREFIX + Bytes.base64(sealed)
    }

    internal fun truncatedName(name: String, excess: Int): String {
        val dot = name.lastIndexOf('.')
        val hasExtension = dot > 0 && dot < name.length - 1
        val base = if (hasExtension) name.substring(0, dot) else name
        val length = base.codePointCount(0, base.length)
        val keep = maxOf(8, length - maxOf(0, excess))
        // Whole code points: half an emoji is not a valid file name.
        val cut = if (keep >= length) base else base.substring(0, base.offsetByCodePoints(0, keep))
        return if (hasExtension) cut + name.substring(dot) else cut
    }

    fun isLelvo(caption: String): Boolean = caption.startsWith(PLAIN_PREFIX) || caption.startsWith(ENCRYPTED_PREFIX)

    /** Reads a caption of any library, plain or encrypted. Throws [CaptionException]; the caller skips the message. */
    fun decode(caption: String, captionKey: ByteArray? = null): CaptionMeta {
        val obj = when {
            caption.startsWith(PLAIN_PREFIX) -> JsonIO.parseObject(caption.substring(PLAIN_PREFIX.length))
            caption.startsWith(ENCRYPTED_PREFIX) -> {
                val key = captionKey ?: throw CaptionException.EncryptedNeedsKey()
                val blob = Bytes.base64OrNull(caption.substring(ENCRYPTED_PREFIX.length)) ?: throw CaptionException.Malformed()
                JsonIO.parseObject(CaptionBox.openOrNull(blob, key, AAD) ?: throw CaptionException.Malformed())
            }
            else -> throw CaptionException.NotLelvo()
        } ?: throw CaptionException.Malformed()
        val meta = try {
            fromJson(obj)
        } catch (_: FieldException) {
            throw CaptionException.Malformed()
        }
        if (meta.v != LelvoFormat.CAPTION_VERSION) throw CaptionException.UnsupportedVersion(meta.v)
        if (!UUID.matches(meta.id) || meta.h.codePointCount(0, meta.h.length) != 64) throw CaptionException.Malformed()
        return meta
    }

    /** Types only, as a snapshot record needs it; `decode` adds the checks on version, id and hash. */
    internal fun fromJson(obj: JsonObject): CaptionMeta {
        val f = JsonFields(obj)
        return CaptionMeta(
            v = f.int("v"),
            id = f.string("id"),
            r = Role.of(f.string("r")) ?: throw FieldException("r"),
            k = Kind.of(f.string("k")) ?: throw FieldException("k"),
            h = f.string("h"),
            n = f.string("n"),
            s = f.long("s"),
            m = f.stringOrNull("m"),
            t = f.longOrNull("t"),
            tz = f.intOrNull("tz"),
            g = f.doublesOrNull("g"),
            wh = f.intsOrNull("wh"),
            d = f.doubleOrNull("d"),
            c = f.stringOrNull("c"),
            hdr = f.intOrNull("hdr"),
            a = f.stringsOrNull("a"),
            fav = f.intOrNull("fav"),
            p = f.longsOrNull("p"),
            e = f.intOrNull("e"),
            src = f.stringOrNull("src"),
            l = f.stringOrNull("l"),
            ed = f.intOrNull("ed"),
            hid = f.intOrNull("hid"),
        )
    }
}

/** File names on Telegram in an encrypted library (§3): nothing about the photo, only the item id and role. */
object CloudFileNames {
    /** `part` is the 0-based part index of a split resource, null for a whole one. */
    fun encrypted(id: String, role: Role, part: Int? = null): String {
        // Not String.format: with the phone set to Arabic or Persian it writes other digits.
        val suffix = if (part != null) ".p" + (part + 1).toString().padStart(3, '0') else ""
        return "$id.${role.wire}$suffix.cge"
    }
}

/**
 * The `md` resource (§2): metadata that doesn't fit the caption, as compact JSON. Readers merge it into the original's
 * caption metadata; its fields win.
 */
data class ExtraMetadata(val a: List<String>? = null) {
    fun encoded(): ByteArray = JsonIO.utf8(JsonIO.obj("a" to JsonIO.strings(a)))

    /** The item's albums: `md`'s list when it has one, else the caption's. */
    fun albums(caption: List<String>?): List<String>? = a ?: caption

    companion object {
        /** Null when the document isn't readable: the restore goes on with the caption's metadata. */
        fun decode(data: ByteArray): ExtraMetadata? = try {
            JsonIO.parseObject(data)?.let { ExtraMetadata(JsonFields(it).stringsOrNull("a")) }
        } catch (_: FieldException) {
            null
        }
    }
}
