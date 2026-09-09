import Foundation
import Testing
@testable import whitenoise_ios

struct DonatePresentationTests {
    @Test func lightningAddressMatchesPublishedFundingValue() {
        #expect(DonatePresentation.lightning.address == "whitenoise@donate.ipf.dev")
    }

    @Test func silentPaymentAddressMatchesPublishedFundingValue() {
        // Spelled with a different split point than the production constant so
        // a copy-paste slip in either spot fails the comparison.
        let expected = "sp1qqvp56mxcj9pz9xudvlch5g4ah5hrc8rj6neu25p34rc9gxhp38cwqqlmld28u57w2srgckr34dkyg3"
            + "q02phu8tm05cyj483q026xedp0s5f5j40p"
        #expect(DonatePresentation.bitcoinSilentPayment.address == expected)
    }

    @Test func methodsListLightningFirst() {
        #expect(DonatePresentation.methods.map(\.id) == ["lightning", "bitcoin-silent-payment"])
    }

    @Test func lightningDisplayAddressShowsInFull() {
        #expect(DonatePresentation.lightning.displayAddress == "whitenoise@donate.ipf.dev")
    }

    @Test func silentPaymentDisplayAddressTruncatesTheMiddle() {
        #expect(DonatePresentation.bitcoinSilentPayment.displayAddress == "sp1qqvp56mxcj9pz9x…edp0s5f5j40p")
    }

    @Test func qrPayloadsCarryTheFullBareAddress() {
        for method in DonatePresentation.methods {
            #expect(method.qrPayload == method.address)
        }
    }

    @Test func qrCardSpansMostOfTheListWidth() {
        #expect(DonatePresentation.qrCardWidth(forContainerWidth: 393) == 393 * 0.81)
        #expect(DonatePresentation.qrCardWidth(forContainerWidth: 320) == 320 * 0.81)
    }

    @Test func qrCardIsLargerThanTheFixedSizeItReplaced() {
        // 204 was the previous fixed card width (180 image + 12 padding a side).
        #expect(DonatePresentation.qrCardWidth(forContainerWidth: 320) > 204)
    }

    @Test func addressChipSitsInsideTheQRCardEdge() {
        let container: CGFloat = 393
        let card = DonatePresentation.qrCardWidth(forContainerWidth: container)
        #expect(DonatePresentation.addressChipWidth(forContainerWidth: container) == card - 16)
    }

    @Test func degenerateContainerWidthsStayNonNegative() {
        #expect(DonatePresentation.qrCardWidth(forContainerWidth: 0) == 0)
        #expect(DonatePresentation.qrCardWidth(forContainerWidth: -100) == 0)
        #expect(DonatePresentation.addressChipWidth(forContainerWidth: 0) == 0)
        #expect(DonatePresentation.addressChipWidth(forContainerWidth: 10) == 0)
    }

    @Test func donateCatalogKeysCoverAllShippedLocales() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("Shared/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])

        let keys = [
            "Donate",
            "White Noise is free and open source. Donations keep it that way.",
            "Lightning address",
            "Bitcoin silent payment"
        ]
        let locales = ["de", "es", "fr", "it", "pt", "ru", "tr", "zh-Hans", "zh-Hant"]
        for key in keys {
            let entry = try #require(strings[key] as? [String: Any], "Missing localization key: \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for locale in locales {
                #expect(localizations[locale] != nil, "Missing \(locale) localization for \(key)")
            }
        }
    }
}
