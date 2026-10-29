import Foundation

/// The text behind the custom amount keypad (DESIGN.md §4.12).
///
/// USD only; the decimal separator is always "." whatever the region. Rules:
/// - digits only, at most one ".", at most 2 digits after it, at most 7 before;
/// - a leading "0" followed by a digit is replaced ("0" then "5" → "5");
/// - "." on an empty buffer gives "0.";
/// - delete removes the last character; `clear()` empties the buffer.
/// A rejected key leaves the buffer unchanged and `press(_:)` returns false
/// (the view plays the `.warning` haptic). No floating point at any step.
public struct AmountEntryBuffer: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        case digit(Int)
        case decimalPoint
        case delete
    }

    public static let maxWholeDigits = 7
    public static let maxFractionDigits = 2

    public private(set) var text: String

    public init(text: String = "") {
        self.text = ""
        for character in text {
            if character == "." {
                press(.decimalPoint)
            } else if let digit = character.wholeNumberValue, character.isASCIIDigit {
                press(.digit(digit))
            }
        }
    }

    public init(money: Money) {
        self.init(text: money.inputString)
    }

    public var isEmpty: Bool { text.isEmpty }

    private var hasDecimalPoint: Bool { text.contains(".") }

    private var wholePart: Substring {
        text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    }

    private var fractionPart: Substring? {
        guard let dot = text.firstIndex(of: ".") else { return nil }
        return text[text.index(after: dot)...]
    }

    /// Applies a key. Returns false when the key was rejected.
    @discardableResult
    public mutating func press(_ key: Key) -> Bool {
        switch key {
        case .digit(let digit):
            guard (0...9).contains(digit) else { return false }
            if let fractionPart {
                guard fractionPart.count < Self.maxFractionDigits else { return false }
                text.append(String(digit))
                return true
            }
            if text == "0" {
                text = String(digit)
                return true
            }
            guard wholePart.count < Self.maxWholeDigits else { return false }
            text.append(String(digit))
            return true
        case .decimalPoint:
            guard !hasDecimalPoint else { return false }
            text = text.isEmpty ? "0." : text + "."
            return true
        case .delete:
            guard !text.isEmpty else { return false }
            text.removeLast()
            return true
        }
    }

    public mutating func clear() {
        text = ""
    }

    /// Replaces the buffer with an exact amount (preset chips, "All").
    public mutating func set(_ money: Money) {
        self = AmountEntryBuffer(money: money)
    }

    /// The amount in cents, or nil when nothing has been typed.
    /// Cents = whole × 100 + fraction padded to two digits.
    public var money: Money? {
        guard !text.isEmpty else { return nil }
        return Money.parse(text)
    }

    /// What the display shows: "$0" when empty, otherwise "$" + the grouped
    /// whole part + the fraction exactly as typed ("12." → "$12.",
    /// "1234.5" → "$1,234.5").
    public var displayText: String {
        guard !text.isEmpty else { return "$0" }
        var result = "$" + Self.grouped(String(wholePart.isEmpty ? "0" : wholePart))
        if let fractionPart {
            result += "." + fractionPart
        }
        return result
    }

    private static func grouped(_ digits: String) -> String {
        var output: [Character] = []
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0 && offset % 3 == 0 { output.append(",") }
            output.append(character)
        }
        return String(output.reversed())
    }
}
