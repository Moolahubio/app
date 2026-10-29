import Foundation
import Testing
@testable import Domain

@Suite("Money formatting")
struct MoneyFormattingTests {
    @Test func exactAlwaysShowsTwoDecimals() {
        #expect(Money(cents: 123_456).formatted() == "$1,234.56")
        #expect(Money(cents: 500_000).formatted(.exact) == "$5,000.00")
        #expect(Money(cents: 5).formatted() == "$0.05")
        #expect(Money.zero.formatted() == "$0.00")
    }

    @Test func wholeIfRoundDropsOnlyZeroCents() {
        #expect(Money(cents: 500_000).formatted(.wholeIfRound) == "$5,000")
        #expect(Money(cents: 500_050).formatted(.wholeIfRound) == "$5,000.50")
        #expect(Money(cents: 99).formatted(.wholeIfRound) == "$0.99")
    }

    @Test func negativeUsesUnicodeMinus() {
        #expect(Money(cents: -2_000).formatted() == "\u{2212}$20.00")
    }

    @Test func directionSigns() {
        #expect(Money(cents: 5_000).formatted(.exact, direction: .moneyIn) == "+$50.00")
        #expect(Money(cents: 2_000).formatted(.exact, direction: .moneyOut) == "\u{2212}$20.00")
        // The sign comes from the direction, the digits from the magnitude.
        #expect(Money(cents: -2_000).formatted(.exact, direction: .moneyOut) == "\u{2212}$20.00")
        #expect(Money.zero.formatted(.exact, direction: .moneyIn) == "$0.00")
    }

    @Test func formattingIgnoresTheDeviceRegion() {
        // Fixed en_US: never "US$" or "1.234,56 $".
        let text = Money(cents: 123_456).formatted()
        #expect(!text.contains("US$"))
        #expect(text.hasPrefix("$"))
    }

    @Test func largeAmountsStayExact() {
        #expect(Money(cents: 999_999_999).formatted() == "$9,999,999.99")
        #expect(Money(cents: 99_999_999_999_999).formatted() == "$999,999,999,999.99")
    }

    @Test func accessibilityUsesFullCurrencyName() {
        #expect(Money(cents: 124_050).accessibilityText() == "1,240.50 US dollars")
        #expect(Money(cents: 5_000).accessibilityText(direction: .moneyIn) == "plus 50.00 US dollars")
        #expect(Money(cents: 2_000).accessibilityText(direction: .moneyOut) == "minus 20.00 US dollars")
    }

    @Test func codableAsBareCents() throws {
        let data = try JSONEncoder().encode(Money(cents: 1_999))
        #expect(String(decoding: data, as: UTF8.self) == "1999")
        #expect(try JSONDecoder().decode(Money.self, from: Data("250".utf8)) == Money(cents: 250))
    }
}

/// Port of artifacts/moolahub-app/src/lib/amount.test.ts (same cases).
@Suite("Money.parse matches the web parser")
struct MoneyParsingTests {
    @Test func parsesDollarsAndCentsWithoutFloatDrift() {
        #expect(Money.parse("19.99")?.cents == 1999)
        #expect(Money.parse("0.29")?.cents == 29)
        #expect(Money.parse("1.1")?.cents == 110)
        #expect(Money.parse("0.07")?.cents == 7)
        #expect(Money.parse("4.35")?.cents == 435)
        #expect(Money.parse("1000")?.cents == 100_000)
        #expect(Money.parse("5.")?.cents == 500)
        #expect(Money.parse(".5")?.cents == 50)
        #expect(Money.parse("0")?.cents == 0)
    }

    @Test func acceptsLeadingDollarSpacesAndDecimalComma() {
        #expect(Money.parse("$12.50")?.cents == 1250)
        #expect(Money.parse(" 12.5 ")?.cents == 1250)
        #expect(Money.parse("12,5")?.cents == 1250)
        #expect(Money.parse("$ 7")?.cents == 700)
    }

    @Test(arguments: ["1.999", "0.001", "-1", "-0.5", "NaN", "abc", "", " ", ".", "1e3", "1,000", "1.2.3", "Infinity", "+5", "$", "١٢", "12.٥"])
    func rejectsJunk(_ input: String) {
        #expect(Money.parse(input) == nil)
    }

    @Test func rejectsAmountsTooLargeToStayExact() {
        #expect(Money.parse("1234567890123") == nil)
        #expect(Money.parse("999999999999.99")?.cents == 99_999_999_999_999)
    }

    @Test func formatsCentsBackIntoAnInputString() {
        #expect(Money(cents: 10_000).inputString == "100")
        #expect(Money(cents: 1999).inputString == "19.99")
        #expect(Money(cents: 1007).inputString == "10.07")
        #expect(Money(cents: 5).inputString == "0.05")
        #expect(Money(cents: 50).inputString == "0.50")
        #expect(Money(cents: -5).inputString == "0")
        #expect(Money.parse(Money(cents: 1007).inputString)?.cents == 1007)
    }
}

@Suite("Amount keypad buffer")
struct AmountEntryBufferTests {
    private func typed(_ keys: String) -> AmountEntryBuffer {
        var buffer = AmountEntryBuffer()
        for character in keys {
            switch character {
            case ".": buffer.press(.decimalPoint)
            case "<": buffer.press(.delete)
            default: buffer.press(.digit(character.wholeNumberValue!))
            }
        }
        return buffer
    }

    @Test func emptyShowsDollarZero() {
        let buffer = AmountEntryBuffer()
        #expect(buffer.displayText == "$0")
        #expect(buffer.money == nil)
    }

    @Test func displayKeepsTheTypedFraction() {
        #expect(typed("12.").displayText == "$12.")
        #expect(typed("1234.5").displayText == "$1,234.5")
        #expect(typed("1234.56").money?.cents == 123_456)
        #expect(typed("1234567").displayText == "$1,234,567")
    }

    @Test func leadingZeroIsReplaced() {
        #expect(typed("05").text == "5")
        #expect(typed("00").text == "0")
        #expect(typed("0.5").text == "0.5")
    }

    @Test func decimalOnEmptyGivesZeroPoint() {
        #expect(typed(".").text == "0.")
        #expect(typed(".5").money?.cents == 50)
    }

    @Test func rejectsExtraKeys() {
        var buffer = typed("1.25")
        let thirdDecimal = buffer.press(.digit(9))
        let secondPoint = buffer.press(.decimalPoint)
        #expect(thirdDecimal == false)
        #expect(secondPoint == false)
        #expect(buffer.text == "1.25")

        var long = typed("1234567")
        let eighthDigit = long.press(.digit(8))
        #expect(eighthDigit == false)
        #expect(long.text == "1234567")
        let point = long.press(.decimalPoint)
        let fraction = long.press(.digit(9))
        #expect(point && fraction)
        #expect(long.money?.cents == 123_456_790)
    }

    @Test func deleteAndClear() {
        var buffer = typed("12.3<")
        #expect(buffer.text == "12.")
        buffer.press(.delete)
        #expect(buffer.text == "12")
        buffer.clear()
        #expect(buffer.isEmpty)
        let deleteOnEmpty = buffer.press(.delete)
        #expect(deleteOnEmpty == false)
    }

    @Test func presetsReplaceTheBuffer() {
        var buffer = typed("99")
        buffer.set(Money(cents: 124_050))
        #expect(buffer.text == "1240.50")
        #expect(buffer.money?.cents == 124_050)
        buffer.set(Money(cents: 5_000))
        #expect(buffer.text == "50")
    }
}

@Suite("Fees and progress")
struct FeeAndProgressTests {
    @Test func feeFloorsLikeTheServer() {
        let rate = FeeRate(basisPoints: 200)
        #expect(rate.fee(on: Money(cents: 10_000)).cents == 200)
        #expect(rate.fee(on: Money(cents: 149)).cents == 2) // 2.98 → 2
        #expect(rate.fee(on: Money(cents: 49)).cents == 0)
        #expect(rate.net(of: Money(cents: 10_000)).cents == 9_800)
        #expect(FeeRate.none.fee(on: Money(cents: 10_000)) == .zero)
    }

    @Test func percentText() {
        #expect(FeeRate(basisPoints: 200).percentText == "2%")
        #expect(FeeRate(basisPoints: 150).percentText == "1.5%")
        #expect(FeeRate(basisPoints: 25).percentText == "0.25%")
        #expect(FeeRate(basisPoints: 10_000).percentText == "100%")
    }

    @Test func goalPercentFloorsAndClamps() {
        #expect(GoalProgress.percent(saved: Money(cents: 125_000), target: Money(cents: 300_000)) == 41)
        #expect(GoalProgress.percent(saved: Money(cents: 400_000), target: Money(cents: 300_000)) == 100)
        #expect(GoalProgress.percentText(saved: Money(cents: 1), target: Money(cents: 300_000)) == "<1%")
        #expect(GoalProgress.percentText(saved: .zero, target: Money(cents: 300_000)) == "0%")
        #expect(GoalProgress.fraction(saved: Money(cents: 150), target: Money(cents: 300)) == 0.5)
        #expect(GoalProgress.fraction(saved: Money(cents: 500), target: Money(cents: 300)) == 1)
    }
}
