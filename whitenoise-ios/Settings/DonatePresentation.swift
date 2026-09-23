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
    case tooPrecise
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
        guard let parts = numericParts(trimmed, locale: locale) else { return .invalid }
        guard parts.fraction.count <= 2 else { return .tooPrecise }
        guard let cents = parseCents(parts) else { return .invalid }
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

    private static func parseCents(_ parts: (whole: String, fraction: String)) -> Int? {
        let whole = parts.whole.isEmpty ? "0" : parts.whole
        guard let dollars = Int(whole), dollars <= (Int.max - 99) / 100 else { return nil }
        let cents = Int(parts.fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        return dollars * 100 + cents
    }

    private static func numericParts(_ input: String, locale: Locale) -> (whole: String, fraction: String)? {
        let parts = input.components(separatedBy: locale.decimalSeparator ?? ".")
        guard parts.count <= 2 else { return nil }
        func digits(_ value: String) -> String? {
            var result = ""
            for character in value {
                guard character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .decimalNumber }),
                      let digit = character.wholeNumberValue else { return nil }
                result.append(String(digit))
            }
            return result
        }
        guard let whole = digits(parts[0]),
              let fraction = digits(parts.count == 2 ? parts[1] : ""),
              !whole.isEmpty || !fraction.isEmpty else { return nil }
        return (whole, fraction)
    }

    static func amountEdit(
        current: String, range: NSRange, replacement: String, isPaste: Bool,
        locale: Locale = .autoupdatingCurrent
    ) -> DonationAmountEdit {
        guard let swiftRange = Range(range, in: current) else { return .reject(nil) }
        let proposed = current.replacingCharacters(in: swiftRange, with: replacement)
        let candidate = isPaste ? proposed.trimmingCharacters(in: .whitespacesAndNewlines) : proposed
        if candidate.isEmpty || candidate == (locale.decimalSeparator ?? ".") { return .accept(candidate) }
        let validation = validateCustomAmount(candidate, locale: locale)
        switch validation {
        case .tooPrecise, .invalid:
            return .reject(isPaste || replacement.count > 1 ? validation : nil)
        default:
            return .accept(candidate)
        }
    }
}

nonisolated enum DonationAmountEdit: Equatable, Sendable {
    case accept(String)
    case reject(CustomDonationAmountValidation?)
}
