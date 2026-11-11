package app.lelvo.android.signin

import java.util.Locale

/** Calling codes and number lengths, the same table as `Countries` in the iOS OnboardingView. */
object Countries {
    data class Country(val region: String, val dialCode: String) {
        val name: String get() = Locale.Builder().setRegion(region).build().displayCountry
        val flag: String get() = region.uppercase().map { Character.toChars(127397 + it.code).concatToString() }.joinToString("")
    }

    // Region → calling code (shared codes like +1 and +7 resolve to the first listed region).
    private val codes = listOf(
        "IN" to "91", "US" to "1", "GB" to "44", "AE" to "971", "SA" to "966", "QA" to "974", "KW" to "965", "OM" to "968", "BH" to "973",
        "PK" to "92", "BD" to "880", "LK" to "94", "NP" to "977", "MV" to "960", "AF" to "93", "CA" to "1", "AU" to "61", "NZ" to "64",
        "DE" to "49", "FR" to "33", "IT" to "39", "ES" to "34", "PT" to "351", "NL" to "31", "BE" to "32", "CH" to "41", "AT" to "43",
        "IE" to "353", "SE" to "46", "NO" to "47", "DK" to "45", "FI" to "358", "PL" to "48", "CZ" to "420", "SK" to "421", "HU" to "36",
        "RO" to "40", "BG" to "359", "GR" to "30", "TR" to "90", "UA" to "380", "RU" to "7", "KZ" to "7", "BY" to "375", "RS" to "381",
        "HR" to "385", "SI" to "386", "LT" to "370", "LV" to "371", "EE" to "372", "IL" to "972", "JO" to "962", "LB" to "961", "IQ" to "964",
        "IR" to "98", "EG" to "20", "MA" to "212", "DZ" to "213", "TN" to "216", "NG" to "234", "GH" to "233", "KE" to "254", "ET" to "251",
        "TZ" to "255", "UG" to "256", "ZA" to "27", "CN" to "86", "HK" to "852", "TW" to "886", "JP" to "81", "KR" to "82", "SG" to "65",
        "MY" to "60", "ID" to "62", "TH" to "66", "VN" to "84", "PH" to "63", "MM" to "95", "KH" to "855", "UZ" to "998", "AZ" to "994",
        "GE" to "995", "AM" to "374", "BR" to "55", "AR" to "54", "MX" to "52", "CO" to "57", "CL" to "56", "PE" to "51", "VE" to "58",
        "EC" to "593", "UY" to "598", "PY" to "595", "BO" to "591", "CU" to "53", "DO" to "1", "JM" to "1", "PR" to "1",
    )

    val all: List<Country> by lazy { codes.map { Country(it.first, it.second) }.sortedBy { it.name } }

    fun byDialCode(code: String): Country? = codes.firstOrNull { it.second == code }?.let { Country(it.first, it.second) }

    /** Longest calling code that prefixes [digits] (for pasted "+91…" numbers). */
    fun matchPrefixOf(digits: String): Country? =
        codes.filter { digits.startsWith(it.second) }.maxByOrNull { it.second.length }?.let { Country(it.first, it.second) }

    /** National number lengths (without the country code) for common countries; others accept 6–15 digits. */
    private val nationalLengths: Map<String, IntRange> = mapOf(
        "91" to 10..10, "1" to 10..10, "44" to 10..10, "971" to 9..9, "966" to 9..9, "974" to 8..8, "965" to 8..8, "968" to 8..8,
        "973" to 8..8, "92" to 10..10, "880" to 10..10, "94" to 9..9, "977" to 10..10, "960" to 7..7, "61" to 9..9, "64" to 8..10,
        "49" to 10..11, "33" to 9..9, "39" to 9..10, "34" to 9..9, "351" to 9..9, "31" to 9..9, "32" to 9..9, "41" to 9..9,
        "353" to 9..9, "46" to 9..9, "47" to 8..8, "45" to 8..8, "48" to 9..9, "90" to 10..10, "380" to 9..9, "7" to 10..10,
        "972" to 9..9, "20" to 10..10, "234" to 10..10, "254" to 9..9, "27" to 9..9, "86" to 11..11, "81" to 10..10,
        "82" to 9..10, "65" to 8..8, "60" to 9..10, "62" to 9..12, "66" to 9..9, "84" to 9..10, "63" to 10..10, "55" to 10..11,
        "52" to 10..10, "54" to 10..10, "57" to 10..10,
    )

    fun lengths(dialCode: String): IntRange = nationalLengths[dialCode] ?: 6..15

    fun defaultDialCode(region: String?): String = codes.firstOrNull { it.first == region }?.second ?: "91"
}
