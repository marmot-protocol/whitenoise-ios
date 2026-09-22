import Foundation

nonisolated enum DonationCadence: String, Codable, CaseIterable, Hashable, Sendable {
    case oneTime = "one_time"
    case monthly
}

nonisolated enum DonationAmountSelection: Equatable, Hashable, Sendable {
    case preset(Int)
    case custom
}

nonisolated struct DonationDraft: Equatable, Sendable {
    let amountCents: Int
    let cadence: DonationCadence
}

nonisolated enum CustomDonationAmountValidation: Equatable, Sendable {
    case empty
    case invalid
    case belowMinimum
    case aboveMaximum
    case valid(Int)

    var amountCents: Int? {
        guard case let .valid(amountCents) = self else { return nil }
        return amountCents
    }
}

nonisolated enum DonatePresentation {
    static let presetAmountsCents = [1_000, 2_500, 5_000, 10_000]
    static let defaultAmountCents = 2_500
    static let minimumAmountCents = 100
    static let maximumAmountCents = 500_000

    static func validateCustomAmount(
        _ input: String,
        locale: Locale = .autoupdatingCurrent
    ) -> CustomDonationAmountValidation {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let cents = parseCents(trimmed, locale: locale) else { return .invalid }
        guard cents >= minimumAmountCents else { return .belowMinimum }
        guard cents <= maximumAmountCents else { return .aboveMaximum }
        return .valid(cents)
    }

    static func formattedAmount(
        cents: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = cents.isMultiple(of: 100) ? 0 : 2
        let amount = Decimal(cents) / 100
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "$\(amount)"
    }

    private static func parseCents(_ input: String, locale: Locale) -> Int? {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
        formatter.isLenient = false

        guard let number = formatter.number(from: input) else { return nil }
        var amount = number.decimalValue
        guard amount.isFinite, amount >= 0 else { return nil }

        var cents = Decimal()
        guard NSDecimalMultiplyByPowerOf10(&cents, &amount, 2, .plain) == .noError else {
            return nil
        }
        var roundedCents = Decimal()
        NSDecimalRound(&roundedCents, &cents, 0, .plain)
        guard cents == roundedCents else { return nil }

        let decimalNumber = NSDecimalNumber(decimal: roundedCents)
        let int64Value = decimalNumber.int64Value
        guard decimalNumber == NSDecimalNumber(value: int64Value),
              int64Value <= Int64(Int.max)
        else { return nil }
        return Int(int64Value)
    }
}
