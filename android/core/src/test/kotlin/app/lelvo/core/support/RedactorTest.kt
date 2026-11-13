package app.lelvo.core.support

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

// Mirrors ParsingTests.redactsSecrets in Packages/LelvoCore/Tests, plus one case per rule.
class RedactorTest {
    @Test fun redactsSecrets() {
        val line = "POST https://api.telegram.org/bot123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ/sendDocument chat -1001234567890"
        val out = Redactor.redact(line)
        assertFalse(out.contains("AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ"))
        assertFalse(out.contains("1234567890"))
        assertTrue(out.contains("<bot-token>"))
        assertEquals("my <redacted>", Redactor.redact("my secret passphrase", listOf("secret passphrase")))
    }

    @Test fun chatIds() = assertEquals("chat <chat-id> ok", Redactor.redact("chat -1009876543 ok"))

    @Test fun phoneNumbers() {
        assertEquals("sent to <phone>", Redactor.redact("sent to +44 7700 900123"))
        assertEquals("sent to <phone>", Redactor.redact("sent to +919876543210"))
    }

    @Test fun apiHash() = assertEquals("hash <api-hash>", Redactor.redact("hash 0123456789abcdef0123456789ABCDEF"))

    @Test fun fileIds() {
        val id = "BQACAgIAAxkBAAIBY2Z" + "a".repeat(50)
        assertEquals("file <file-id>", Redactor.redact("file $id"))
    }

    @Test fun shortSecretsAreLeftAlone() = assertEquals("the cat", Redactor.redact("the cat", listOf("cat")))

    @Test fun ordinaryLinesStayReadable() {
        val line = "Library scan (full): 2918 messages, 1124 items, 1 incomplete, 0 duplicates"
        assertEquals(line, Redactor.redact(line))
    }

    @Test fun logFileIsRedactedRotatedAndCleared() {
        val dir = Files.createTempDirectory("applog").toFile()
        AppLog.install(dir, secrets = { listOf("hunter22") })
        AppLog.clear()
        AppLog.warn("password hunter22 for +44 7700 900123")
        val text = AppLog.contents()
        assertTrue(text.contains("[WARN] password <redacted> for <phone>"), text)
        assertFalse(text.contains("hunter22"))
        AppLog.clear()
        assertEquals("", AppLog.contents())
        dir.deleteRecursively()
    }
}
