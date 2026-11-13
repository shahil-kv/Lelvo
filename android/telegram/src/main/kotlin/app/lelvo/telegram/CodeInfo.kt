package app.lelvo.telegram

import org.drinkless.tdlib.TdApi

// Same wording and rules as TDService.describe / delivery / resend / codeLength on iOS.
internal object CodeInfo {
    fun describe(info: TdApi.AuthenticationCodeInfo): String = when (val t = info.type) {
        is TdApi.AuthenticationCodeTypeTelegramMessage -> "Enter the code Telegram sent to your other device or app."
        is TdApi.AuthenticationCodeTypeSms -> "Enter the code sent by SMS to ${info.phoneNumber}."
        is TdApi.AuthenticationCodeTypeSmsWord -> "Enter the word sent by SMS to ${info.phoneNumber}."
        is TdApi.AuthenticationCodeTypeSmsPhrase -> "Enter the phrase sent by SMS to ${info.phoneNumber}."
        is TdApi.AuthenticationCodeTypeCall -> "You'll receive a call with the code."
        is TdApi.AuthenticationCodeTypeMissedCall ->
            "You'll get a missed call from a number starting with ${t.phoneNumberPrefix}. Enter its last ${t.length} digits."
        is TdApi.AuthenticationCodeTypeFragment -> "Enter the code shown on fragment.com for your anonymous number."
        else -> "Enter the login code sent to ${info.phoneNumber}."
    }

    fun delivery(type: TdApi.AuthenticationCodeType): CodeDelivery = when (type) {
        is TdApi.AuthenticationCodeTypeTelegramMessage -> CodeDelivery.Telegram
        is TdApi.AuthenticationCodeTypeSms, is TdApi.AuthenticationCodeTypeSmsWord,
        is TdApi.AuthenticationCodeTypeSmsPhrase -> CodeDelivery.Sms
        else -> CodeDelivery.Other
    }

    /** Null when Telegram has no other way to send the code (`nextType` is null), so the screen offers nothing. */
    fun resend(info: TdApi.AuthenticationCodeInfo): CodeResend? {
        val label = when (info.nextType) {
            is TdApi.AuthenticationCodeTypeSms, is TdApi.AuthenticationCodeTypeSmsWord,
            is TdApi.AuthenticationCodeTypeSmsPhrase -> "Send by SMS instead"
            is TdApi.AuthenticationCodeTypeCall, is TdApi.AuthenticationCodeTypeFlashCall,
            is TdApi.AuthenticationCodeTypeMissedCall -> "Call me instead"
            is TdApi.AuthenticationCodeTypeTelegramMessage -> "Send to Telegram again"
            else -> return null
        }
        return CodeResend(label, maxOf(0, info.timeout))
    }

    /** Digits in the code (Telegram sends 5 or 6, depending on the account and delivery), 0 for words and phrases. */
    fun length(type: TdApi.AuthenticationCodeType): Int = when (type) {
        is TdApi.AuthenticationCodeTypeTelegramMessage -> type.length
        is TdApi.AuthenticationCodeTypeSms -> type.length
        is TdApi.AuthenticationCodeTypeCall -> type.length
        is TdApi.AuthenticationCodeTypeMissedCall -> type.length
        is TdApi.AuthenticationCodeTypeFragment -> type.length
        is TdApi.AuthenticationCodeTypeFirebaseAndroid -> type.length
        is TdApi.AuthenticationCodeTypeFirebaseIos -> type.length
        else -> 0
    }
}
