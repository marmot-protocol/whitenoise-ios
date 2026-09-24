import Foundation
import Testing
@testable import whitenoise_ios

struct DonationAmountInputTests {
    @Test(arguments: ["en_US", "de_DE", "fr_FR", "ar_EG"])
    func typedThirdDecimalIsRejectedWithoutRounding(_ identifier: String) {
        let locale = Locale(identifier: identifier)
        let separator = locale.decimalSeparator ?? "."
        let current = "10\(separator)25"
        #expect(DonatePresentation.amountEdit(
            current: current, range: NSRange(location: (current as NSString).length, length: 0),
            replacement: "9", isPaste: false, locale: locale
        ) == .reject(nil))
        #expect(DonatePresentation.validateCustomAmount(current, locale: locale) == .valid(1_025))
    }

    @Test func invalidPasteReportsPrecisionAndNeverRounds() {
        let locale = Locale(identifier: "en_US")
        for text in ["10.001", "10.999", "10.000"] {
            #expect(DonatePresentation.amountEdit(
                current: "25", range: NSRange(location: 0, length: 2),
                replacement: text, isPaste: true, locale: locale
            ) == .reject(.tooPrecise))
        }
        #expect(DonatePresentation.amountEdit(
            current: "10.25", range: NSRange(location: 5, length: 0),
            replacement: "9", isPaste: true, locale: locale
        ) == .reject(.tooPrecise))
    }

    @Test func permitsCaretEditsDeletionAndWholePartGrowth() {
        let locale = Locale(identifier: "en_US")
        #expect(DonatePresentation.amountEdit(current: "10.25", range: NSRange(location: 3, length: 1), replacement: "9", isPaste: false, locale: locale) == .accept("10.95"))
        #expect(DonatePresentation.amountEdit(current: "10.25", range: NSRange(location: 5, length: 0), replacement: "", isPaste: false, locale: locale) == .accept("10.25"))
        #expect(DonatePresentation.amountEdit(current: "10.25", range: NSRange(location: 4, length: 1), replacement: "", isPaste: false, locale: locale) == .accept("10.2"))
        #expect(DonatePresentation.amountEdit(current: "10.25", range: NSRange(location: 0, length: 0), replacement: "1", isPaste: false, locale: locale) == .accept("110.25"))
        #expect(DonatePresentation.amountEdit(current: "10.25", range: NSRange(location: 0, length: 5), replacement: "", isPaste: false, locale: locale) == .accept(""))
    }

    @Test func acceptsLocalizedDigitsAndRejectsPartialNumberParsing() {
        #expect(DonatePresentation.validateCustomAmount("١٠٫٢٥", locale: Locale(identifier: "ar_EG")) == .valid(1_025))
        let locale = Locale(identifier: "en_US")
        for text in ["10.25oops", "10.2.5", "1e3", "10,001", "-25"] {
            #expect(DonatePresentation.validateCustomAmount(text, locale: locale) == .invalid)
        }
        #expect(DonatePresentation.validateCustomAmount("5000.01", locale: locale) == .aboveMaximum)
        #expect(DonatePresentation.validateCustomAmount("0.99", locale: locale) == .belowMinimum)
    }

    @Test func acceptsValidPasteAndIncompleteDecimalEditing() {
        let locale = Locale(identifier: "de_DE")
        #expect(DonatePresentation.amountEdit(current: "", range: NSRange(location: 0, length: 0), replacement: " 10,25 ", isPaste: true, locale: locale) == .accept("10,25"))
        #expect(DonatePresentation.amountEdit(current: "", range: NSRange(location: 0, length: 0), replacement: ",", isPaste: false, locale: locale) == .accept(","))
        #expect(DonatePresentation.amountEdit(current: "10", range: NSRange(location: 2, length: 0), replacement: ",", isPaste: false, locale: locale) == .accept("10,"))
    }
}
