package app.lelvo.core.support

/**
 * Links and message drafts behind Settings → Report a problem and Suggest a feature (iOS `Feedback`, same text). The
 * app never sends anything itself: it opens a mail app, GitHub or the Lelvo group with the text ready, and the user
 * presses send.
 */
object Feedback {
    enum class Kind { Bug, Idea }

    /** What the app runs on, put into every draft so a bug can be reproduced without asking back. Nothing personal. */
    data class Environment(
        /** Matches the "App" dropdown in the issue templates. */
        val app: String,
        val version: String,
        val device: String,
        val os: String,
    )

    fun draft(kind: Kind, appName: String, developer: String, env: Environment): String {
        val body = when (kind) {
            Kind.Bug -> "Hi $developer, something isn't working in $appName.\n\nWhat I was doing:\n\n\nWhat happened instead:\n\n"
            Kind.Idea -> "Hi $developer, I have an idea for $appName.\n\nWhat I'd like:\n\n\nWhy it would help:\n\n"
        }
        return body + "\n— $appName ${env.version}, ${env.device}, ${env.os}"
    }

    /**
     * The same report for the Lelvo group on Telegram, matching the template pinned in its Bugs and Feature ideas topics.
     * Telegram doesn't let an app type into a group, so the app copies this and opens the topic for the user to paste.
     */
    fun groupPost(kind: Kind, appName: String, env: Environment): String = when (kind) {
        Kind.Bug -> "🐞 Bug\n\nWhat I did:\n\nWhat I expected:\n\nWhat happened instead:\n\nHow often: every time / sometimes / once\n" +
            "Phone: ${env.device}, ${env.os}\n$appName version: ${env.version} (${env.app})"
        Kind.Idea -> "💡 Feature idea\n\nWhat I'd like $appName to do:\n\nWhy it would help me:\n\nHow I do it today:\n\n" +
            "$appName ${env.version} (${env.app}), ${env.device}"
    }

    fun subject(kind: Kind, appName: String): String =
        if (kind == Kind.Bug) "$appName: something isn't working" else "$appName: an idea"

    /**
     * A mailto link with the subject and body filled in. Mail apps don't decode "+" as a space, so spaces go as %20,
     * and "&" inside the text is encoded so it doesn't end the body early.
     */
    fun mailUrl(to: String, subject: String, body: String): String = "mailto:$to?subject=${encode(subject)}&body=${encode(body)}"

    /**
     * The repository's issue form for [kind], with the fields the form has filled in from [env]. GitHub fills a form
     * field from the query parameter named after its `id`; see .github/ISSUE_TEMPLATE.
     */
    fun gitHubIssueUrl(repository: String, kind: Kind, env: Environment): String {
        val fields = when (kind) {
            Kind.Bug -> listOf("template" to "bug_report.yml", "app" to env.app, "version" to env.version, "os" to "${env.device}, ${env.os}")
            Kind.Idea -> listOf("template" to "feature_request.yml", "app" to env.app)
        }
        return repository.trimEnd('/') + "/issues/new?" + fields.joinToString("&") { (k, v) -> "$k=${encode(v)}" }
    }

    // Foundation's urlQueryAllowed without "&+=?#", so the iPhone and Android links are the same.
    private const val ALLOWED = "!$'()*,-./:;@_~"

    private fun encode(value: String): String = buildString {
        for (b in value.encodeToByteArray()) {
            val c = (b.toInt() and 0xFF).toChar()
            if (c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' || c in ALLOWED) append(c)
            else append('%').append("0123456789ABCDEF"[c.code shr 4]).append("0123456789ABCDEF"[c.code and 15])
        }
    }
}
