package app.lelvo.core

import app.lelvo.core.crypto.Argon2Parameters
import app.lelvo.core.crypto.CryptoException
import app.lelvo.core.crypto.E2EKeys
import app.lelvo.core.crypto.FileCrypto
import app.lelvo.core.crypto.KeyDerivation
import app.lelvo.core.crypto.MasterKeyLock
import app.lelvo.core.crypto.Passphrase
import app.lelvo.core.crypto.RecoveryKey
import app.lelvo.core.crypto.derive
import app.lelvo.core.format.CaptionCodec
import app.lelvo.core.format.HeaderResult
import app.lelvo.core.format.LibraryHeader
import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LibraryHeaderTest {
    private val zeros16 = "AAAAAAAAAAAAAAAAAAAAAA=="
    private fun found(text: String) = assertIs<HeaderResult.Found>(LibraryHeader.parse(text)).header
    private fun newLibrary(passphrase: String) = LibraryHeader.newLibrary(passphrase, testArgon2, cheapArgon)

    @Test
    fun plainMissingAndWhereTheHeaderIs() {
        assertEquals(LibraryHeader.Plain, found("CloudGallery Library\ncg:1"))
        assertEquals(LibraryHeader.Plain, found("#cloudgallery-library cg:1"))
        assertEquals(LibraryHeader.Plain, found("  #cloudgallery-library   cg:1  \r\n"))
        assertEquals(HeaderResult.Missing, LibraryHeader.parse("hello"))
        assertEquals(HeaderResult.Missing, LibraryHeader.parse(""))
        // A line of an ordinary channel's description that happens to start with "cg:".
        assertEquals(HeaderResult.Missing, LibraryHeader.parse("My channel\ncg: computer graphics"))
        assertEquals(HeaderResult.Missing, LibraryHeader.parse("not at the start cg:1"))
    }

    @Test
    fun aNewerFormatIsNeverTakenForAMissingHeader() {
        assertEquals(HeaderResult.Newer(3), LibraryHeader.parse("#cloudgallery-library cg:3;e2e:1;x:y"))
        assertEquals(HeaderResult.Newer(3), LibraryHeader.parse("#cloudgallery-library cg:3;zz\n#cloudgallery-library cg:1"))
        assertEquals(HeaderResult.Newer(3), LibraryHeader.parse("Lelvo Library · do not edit\ncg:3;e2e:1"))
        // A version too big for an Int is newer, not unreadable and certainly not missing.
        assertIs<HeaderResult.Newer>(LibraryHeader.parse("cg:99999999999999999999999"))
        assertIs<HeaderResult.Newer>(LibraryHeader.parse("cg:4294967298"))
    }

    @Test
    fun aHeaderThatCantBeReadIsDamagedNotMissing() {
        // Too few iterations, a cut value, an unknown flag, a version that never existed.
        assertEquals(HeaderResult.Damaged, LibraryHeader.parse("cg:1;e2e:1;it:50;s:$zeros16;kc:$zeros16"))
        assertEquals(HeaderResult.Damaged, LibraryHeader.parse("cg:1;e2e:1;it:600000;s:$zeros16"))
        assertEquals(HeaderResult.Damaged, LibraryHeader.parse("cg:1;e2e:1;it:600000;s:AAAA;kc:$zeros16"))
        assertEquals(HeaderResult.Damaged, LibraryHeader.parse("cg:1;e2e:2"))
        assertEquals(HeaderResult.Damaged, LibraryHeader.parse("cg:0"))
        assertEquals(HeaderResult.Damaged, LibraryHeader.parse("#cloudgallery-library cg:two"))
        assertEquals(HeaderResult.Damaged, LibraryHeader.parse("cg:2"))

        val header = newLibrary("pw").header
        val weak = header.line.replace("a2:1,${cheapArgon.memoryKiB},1", "a2:1,1024,1")
        assertEquals(HeaderResult.Damaged, LibraryHeader.parse(weak))
        assertEquals(HeaderResult.Damaged, LibraryHeader.parse(header.line.dropLast(10)))
        assertEquals(HeaderResult.Damaged, LibraryHeader.parse(header.line.replace("a2:1,", "a2:0,")))
        assertEquals(HeaderResult.Damaged, LibraryHeader.parse(header.line.replace(",1;s:", ",17;s:")))
        assertEquals(HeaderResult.Damaged, LibraryHeader.parse(header.line.replace("a2:1,", "a2:x,")))
        // The pinned message with its format 2 line cut: the format 1 decoy must not become "wrong passphrase".
        val lines = header.messageText.split("\n")
        assertEquals(HeaderResult.Damaged, LibraryHeader.parse(lines[0].dropLast(10) + "\n" + lines[1]))
        // An encrypted line that can't be read never turns the library into a plain one.
        assertEquals(HeaderResult.Damaged, LibraryHeader.parse("cg:1\ncg:1;e2e:1;it:5"))
    }

    @Test
    fun newLibraryOpensWithPassphraseOrRecoveryKey() {
        val made = newLibrary("correct horse")
        assertEquals(2, made.header.version)
        assertEquals(LelvoFormat.WRITTEN_HEADER_FORMAT, made.header.version)
        assertContentEquals(made.keys.master, made.header.unlock("correct horse", testArgon2)?.master)
        assertNull(made.header.unlock("wrong horse", testArgon2))
        assertNull(made.header.unlock("", testArgon2))
        assertContentEquals(made.keys.master, made.header.unlock(made.recoveryKey)?.master)
        assertNull(made.header.unlock(RecoveryKey.random()))
        assertFailsWith<CryptoException.DerivationFailed> { newLibrary("") }
    }

    @Test
    fun pinnedMessageRoundTripsAndOlderVersionsCantOpenIt() {
        val header = newLibrary("pw").header
        assertEquals(header, found(header.messageText))
        assertEquals(header, found("Lelvo Library · do not edit\n" + header.line))
        // What a format 1 reader sees: only the cg:1 line, with random values, so the passphrase never matches.
        val decoy = assertIs<LibraryHeader.V1>(found(header.messageText.split("\n").first { it.contains("cg:1") }))
        assertEquals(E2EKeys.DEFAULT_ITERATIONS, decoy.iterations)
        assertNull(decoy.unlock("pw"))
        assertNotEquals(header.messageText, header.messageText)
        // The description holds the format 2 line alone and must fit Telegram's 255 characters with its label.
        val standard = LibraryHeader.V2(Argon2Parameters.STANDARD, header.salt, header.lockedByPassphrase, header.lockedByRecoveryKey)
        assertTrue(("Lelvo Library · do not edit\n" + standard.line).length <= 255)
    }

    @Test
    fun changingThePassphraseKeepsTheKeyAndTheRecoveryKey() {
        val made = newLibrary("old")
        val changed = made.header.changingPassphrase(made.keys, "new’s", testArgon2)
        assertNull(changed.unlock("old", testArgon2))
        assertContentEquals(made.keys.master, changed.unlock("new's", testArgon2)?.master)
        assertContentEquals(made.keys.master, changed.unlock(made.recoveryKey)?.master)
        assertNotEquals(hex(made.header.salt), hex(changed.salt))
    }

    @Test
    fun upgradingFormat1KeepsTheMasterKeyAndAddsARecoveryKey() {
        val salt = ByteArray(16) { it.toByte() }
        val keys = E2EKeys.derive("old", salt, E2EKeys.MINIMUM_ITERATIONS)
        val v1 = LibraryHeader.V1(E2EKeys.MINIMUM_ITERATIONS, salt, keys.keyCheck)
        val opened = assertNotNull(v1.unlock("old"))
        val (upgraded, recovery) = v1.upgrading(opened, "new’s", testArgon2, cheapArgon)
        // Files were sealed with the format 1 key, so the upgraded header must open to exactly that key.
        assertContentEquals(keys.master, upgraded.unlock("new's", testArgon2)?.master)
        assertContentEquals(keys.master, upgraded.unlock(recovery)?.master)
        assertNull(upgraded.unlock("old", testArgon2))
        assertEquals(2, found(upgraded.line).version)
    }

    @Test
    fun aNewRecoveryKeyReplacesTheOldOne() {
        val made = newLibrary("pw")
        val (replaced, fresh) = made.header.replacingRecoveryKey(made.keys)
        assertNull(replaced.unlock(made.recoveryKey))
        assertContentEquals(made.keys.master, replaced.unlock(fresh)?.master)
        assertContentEquals(made.keys.master, replaced.unlock("pw", testArgon2)?.master)
    }

    @Test
    fun lockedCopiesCantBeSwapped() {
        val h = newLibrary("pw").header
        val swapped = LibraryHeader.V2(h.argon, h.salt, h.lockedByRecoveryKey, h.lockedByPassphrase)
        assertNull(swapped.unlock("pw", testArgon2))
    }

    /** A header edited to ask for an extreme cost is refused before any work, and still counts as encrypted. */
    @Test
    fun unlockingRefusesACostBeyondTheLimits() {
        val h = newLibrary("pw").header
        var calls = 0
        val counting = app.lelvo.core.crypto.Argon2id { p, s, t, m, l, n -> calls++; testArgon2.hash(p, s, t, m, l, n) }
        for (cost in listOf(Argon2Parameters(1, Argon2Parameters.MAXIMUM_MEMORY_KIB + 1), Argon2Parameters(11, cheapArgon.memoryKiB), Argon2Parameters(4_294_967_295, 4_294_967_295))) {
            val extreme = LibraryHeader.V2(cost, h.salt, h.lockedByPassphrase, h.lockedByRecoveryKey)
            assertFailsWith<CryptoException.DerivationFailed> { extreme.unlock("pw", counting) }
            assertTrue(found(extreme.messageText).encrypted)
            assertEquals(extreme, found(extreme.line))
        }
        assertEquals(0, calls)

        val salt = KeyDerivation.randomSalt()
        val tooMany = assertIs<LibraryHeader.V1>(found(LibraryHeader.V1(4_294_967_295, salt, salt).line))
        assertFailsWith<CryptoException.DerivationFailed> { tooMany.unlock("pw") }
        assertFailsWith<CryptoException.DerivationFailed> { LibraryHeader.V1(E2EKeys.MAXIMUM_ITERATIONS + 1, salt, salt).unlock("pw") }
        // In range: just the wrong passphrase.
        assertNull(LibraryHeader.V1(E2EKeys.MINIMUM_ITERATIONS, salt, salt).unlock("pw"))
    }

    /** A format 1 library upgraded on the iPhone keeps its master key, so everything written before still opens. */
    @Test
    fun aLibraryUpgradedFromFormat1KeepsEverythingReadable() {
        val salt = KeyDerivation.randomSalt()
        val keys = E2EKeys.derive("pw", salt, E2EKeys.MINIMUM_ITERATIONS)
        val v1 = LibraryHeader.V1(E2EKeys.MINIMUM_ITERATIONS, salt, keys.keyCheck)
        val caption = CaptionCodec.encode(sampleMeta().copy(e = 1), keys.captionKey)
        val file = FileCrypto.encrypt("photo bytes".toByteArray(), keys.master)

        val recovery = RecoveryKey.random()
        val v2 = LibraryHeader.locking(assertNotNull(v1.unlock("pw")), "pw", testArgon2, recovery, cheapArgon)
        val reopened = assertNotNull(v2.unlock("pw", testArgon2))
        assertEquals(sampleMeta().id, CaptionCodec.decode(caption, reopened.captionKey).id)
        assertContentEquals("photo bytes".toByteArray(), FileCrypto.decrypt(file, reopened.master))
        assertContentEquals(keys.master, v2.unlock(recovery)?.master)
        assertTrue(!v2.line.contains("kc:"))
    }
}

class PassphraseTest {
    private fun newLibrary(passphrase: String) = LibraryHeader.newLibrary(passphrase, testArgon2, cheapArgon)

    @Test
    fun smartPunctuationGoesBackToTheTypedKeys() {
        assertEquals("don't \"panic\" -- ok...", Passphrase.normalized("don’t “panic” — ok…"))
        assertEquals("'''' \"\"\"\" a b", Passphrase.normalized("‘’‚‛ “”„‟ a b"))
        // Spaces are kept: what older versions use, byte for byte.
        assertEquals("  spaced out \n", Passphrase.normalized("  spaced out \n"))
        assertEquals("plain ascii-only", Passphrase.normalized("plain ascii-only"))
        // Other dashes, emoji and accents are not touched.
        assertEquals("a–b 🔑 é", Passphrase.normalized("a–b 🔑 é"))
        // A quote carrying a combining mark is another character on the iPhone, which leaves it; so does Android.
        assertEquals("x’́y", Passphrase.normalized("x’́y"))
    }

    @Test
    fun whatUnlockingTriesAndInWhichOrder() {
        assertEquals(listOf("plain"), Passphrase.candidates("plain"))
        assertEquals(listOf(" x’y", " x'y", "x'y"), Passphrase.candidates(" x’y"))
        assertEquals(listOf("pw \n", "pw"), Passphrase.candidates("pw \n"))
        assertEquals(listOf(" pw ", " pw ", "pw"), Passphrase.candidates(" pw "))
        assertEquals(emptyList(), Passphrase.candidates(""))
        assertEquals(listOf("  "), Passphrase.candidates("  "))
    }

    @Test
    fun aLibraryMadeOnTheIPhoneOpensOnAndroid() {
        // Set with Show on (Smart Punctuation); typed here with plain keys, the same way, or with a stray space.
        val made = newLibrary("my dog’s name — rex")
        for (typed in listOf("my dog's name -- rex", "my dog’s name — rex", "my dog's name -- rex ")) {
            assertContentEquals(made.keys.master, made.header.unlock(typed, testArgon2)?.master, typed)
        }
        assertNull(made.header.unlock("my dogs name rex", testArgon2))
        val plainKeys = newLibrary("it's -- fine")
        assertContentEquals(plainKeys.keys.master, plainKeys.header.unlock("it’s — fine", testArgon2)?.master)
    }

    @Test
    fun aPassphraseWithoutSmartPunctuationIsUsedExactlyAsTyped() {
        // Older versions of Lelvo derive from the typed text with no changes; a new library must open there too.
        val typed = " spaces and plain 'quotes' "
        val made = newLibrary(typed)
        val key = testArgon2.derive(typed, made.header.salt, cheapArgon)
        assertContentEquals(made.keys.master, MasterKeyLock.open(made.header.lockedByPassphrase, key, MasterKeyLock.Purpose.PASSPHRASE))
    }

    @Test
    fun librariesLockedBeforeNormalizationStillOpen() {
        // Before November 2026 the passphrase was used exactly as typed, smart quotes and spaces included.
        val keys = E2EKeys.random()
        val salt = ByteArray(16) { 7 }
        val typed = " old’one "
        val old = LibraryHeader.V2(
            cheapArgon, salt,
            MasterKeyLock.seal(keys.master, testArgon2.derive(typed, salt, cheapArgon), MasterKeyLock.Purpose.PASSPHRASE),
            MasterKeyLock.seal(keys.master, RecoveryKey.random().lockKey, MasterKeyLock.Purpose.RECOVERY),
        )
        assertContentEquals(keys.master, old.unlock(typed, testArgon2)?.master)
        // A format 1 library, too, and one whose passphrase was set with plain keys.
        val v1Keys = E2EKeys.derive(typed, salt, 1_000)
        val v1 = LibraryHeader.V1(E2EKeys.MINIMUM_ITERATIONS, salt, v1Keys.keyCheck)
        assertNull(v1.unlock(typed)) // other iteration count: other key
        val exact = E2EKeys.derive(typed, salt, E2EKeys.MINIMUM_ITERATIONS)
        assertContentEquals(exact.master, LibraryHeader.V1(E2EKeys.MINIMUM_ITERATIONS, salt, exact.keyCheck).unlock(typed)?.master)
        val straight = E2EKeys.derive("old'one", salt, E2EKeys.MINIMUM_ITERATIONS)
        assertContentEquals(straight.master, LibraryHeader.V1(E2EKeys.MINIMUM_ITERATIONS, salt, straight.keyCheck).unlock(typed)?.master)
    }
}

class RecoveryKeyTest {
    @Test
    fun textRoundTripsAndForgivesTypos() {
        val key = RecoveryKey.random()
        assertEquals(52 + 12, key.text.length)
        assertTrue(Regex("([A-Z2-7]{4}-){12}[A-Z2-7]{4}").matches(key.text))
        assertEquals(key, RecoveryKey.parse(key.text))
        assertEquals(key, RecoveryKey.parse(key.text.lowercase().replace("-", " ")))
        assertEquals(key, RecoveryKey.parse(key.text.replace("O", "0").replace("I", "1").replace("B", "8")))
        // Pasted from a note: line breaks from any system, tabs, no-break spaces, typographic dashes.
        assertEquals(key, RecoveryKey.parse("  " + key.text.replace("-", "\r\n") + "\t\n"))
        assertEquals(key, RecoveryKey.parse(key.text.replace("-", "–").chunked(10).joinToString(" ")))
        assertEquals(key, RecoveryKey.parse(key.text.replace("-", "")))
        assertNull(RecoveryKey.parse("ABCD-EFGH"))
        assertNull(RecoveryKey.parse("!".repeat(52)))
        assertNull(RecoveryKey.parse(key.text + "A"))
        assertNull(RecoveryKey.parse(key.text.dropLast(1) + "9"))
        assertNull(RecoveryKey.parse(""))
        assertNull(RecoveryKey.of(ByteArray(31)))
        assertEquals(key, RecoveryKey.of(key.bytes))
    }

    @Test
    fun aPhoneSetToTurkishReadsTheSameKey() {
        val key = RecoveryKey.of(ByteArray(32) { (it * 37 + 64).toByte() })!!
        val before = Locale.getDefault()
        try {
            // In Turkish, "i".uppercase() with the phone's locale is "İ", which is not in the alphabet.
            Locale.setDefault(Locale.forLanguageTag("tr-TR"))
            assertTrue(key.text.contains('I'))
            assertEquals(key, RecoveryKey.parse(key.text.lowercase(Locale.ROOT)))
        } finally {
            Locale.setDefault(before)
        }
    }

    @Test
    fun keysNeverPrint() {
        val key = RecoveryKey.random()
        assertTrue(!key.toString().contains(key.text.take(4)))
        assertEquals("E2EKeys(hidden)", E2EKeys.random().toString())
    }
}
