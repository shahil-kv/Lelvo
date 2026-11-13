package app.lelvo.core.support

import java.net.URI
import java.net.URLDecoder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The same cases as iOS `FeedbackTests`. */
class FeedbackTest {
    private val env = Feedback.Environment("Android", "0.1.0 (12)", "Pixel 9", "Android 16")

    // Splits on the raw "&" before decoding, so an encoded "&" inside a value stays in it.
    private fun query(url: String): Map<String, String> = url.substringAfter('?').split('&').associate { pair ->
        val (k, v) = pair.split('=', limit = 2)
        k to URLDecoder.decode(v.replace("+", "%2B"), Charsets.UTF_8)
    }

    @Test
    fun bugDraftGreetsTheDeveloperAndEndsWithTheAppDetails() {
        val text = Feedback.draft(Feedback.Kind.Bug, "Lelvo", "Shahil", env)
        assertTrue(text.startsWith("Hi Shahil,"))
        assertTrue(text.contains("What happened instead:"))
        assertTrue(text.endsWith("Lelvo 0.1.0 (12), Pixel 9, Android 16"))
    }

    @Test
    fun ideaDraftAsksForTheIdeaAndWhy() {
        val text = Feedback.draft(Feedback.Kind.Idea, "Lelvo", "Shahil", env)
        assertTrue(text.contains("What I'd like:"))
        assertTrue(text.contains("Why it would help:"))
        assertFalse(text.contains("What happened instead:"))
    }

    /** Newlines, ampersands and plus signs must survive, or the draft arrives cut short or with spaces turned into "+". */
    @Test
    fun mailLinkCarriesSubjectAndDraftUnchanged() {
        val text = "Line one & two\n\n1 + 1 = 2? #yes 📷"
        val url = Feedback.mailUrl("dev@example.com", Feedback.subject(Feedback.Kind.Bug, "Lelvo"), text)
        assertTrue(url.startsWith("mailto:dev@example.com?"))
        assertEquals("Lelvo: something isn't working", query(url)["subject"])
        assertEquals(text, query(url)["body"])
        assertFalse(url.contains("+"))
        assertFalse(url.contains(" "))
    }

    @Test
    fun ideaSubjectSaysItIsAnIdea() = assertEquals("Lelvo: an idea", Feedback.subject(Feedback.Kind.Idea, "Lelvo"))

    @Test
    fun bugIssueOpensTheBugTemplateWithDetailsFilledIn() {
        val url = Feedback.gitHubIssueUrl("https://github.com/shahil-kv/Lelvo", Feedback.Kind.Bug, env)
        assertEquals("/shahil-kv/Lelvo/issues/new", URI(url).path)
        val q = query(url)
        assertEquals("bug_report.yml", q["template"])
        assertEquals("Android", q["app"])
        assertEquals("0.1.0 (12)", q["version"])
        assertEquals("Pixel 9, Android 16", q["os"])
    }

    @Test
    fun ideaIssueOpensTheFeatureTemplate() {
        val q = query(Feedback.gitHubIssueUrl("https://github.com/shahil-kv/Lelvo", Feedback.Kind.Idea, env))
        assertEquals("feature_request.yml", q["template"])
        assertEquals("Android", q["app"])
        assertNull(q["version"])
    }

    @Test fun groupPostMatchesThePinnedTemplatesAndCarriesNothingPersonal() {
        val env = Feedback.Environment("Android", "0.2.0 (7)", "Google Pixel 8", "Android 16")
        val bug = Feedback.groupPost(Feedback.Kind.Bug, "Lelvo", env)
        assertTrue(bug.startsWith("🐞 Bug\n\nWhat I did:"))
        assertTrue("What happened instead:" in bug)
        assertTrue(bug.endsWith("Phone: Google Pixel 8, Android 16\nLelvo version: 0.2.0 (7) (Android)"))
        val idea = Feedback.groupPost(Feedback.Kind.Idea, "Lelvo", env)
        assertTrue(idea.startsWith("💡 Feature idea\n\nWhat I'd like Lelvo to do:"))
        assertTrue(idea.endsWith("Lelvo 0.2.0 (7) (Android), Google Pixel 8"))
    }
}
