import Foundation

/// Splits what lands in the phone field (typed, pasted, autofilled, or a keyboard's suggestion chip) into a calling
/// code and a national number. Keyboards and contact cards give the number in many shapes: "+91 70123 45678",
/// "0091…", "917012345678" with no plus, or "07012345678" with the trunk zero. Cutting those to the first N digits
/// gave a wrong number that Telegram then rejected.
public enum PhoneInput {
    public struct Split: Equatable, Sendable {
        public let dialCode: String
        public let national: String
        public init(dialCode: String, national: String) { self.dialCode = dialCode; self.national = national }
    }

    /// - Parameters:
    ///   - raw: the field's new text.
    ///   - dialCode: the calling code currently chosen.
    ///   - match: the longest known calling code that prefixes some digits, or nil.
    ///   - lengths: allowed national lengths for a calling code.
    public static func split(_ raw: String, dialCode: String,
                             match: (String) -> String?, lengths: (String) -> ClosedRange<Int>) -> Split {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        var digits = trimmed.filter { $0.isASCII && $0.isNumber }
        let range = lengths(dialCode)
        let international = trimmed.hasPrefix("+") || (digits.hasPrefix("00") && digits.count > range.upperBound)
        if international {
            if digits.hasPrefix("00") && !trimmed.hasPrefix("+") { digits.removeFirst(2) }
            if let code = match(digits) {
                return Split(dialCode: code, national: String(digits.dropFirst(code.count).prefix(lengths(code).upperBound)))
            }
        }
        if digits.count > range.upperBound {
            // The current country's code without a plus, as some keyboards' suggestion chips give it.
            if digits.hasPrefix(dialCode), range.contains(digits.count - dialCode.count) {
                return Split(dialCode: dialCode, national: String(digits.dropFirst(dialCode.count)))
            }
            // A national number written with its trunk zero.
            if digits.hasPrefix("0"), range.contains(digits.count - 1) {
                return Split(dialCode: dialCode, national: String(digits.dropFirst()))
            }
        }
        return Split(dialCode: dialCode, national: String(digits.prefix(range.upperBound)))
    }
}
