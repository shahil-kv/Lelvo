package app.lelvo.core.support

import kotlin.test.Test
import kotlin.test.assertEquals

/** The same cases as iOS `PhoneInputTests`. */
class PhoneInputTest {
    private val codes = listOf("91", "1", "44", "971")
    private val lengthsMap = mapOf("91" to 10..10, "1" to 10..10, "44" to 10..10, "971" to 9..9)
    private fun split(s: String, dial: String = "91") = PhoneInput.split(s, dial,
        { d -> codes.filter { d.startsWith(it) }.maxByOrNull { it.length } }, { lengthsMap[it] ?: 6..15 })

    @Test fun typedDigitsStayAsTheyAre() {
        assertEquals(PhoneInput.Split("91", "70123"), split("70123"))
        assertEquals(PhoneInput.Split("91", "7012345678"), split("7012345678"))
    }

    @Test fun plusNumberChangesTheCountry() {
        assertEquals(PhoneInput.Split("44", "7700900123"), split("+44 7700 900123"))
        assertEquals(PhoneInput.Split("91", "7012345678"), split("+91 70123 45678", "1"))
    }

    @Test fun doubleZeroIsInternational() = assertEquals(PhoneInput.Split("971", "501234567"), split("00971501234567"))

    @Test fun keyboardChipWithoutPlusDropsTheCountryCode() = assertEquals(PhoneInput.Split("91", "7012345678"), split("917012345678"))

    @Test fun trunkZeroIsDropped() {
        assertEquals(PhoneInput.Split("91", "7012345678"), split("07012345678"))
        assertEquals(PhoneInput.Split("44", "7700900123"), split("07700 900123", "44"))
    }

    @Test fun tooManyDigitsAreCut() = assertEquals(PhoneInput.Split("91", "7012345678"), split("70123456789999"))

    @Test fun nationalNumberThatHappensToStartWithTheCodeIsKept() = assertEquals(PhoneInput.Split("91", "9123456789"), split("9123456789"))
}
