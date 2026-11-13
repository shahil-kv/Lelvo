package app.lelvo.core

import app.lelvo.core.crypto.E2EKeys
import app.lelvo.core.format.CaptionCodec
import app.lelvo.core.format.CaptionException
import app.lelvo.core.format.CaptionMeta
import app.lelvo.core.format.CloudFileNames
import app.lelvo.core.format.ExtraMetadata
import app.lelvo.core.format.Kind
import app.lelvo.core.format.Role
import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CaptionCodecTest {
    private val keys = E2EKeys.random()
    private val id = "0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10"
    private fun plain(fields: String) = """CG1:{"v":1,"id":"$id","r":"o","k":"p","h":"${"0".repeat(64)}","n":"a.jpg","s":1$fields}"""

    @Test
    fun encryptedRoundTripKeepsEveryField() {
        val meta = sampleMeta().copy(
            e = 1, a = listOf("Goa Trip", "Família"), fav = 1, p = listOf(1, 3, 2_096_103_424), l = "local/1", ed = 1, hid = 1,
            g = CaptionMeta.roundedGps(12.9715987, 77.5945627, 920.04),
        )
        val caption = CaptionCodec.encode(meta, keys.captionKey)
        assertTrue(caption.startsWith("CG1E:"))
        assertEquals(meta, CaptionCodec.decode(caption, keys.captionKey))
        assertEquals(CaptionMeta.Part(1, 3, 2_096_103_424), meta.part)
        assertEquals(listOf(12.971599, 77.594563, 920.0), meta.g)
    }

    @Test
    fun foreignCaptionsAndMissingOrWrongKeys() {
        assertFailsWith<CaptionException.NotLelvo> { CaptionCodec.decode("#cloudgallery id:x role:original") }
        assertFailsWith<CaptionException.NotLelvo> { CaptionCodec.decode("") }
        assertFailsWith<CaptionException.Malformed> { CaptionCodec.decode("CG1:{not json") }
        assertFailsWith<CaptionException.Malformed> { CaptionCodec.decode("CG1:[1]") }
        val sealed = CaptionCodec.encode(sampleMeta().copy(e = 1), keys.captionKey)
        assertFailsWith<CaptionException.EncryptedNeedsKey> { CaptionCodec.decode(sealed) }
        assertFailsWith<CaptionException.Malformed> { CaptionCodec.decode(sealed, E2EKeys.random().captionKey) }
        assertFailsWith<CaptionException.Malformed> { CaptionCodec.decode("CG1E:not base64!", keys.captionKey) }
        assertFailsWith<CaptionException.Malformed> { CaptionCodec.decode("CG1E:AAAA", keys.captionKey) }
        // Notes and snapshots are never item captions.
        assertFalse(CaptionCodec.isLelvo("CGT1:{}") || CaptionCodec.isLelvo("CGM1E:xx") || CaptionCodec.isLelvo("CGX1:{}"))
    }

    @Test
    fun unknownFieldsAreIgnored() {
        assertEquals("a.jpg", CaptionCodec.decode(plain(""","future":{"x":[1,{"y":null}]},"zz":"1"""")).n)
        // null is the same as not there.
        assertNull(CaptionCodec.decode(plain(""","m":null,"t":null""")).m)
    }

    @Test
    fun unknownRolesKindsAndVersionsAreSkippedNotGuessed() {
        val base = plain("")
        assertFailsWith<CaptionException.Malformed> { CaptionCodec.decode(base.replace(""""r":"o"""", """"r":"zz"""")) }
        assertFailsWith<CaptionException.Malformed> { CaptionCodec.decode(base.replace(""""k":"p"""", """"k":"x"""")) }
        assertEquals(2, assertFailsWith<CaptionException.UnsupportedVersion> { CaptionCodec.decode(base.replace(""""v":1""", """"v":2""")) }.version)
        for (role in Role.entries) assertEquals(role, CaptionCodec.decode(base.replace(""""r":"o"""", """"r":"${role.wire}"""")).r)
        assertEquals(setOf("o", "pv", "t", "sp", "e", "d", "ad", "ad2", "ra", "epv", "md"), Role.entries.map { it.wire }.toSet())
        assertEquals(setOf("d", "sp", "t", "ad", "ad2", "ra", "epv", "md"), Role.entries.filter { it.isOptionalOnly }.map { it.wire }.toSet())
        assertEquals(setOf(Role.ORIGINAL, Role.PAIRED_VIDEO), Kind.LIVE.requiredRoles)
    }

    @Test
    fun missingOrMistypedFieldsAreMalformed() {
        val base = plain("")
        for (key in listOf("v", "id", "r", "k", "h", "n", "s")) {
            val without = base.replace(Regex(""""$key":("[^"]*"|\d+),?"""), "").replace(",}", "}")
            assertFailsWith<CaptionException.Malformed>(key) { CaptionCodec.decode(without) }
        }
        assertFailsWith<CaptionException.Malformed> { CaptionCodec.decode(plain(""","t":"1729677600"""")) }
        assertFailsWith<CaptionException.Malformed> { CaptionCodec.decode(plain(""","t":1.5""")) }
        assertFailsWith<CaptionException.Malformed> { CaptionCodec.decode(plain(""","fav":true""")) }
        assertFailsWith<CaptionException.Malformed> { CaptionCodec.decode(plain(""","a":"Album"""")) }
        assertFailsWith<CaptionException.Malformed> { CaptionCodec.decode(plain(""","d":NaN""")) }
        assertFailsWith<CaptionException.Malformed> { CaptionCodec.decode(base.replace(id, "not-a-uuid")) }
        assertFailsWith<CaptionException.Malformed> { CaptionCodec.decode(base.replace("0".repeat(64), "0".repeat(63))) }
        // Whole numbers written as 1.0, and a duration written as 63.
        assertEquals(5L, CaptionCodec.decode(plain(""","t":5.0""")).t)
        assertEquals(63.0, CaptionCodec.decode(plain(""","d":63""")).d)
        // Split info of the wrong shape is no split info.
        assertNull(CaptionCodec.decode(plain(""","p":[0,2]""")).part)
    }

    @Test
    fun longCaptionsAreTrimmedInTheContractsOrder() {
        val meta = sampleMeta().copy(e = 1, l = "L".repeat(40), a = (0 until 60).map { "Album with a fairly long name $it" })
        assertFalse(CaptionCodec.keepsAlbums(meta, keys.captionKey))
        assertTrue(CaptionCodec.keepsAlbums(meta.copy(a = listOf("One")), keys.captionKey))
        // Albums go first; the rest stays.
        val first = CaptionCodec.decode(CaptionCodec.encode(meta, keys.captionKey), keys.captionKey)
        assertEquals(meta.copy(a = null), first)

        val long = meta.copy(n = "x".repeat(900) + ".HEIC")
        val caption = CaptionCodec.encode(long, keys.captionKey)
        assertTrue(caption.length <= CaptionCodec.MAX_LENGTH)
        val decoded = CaptionCodec.decode(caption, keys.captionKey)
        assertNull(decoded.a)
        assertNull(decoded.c)
        assertNull(decoded.l)
        assertTrue(decoded.n.endsWith(".HEIC") && decoded.n.length < 905)
        assertEquals(long.h, decoded.h)

        // Names in scripts that take more bytes than characters still fit, and are cut between characters.
        val emoji = CaptionCodec.decode(CaptionCodec.encode(meta.copy(n = "🌴".repeat(400) + ".jpg"), keys.captionKey), keys.captionKey)
        assertTrue(emoji.n.endsWith(".jpg") && emoji.n.dropLast(4).length % 2 == 0)
        assertEquals("abcdefgh.tar.gz".let { "abcdefgh.tar" }.take(8) + ".gz", CaptionCodec.truncatedName("abcdefgh.tar.gz", 100))
        assertEquals(".hidden-file-name".take(8), CaptionCodec.truncatedName(".hidden-file-name", 100))

        // Nothing optional left to drop: refused, not sent to be refused by Telegram.
        assertFailsWith<CaptionException.TooLong> { CaptionCodec.encode(meta.copy(m = "m".repeat(2000)), keys.captionKey) }
    }

    @Test
    fun nothingPlainIsWritten() {
        assertFailsWith<IllegalArgumentException> { CaptionCodec.encode(sampleMeta(), keys.captionKey) }
        assertFailsWith<IllegalArgumentException> { CaptionCodec.encode(sampleMeta().copy(e = 0), keys.captionKey) }
    }

    @Test
    fun writtenTextIsNfcAndIdsLowercase() {
        val meta = sampleMeta().copy(e = 1, id = id.uppercase(), n = "café.jpg", a = listOf("Été"))
        val decoded = CaptionCodec.decode(CaptionCodec.encode(meta, keys.captionKey), keys.captionKey)
        assertEquals(id, decoded.id)
        assertEquals("café.jpg", decoded.n)
        assertEquals(listOf("Été"), decoded.a)
        // Slashes and non-ASCII are written as they are; quotes and control characters escaped.
        assertEquals("""{"a":["a/b \"q\" é\n"]}""", String(ExtraMetadata(listOf("a/b \"q\" é\n")).encoded()))
    }

    @Test
    fun fileNamesOnTelegram() {
        val before = Locale.getDefault()
        try {
            // With Arabic digits as the default, a formatted number would not be 001.
            Locale.setDefault(Locale.forLanguageTag("ar-SA-u-nu-arab"))
            assertEquals("$id.o.cge", CloudFileNames.encrypted(id, Role.ORIGINAL))
            assertEquals("$id.sp.p001.cge", CloudFileNames.encrypted(id, Role.SMOOTH_PREVIEW, 0))
            assertEquals("$id.o.p012.cge", CloudFileNames.encrypted(id, Role.ORIGINAL, 11))
        } finally {
            Locale.setDefault(before)
        }
    }

    @Test
    fun mdResourceWinsOverTheCaption() {
        val md = ExtraMetadata.decode("""{"a":["One","Two"],"future":1}""".toByteArray())!!
        assertEquals(listOf("One", "Two"), md.albums(listOf("One")))
        assertEquals(listOf("One"), ExtraMetadata.decode("{}".toByteArray())!!.albums(listOf("One")))
        assertNull(ExtraMetadata.decode("nope".toByteArray()))
        assertNull(ExtraMetadata.decode("""{"a":"One"}""".toByteArray()))
        assertEquals(md.copy(), ExtraMetadata.decode(ExtraMetadata(listOf("One", "Two")).encoded()))
    }
}
