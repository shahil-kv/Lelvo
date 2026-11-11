package app.lelvo.core.session

/** Telegram error text → what the user reads. Same cases and words as the iOS `TDServiceError.friendly`. */
object TelegramErrors {
    private val floodPatterns = listOf(
        Regex("FLOOD(?:_PREMIUM)?_WAIT_(\\d+)", RegexOption.IGNORE_CASE),
        Regex("retry after (\\d+)", RegexOption.IGNORE_CASE),
    )

    fun floodWaitSeconds(message: String): Int? =
        floodPatterns.firstNotNullOfOrNull { it.find(message)?.groupValues?.get(1)?.toIntOrNull() }

    fun keysRejected(message: String): Boolean =
        message.contains("API_ID_INVALID") || message.contains("API_ID_PUBLISHED_FLOOD")

    fun friendly(code: Int, message: String): String = when {
        "PHONE_NUMBER_INVALID" in message -> "That phone number isn't valid. Use international format, e.g. +91 98765 43210."
        "PHONE_CODE_INVALID" in message -> "Wrong login code. Check the code Telegram sent you."
        "PHONE_CODE_EXPIRED" in message -> "The login code expired. Request a new one."
        "PASSWORD_HASH_INVALID" in message -> "Wrong two-step verification password."
        "API_ID_INVALID" in message -> "api_id / api_hash are invalid. Copy them again from my.telegram.org."
        "API_ID_PUBLISHED_FLOOD" in message -> "Telegram blocked this api_id. Create your own at my.telegram.org."
        "USER_RESTRICTED" in message ->
            "Telegram has limited this account, so it can't create channels. In Telegram, message @SpamBot to see why and appeal, or use a different Telegram account."
        "CHANNELS_TOO_MUCH" in message ->
            "This account is in too many channels and groups. Leave some in Telegram, or pick an existing channel below."
        "PHONE_NUMBER_BANNED" in message -> "Telegram has banned this phone number. Use a different Telegram account."
        "FROZEN" in message ->
            "Telegram has frozen this account: it can still read, but it can't upload. Your library stays where it is. Open the Telegram app to see the notice and appeal."
        "FLOOD_WAIT" in message || code == 429 -> "Telegram asked us to slow down. Waiting ${floodWaitSeconds(message) ?: 0} s."
        else -> "Telegram error $code: $message"
    }
}
