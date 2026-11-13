package app.lelvo.telegram

/** Where sign-in stands. Same steps as the iOS `TDService.AuthStep`. */
sealed interface AuthStep {
    data object NeedsCredentials : AuthStep
    data object Starting : AuthStep
    data object WaitPhone : AuthStep

    /** [length] is the number of digits Telegram sent, or 0 when the code is a word or phrase. */
    data class WaitCode(val info: String, val length: Int, val delivery: CodeDelivery, val resend: CodeResend?) : AuthStep
    data class WaitPassword(val hint: String) : AuthStep
    data object WaitEmail : AuthStep
    data class WaitOtherDevice(val link: String) : AuthStep
    data object WaitRegistration : AuthStep
    data object Ready : AuthStep
    data object LoggingOut : AuthStep
    data object Closed : AuthStep
}

enum class CodeDelivery { Telegram, Sms, Other }

/** Another way Telegram offers to send the code, available after [afterSeconds]. */
data class CodeResend(val label: String, val afterSeconds: Int)

class TelegramException(val code: Int, override val message: String) : Exception(message) {
    val friendly: String get() = app.lelvo.core.session.TelegramErrors.friendly(code, message)
}
