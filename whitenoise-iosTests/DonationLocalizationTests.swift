import Foundation
import Testing

struct DonationLocalizationTests {
    @Test func donationCopyCoversEveryShippedLocale() throws {
        let keys = [
            "%@ will be donated each month until you cancel.",
            "A donation is already in progress.",
            "About your donation",
            "Amount",
            "Amount in USD",
            "Apple Pay donations aren't configured in this build.",
            "Apple Pay donations couldn't load. Please try again.",
            "Apple Pay isn't available for this donation.",
            "Apple Pay isn't available on this device.",
            "Apple Pay needs your name and email for monthly donations.",
            "Check for receipt",
            "Checking receipt…",
            "Choose an amount from $1 to $5,000 USD.",
            "Completing donation…",
            "Custom donation amount in USD",
            "Donation complete",
            "Enter a valid USD amount with no more than two decimal places.",
            "Frequency",
            "IPF General Fund Donation",
            "IPF is a 501(c)(3) nonprofit. No goods or services are provided in exchange for your donation.",
            "Manage monthly donation",
            "Monthly",
            "Monthly donation to IPF",
            "One time",
            "Open donation website",
            "Other ways to donate",
            "Tax deductibility depends on your circumstances. Please consult your tax advisor.",
            "The donation couldn't be completed. Please try again.",
            "The donation succeeded, but the receipt isn't available yet.",
            "The maximum donation is $5,000.",
            "The minimum donation is $1.",
            "Thank you for supporting IPF.",
            "Try again",
            "USD",
            "View receipt",
            "Your donation supports IPF's general fund, including White Noise.",
            "Your receipt is still being prepared.",
            "Your selected amount will be charged every month until you cancel."
        ]
        let locales = ["de", "es", "fr", "it", "pt", "ru", "tr", "zh-Hans", "zh-Hant"]
        let testFile = URL(fileURLWithPath: #filePath)
        let catalogURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])

        for key in keys {
            let entry = try #require(strings[key] as? [String: Any], "Missing localization key: \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for locale in locales {
                #expect(localizations[locale] != nil, "Missing \(locale) localization for \(key)")
            }
        }
    }
}
