import Foundation
import Testing

struct DonationLocalizationTests {
    @Test func donationCopyCoversEveryShippedLocale() throws {
        let keys = [
            "You’re donating %@ each month to help people communicate freely and privately.",
            "Your monthly payment couldn’t be completed. Please check your payment method to continue your support.",
            "Your monthly donation is scheduled to end. Your support has helped us build tools for private communication.",
            "Payments stop on %@",
            "Donations are temporarily unavailable. Please try again later.",
            "Use up to two decimal places.",
            "Enter a valid USD amount.",
            "Thank you for your commitment",
            "By giving monthly, you help IPF keep building White Noise and tools for free, private communication.",
            "Payments",
            "Invoice",
            "Your recent payments:",
            "See all payments",
            "Invoice unavailable",
            "Your invoice is still being prepared.",
            "Your payment succeeded. Please try again later to view the invoice.",
            "Thank you for supporting IPF and White Noise. You’re helping people communicate freely and privately.",
            "Help the Internet Privacy Foundation (IPF), a nonprofit building tools for private communication.",
            "IPF is a nonprofit that builds tools to help people communicate privately. We develop White Noise and Marmot, the open messaging protocol behind it. Your donation supports this work and our belief that private conversations should be available to everyone.",
            "Charged monthly until you cancel.",
            "Monthly donation active",
            "Cancellation scheduled",
            "Monthly donation overdue",
            "Next payment: %@",
            "Thank you for your support",
            "%@ will be donated each month until you cancel.",
            "A donation is already in progress.",
            "About your donation",
            "Apple Pay isn't available for this donation.",
            "Apple Pay unavailable",
            "Custom donation amount in USD",
            "Custom amount",
            "Frequency",
            "IPF General Fund Donation",
            "Manage monthly donation",
            "Monthly",
            "Monthly donation to IPF",
            "One time",
            "The donation couldn't be completed. Please try again.",
            "The maximum donation is $5,000.",
            "The minimum donation is $1.",
            "USD",
            "Donation history access is no longer available on this device.",
            "Your donation history couldn't be loaded. Please try again.",
            "Other ways to donate",
            "Recent billing activity",
            "Your monthly donation has not started yet. Check your payment method to complete it.",
            "This monthly donation has ended.",
            "This monthly donation's status is unavailable. Check Stripe to manage it.",
            "Ended on %@",
            "Monthly donation not yet active",
            "Monthly donation ended",
            "Monthly donation status unavailable",
            "Load more",
            "Paid",
            "Pending",
            "Payment failed",
            "Credited",
            "Paid outside the app",
            "See all billing activity",
            "This document isn't available right now. Please try again later.",
            "More billing activity couldn't be loaded. Try again.",
            "A new donation won't restore earlier payments.",
            "Your donation succeeded, but history couldn't be saved on this device.",
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
