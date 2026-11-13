package app.lelvo.core.support

/** Strips secrets from text before it is logged or shared. Same rules, in the same order, as the iOS `Redactor`. */
object Redactor {
    private val rules: List<Pair<Regex, String>> = listOf(
        // Bot token: <digits>:<35 url-safe chars>, also inside api.telegram.org/bot<token>/ URLs.
        Regex("""\d{5,}:[A-Za-z0-9_-]{30,}""") to "<bot-token>",
        // Channel / supergroup ids.
        Regex("""-100\d{6,}""") to "<chat-id>",
        // Phone numbers in international format.
        Regex("""\+\d[\d ]{6,}\d""") to "<phone>",
        // api_hash (32 hex characters).
        Regex("""\b[0-9a-fA-F]{32}\b""") to "<api-hash>",
        // file_id values (long base64url strings).
        Regex("""\b[A-Za-z0-9_-]{60,}\b""") to "<file-id>",
    )

    fun redact(text: String, extraSecrets: List<String> = emptyList()): String {
        var result = text
        // Shorter values would wipe ordinary words out of the log.
        for (secret in extraSecrets) if (secret.length >= 4) result = result.replace(secret, "<redacted>")
        for ((regex, template) in rules) result = regex.replace(result, template)
        return result
    }
}
