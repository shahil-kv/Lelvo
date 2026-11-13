package app.lelvo.core

import app.lelvo.core.crypto.CgfeRandomReader
import app.lelvo.core.crypto.E2EKeys
import app.lelvo.core.crypto.FileCrypto
import app.lelvo.core.crypto.Hashing
import app.lelvo.core.crypto.MasterKeyLock
import app.lelvo.core.crypto.RecoveryKey
import app.lelvo.core.crypto.derive
import app.lelvo.core.format.ByteRange
import app.lelvo.core.format.CaptionCodec
import app.lelvo.core.format.CaptionMeta
import app.lelvo.core.format.HeaderResult
import app.lelvo.core.format.Kind
import app.lelvo.core.format.LibraryHeader
import app.lelvo.core.format.MetaLog
import app.lelvo.core.format.NoteCaption
import app.lelvo.core.format.Role
import app.lelvo.core.format.TrashLog
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull

fun sampleMeta() = CaptionMeta(
    id = "0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10", r = Role.ORIGINAL, k = Kind.VIDEO, h = "ab".repeat(32),
    n = "IMG_4821.MOV", s = 734_003_200, m = "video/quicktime", t = 1_729_677_600, tz = 330,
    g = CaptionMeta.roundedGps(12.9715987, 77.5945627), wh = listOf(3840, 2160), d = 63.2, c = "hevc", hdr = 2, src = "ios",
)

/** Every value in docs/test-vectors/format1.json, read and written. */
class Format1VectorTest {
    private val v = Vector("format1.json")
    private val keys by lazy { E2EKeys.derive(v.string("passphrase"), v.bytes("saltHex"), v.int("iterations").toLong()) }

    @Test
    fun everyKeyOfTheFileIsCovered() {
        assertEquals(
            setOf(
                "captionJSON", "captionNonceHex", "encryptedCaption", "fileChunkSize", "fileCipherB64", "fileNoncesHex",
                "filePlaintextLength", "fileSaltHex", "header", "iterations", "keyCheckB64", "masterHex", "passphrase",
                "plainCaption", "saltHex",
            ),
            v.keys,
        )
    }

    @Test
    fun masterKeyAndKeyCheck() {
        assertEquals(v.string("masterHex"), hex(keys.master))
        assertEquals(v.string("keyCheckB64"), Base64.getEncoder().encodeToString(keys.keyCheck))
    }

    @Test
    fun headerReadsWritesAndUnlocks() {
        val header = assertIs<LibraryHeader.V1>(assertIs<HeaderResult.Found>(LibraryHeader.parse(v.string("header"))).header)
        assertEquals(v.int("iterations").toLong(), header.iterations)
        assertContentEquals(v.bytes("saltHex"), header.salt)
        assertEquals(v.string("header"), header.line)
        assertEquals(v.string("header"), LibraryHeader.V1(v.int("iterations").toLong(), v.bytes("saltHex"), keys.keyCheck).line)
        assertEquals(v.string("masterHex"), hex(assertNotNull(header.unlock(v.string("passphrase"))).master))
        assertNull(header.unlock("wrong passphrase"))
        // As the pinned message has it.
        assertEquals(header, (LibraryHeader.parse(LibraryHeader.MESSAGE_PREFIX + v.string("header")) as HeaderResult.Found).header)
    }

    @Test
    fun captionJsonIsByteForByteTheIPhones() {
        assertEquals(v.string("captionJSON"), CaptionCodec.json(sampleMeta()))
        assertEquals(CaptionCodec.PLAIN_PREFIX + v.string("captionJSON"), v.string("plainCaption"))
    }

    @Test
    fun plainCaptionIsRead() {
        assertEquals(sampleMeta(), CaptionCodec.decode(v.string("plainCaption")))
        assertEquals(12.971599, sampleMeta().latitude)
    }

    @Test
    fun encryptedCaptionReadsAndWritesTheSameBytes() {
        assertEquals(sampleMeta(), CaptionCodec.decode(v.string("encryptedCaption"), keys.captionKey))
        // The vector's caption is of a plain-library file (no `e`); sealing its JSON gives the vector's bytes.
        val sealed = app.lelvo.core.crypto.CaptionBox.seal(v.string("captionJSON").toByteArray(), keys.captionKey, "CG1E", v.bytes("captionNonceHex"))
        assertEquals(v.string("encryptedCaption"), CaptionCodec.ENCRYPTED_PREFIX + Base64.getEncoder().encodeToString(sealed))
        // And through the writer, with `e` as Android always sets it.
        val written = CaptionCodec.encode(sampleMeta().copy(e = 1), keys.captionKey, v.bytes("captionNonceHex"))
        assertEquals(sampleMeta().copy(e = 1), CaptionCodec.decode(written, keys.captionKey))
    }

    @Test
    fun fileEncryptsToTheSameBytesAndDecryptsBack() {
        val plain = vectorPlaintext(v.int("filePlaintextLength"))
        val cipher = Base64.getDecoder().decode(v.string("fileCipherB64"))
        val made = FileCrypto.encryptForTesting(plain, keys.master, v.int("fileChunkSize"), v.bytes("fileSaltHex"), v.strings("fileNoncesHex").map(::unhex))
        assertContentEquals(cipher, made)
        assertEquals(cipher.size.toLong(), FileCrypto.encryptedSize(plain.size.toLong(), v.int("fileChunkSize")))
        assertContentEquals(plain, FileCrypto.decrypt(cipher, keys.master))

        val reader = CgfeRandomReader(cipher.copyOf(25), cipher.size.toLong(), keys.master)
        assertEquals(v.int("fileChunkSize"), reader.layout.chunkSize)
        assertEquals(plain.size.toLong(), reader.layout.plaintextSize)
        assertEquals(v.strings("fileNoncesHex").size.toLong(), reader.layout.chunkCount)
        val piece = reader.read(ByteRange(4000, 8300)) { cipher.copyOfRange(it.start.toInt(), it.endExclusive.toInt()) }
        assertContentEquals(plain.copyOfRange(4000, 8300), piece)
    }
}

/** docs/test-vectors/format2-header.json. */
class Format2HeaderVectorTest {
    private val v = Vector("format2-header.json")
    private val argon = app.lelvo.core.crypto.Argon2Parameters(
        v.int("argon2idIterations").toLong(), v.int("argon2idMemoryKiB").toLong(), v.int("argon2idParallelism"),
    )

    @Test
    fun everyKeyOfTheFileIsCovered() {
        assertEquals(
            setOf(
                "argon2idIterations", "argon2idMemoryKiB", "argon2idParallelism", "header", "masterHex", "passphrase",
                "passphraseKeyHex", "passphraseNonceHex", "recoveryKey", "recoveryLockKeyHex", "recoveryNonceHex", "saltHex",
            ),
            v.keys,
        )
    }

    @Test
    fun passphraseKeyAndRecoveryLockKey() {
        assertEquals(v.string("passphraseKeyHex"), hex(testArgon2.derive(v.string("passphrase"), v.bytes("saltHex"), argon)))
        val recovery = assertNotNull(RecoveryKey.parse(v.string("recoveryKey")))
        assertEquals(v.string("recoveryLockKeyHex"), hex(recovery.lockKey))
        assertEquals(v.string("recoveryKey"), recovery.text)
    }

    @Test
    fun lockingWithTheVectorsSaltAndNoncesGivesTheSameHeader() {
        val recovery = RecoveryKey.parse(v.string("recoveryKey"))!!
        val rebuilt = LibraryHeader.locking(
            E2EKeys(v.bytes("masterHex")), v.string("passphrase"), testArgon2, recovery, argon,
            salt = v.bytes("saltHex"), passphraseNonce = v.bytes("passphraseNonceHex"), recoveryNonce = v.bytes("recoveryNonceHex"),
        )
        assertEquals(v.string("header"), rebuilt.line)
        // The two locked copies, piece by piece.
        val wk = MasterKeyLock.seal(v.bytes("masterHex"), v.bytes("passphraseKeyHex"), MasterKeyLock.Purpose.PASSPHRASE, v.bytes("passphraseNonceHex"))
        assertContentEquals(rebuilt.lockedByPassphrase, wk)
    }

    @Test
    fun headerUnlocksWithPassphraseAndRecoveryKey() {
        val header = assertIs<LibraryHeader.V2>(assertIs<HeaderResult.Found>(LibraryHeader.parse(v.string("header"))).header)
        assertEquals(argon, header.argon)
        assertContentEquals(v.bytes("saltHex"), header.salt)
        assertEquals(v.string("header"), header.line)
        assertEquals(v.string("masterHex"), hex(assertNotNull(header.unlock(v.string("passphrase"), testArgon2)).master))
        assertNull(header.unlock("wrong passphrase", testArgon2))
        assertEquals(v.string("masterHex"), hex(assertNotNull(header.unlock(RecoveryKey.parse(v.string("recoveryKey"))!!)).master))
        assertNull(header.unlock(RecoveryKey.random()))
    }
}

/** docs/test-vectors/metalog1.json and trashlog1.json. */
class NoteVectorsTest {
    private val expectedKeys = setOf("body", "captionNonceHex", "encryptedCaption", "masterHex", "plainCaption")

    @Test
    fun favoritesAndAlbumsNote() {
        val v = Vector("metalog1.json")
        assertEquals(expectedKeys, v.keys)
        val keys = E2EKeys(v.bytes("masterHex"))
        val document = v.string("body").toByteArray()
        val body = assertNotNull(MetaLog.decode(document))
        assertEquals(MetaLog.Body(MetaLog.Op.ALBUM_ADD, listOf("0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10"), "Goa Trip"), body)
        assertEquals(v.string("body"), String(MetaLog.encode(body)))

        val caption = NoteCaption.of(document, body.ids.size)
        assertEquals(v.string("plainCaption"), MetaLog.PLAIN_PREFIX + MetaLog.captionJson(caption))
        assertEquals(caption, MetaLog.parseCaption(v.string("plainCaption"), null))
        assertEquals(v.string("encryptedCaption"), MetaLog.caption(caption, keys.captionKey, v.bytes("captionNonceHex")))
        assertEquals(caption, MetaLog.parseCaption(v.string("encryptedCaption"), keys.captionKey))
        assertEquals(Hashing.sha256Hex(document), caption.h)
        assertEquals(body, MetaLog.read(document, caption))
    }

    @Test
    fun recentlyDeletedNote() {
        val v = Vector("trashlog1.json")
        assertEquals(expectedKeys, v.keys)
        val keys = E2EKeys(v.bytes("masterHex"))
        val document = v.string("body").toByteArray()
        val body = assertNotNull(TrashLog.decode(document))
        assertEquals(TrashLog.Body(TrashLog.Op.DELETE, listOf("0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10")), body)
        assertEquals(v.string("body"), String(TrashLog.encode(body)))

        val caption = NoteCaption.of(document, body.ids.size)
        assertEquals(v.string("plainCaption"), TrashLog.PLAIN_PREFIX + TrashLog.captionJson(caption))
        assertEquals(caption, TrashLog.parseCaption(v.string("plainCaption"), null))
        assertEquals(v.string("encryptedCaption"), TrashLog.caption(caption, keys.captionKey, v.bytes("captionNonceHex")))
        assertEquals(caption, TrashLog.parseCaption(v.string("encryptedCaption"), keys.captionKey))
        assertEquals(body, TrashLog.read(document, caption))
    }
}
