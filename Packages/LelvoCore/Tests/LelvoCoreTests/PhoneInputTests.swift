import Foundation
import Testing
import LelvoCore

/// The same cases as Android `PhoneInputTest`.
@Suite struct PhoneInputTests {
    private let codes = ["91", "1", "44", "971"]
    private func match(_ d: String) -> String? { codes.filter { d.hasPrefix($0) }.max { $0.count < $1.count } }
    private func lengths(_ c: String) -> ClosedRange<Int> { ["91": 10...10, "1": 10...10, "44": 10...10, "971": 9...9][c] ?? 6...15 }
    private func split(_ s: String, _ dial: String = "91") -> PhoneInput.Split {
        PhoneInput.split(s, dialCode: dial, match: match, lengths: lengths)
    }

    @Test func typedDigitsStayAsTheyAre() {
        #expect(split("70123") == .init(dialCode: "91", national: "70123"))
        #expect(split("7012345678") == .init(dialCode: "91", national: "7012345678"))
    }

    @Test func plusNumberChangesTheCountry() {
        #expect(split("+44 7700 900123") == .init(dialCode: "44", national: "7700900123"))
        #expect(split("+91 70123 45678", "1") == .init(dialCode: "91", national: "7012345678"))
    }

    @Test func doubleZeroIsInternational() {
        #expect(split("00971501234567") == .init(dialCode: "971", national: "501234567"))
    }

    @Test func keyboardChipWithoutPlusDropsTheCountryCode() {
        // Samsung Keyboard and Gboard offer the SIM number as "917012345678".
        #expect(split("917012345678") == .init(dialCode: "91", national: "7012345678"))
    }

    @Test func trunkZeroIsDropped() {
        #expect(split("07012345678") == .init(dialCode: "91", national: "7012345678"))
        #expect(split("07700 900123", "44") == .init(dialCode: "44", national: "7700900123"))
    }

    @Test func tooManyDigitsAreCut() {
        #expect(split("70123456789999") == .init(dialCode: "91", national: "7012345678"))
    }

    @Test func nationalNumberThatHappensToStartWithTheCodeIsKept() {
        // Ten digits is already a full Indian number, even though it starts with 91.
        #expect(split("9123456789") == .init(dialCode: "91", national: "9123456789"))
    }
}
