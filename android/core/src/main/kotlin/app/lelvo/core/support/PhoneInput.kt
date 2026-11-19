package app.lelvo.core.support

/**
 * Splits what lands in the phone field (typed, pasted, autofilled, or a keyboard's suggestion chip) into a calling
 * code and a national number. Same rules as iOS `PhoneInput`: keyboards give "+91 …", "0091…", "917012345678" with
 * no plus, or "07012345678" with the trunk zero, and cutting those to the first N digits gave a wrong number.
 */
object PhoneInput {
    data class Split(val dialCode: String, val national: String)

    fun split(raw: String, dialCode: String, match: (String) -> String?, lengths: (String) -> IntRange): Split {
        val trimmed = raw.trim()
        var digits = trimmed.filter { it in '0'..'9' }
        val range = lengths(dialCode)
        val international = trimmed.startsWith("+") || (digits.startsWith("00") && digits.length > range.last)
        if (international) {
            if (digits.startsWith("00") && !trimmed.startsWith("+")) digits = digits.drop(2)
            match(digits)?.let { code -> return Split(code, digits.drop(code.length).take(lengths(code).last)) }
        }
        if (digits.length > range.last) {
            // The current country's code without a plus, as some keyboards' suggestion chips give it.
            if (digits.startsWith(dialCode) && (digits.length - dialCode.length) in range) return Split(dialCode, digits.drop(dialCode.length))
            // A national number written with its trunk zero.
            if (digits.startsWith("0") && (digits.length - 1) in range) return Split(dialCode, digits.drop(1))
        }
        return Split(dialCode, digits.take(range.last))
    }
}
