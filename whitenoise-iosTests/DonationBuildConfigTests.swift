import Foundation
import Testing
@testable import whitenoise_ios

struct DonationBuildConfigTests {
    @Test func routesOnlyTheProductionFlavorToApplePay() {
        let key = DonationBuildConfig.environmentKey
        #expect(DonationScreenRoute.current(infoDictionary: [key: "production"]) == .applePay)
        #expect(DonationScreenRoute.current(infoDictionary: [key: "staging"]) == .website)
        #expect(DonationScreenRoute.current(infoDictionary: [key: "unknown"]) == .unavailable)
        #expect(DonationScreenRoute.current(infoDictionary: [:]) == .unavailable)
        #expect(DonationScreenRoute.websiteURL.absoluteString == "https://ipf.dev/donate")
    }

    @Test func acceptsMatchingProductionAndStagingConfiguration() throws {
        let production = try #require(DonationBuildConfig.current(infoDictionary: info(
            environment: "production",
            serviceURL: "https://payments.ipf.dev"
        )))
        #expect(production.environment == .production)
        #expect(production.managementURL.absoluteString == "https://payments.ipf.dev/manage")

        let staging = try #require(DonationBuildConfig.current(infoDictionary: info(
            environment: "staging",
            serviceURL: "https://payments-staging.ipf.dev"
        )))
        #expect(staging.environment == .staging)
    }

    @Test(arguments: [
        ("production", "http://payments.ipf.dev", "merchant.dev.ipf.whitenoise"),
        ("production", "https://user@payments.ipf.dev", "merchant.dev.ipf.whitenoise"),
        ("production", "https://payments.ipf.dev?debug=1", "merchant.dev.ipf.whitenoise"),
        ("staging", "https://payments-staging.ipf.dev", "merchant invalid"),
        ("unknown", "https://payments.ipf.dev", "merchant.dev.ipf.whitenoise")
    ])
    func rejectsInvalidConfiguration(
        environment: String,
        serviceURL: String,
        merchant: String
    ) {
        #expect(DonationBuildConfig.current(infoDictionary: info(
            environment: environment,
            serviceURL: serviceURL,
            merchant: merchant
        )) == nil)
    }

    @Test func missingOrUnexpandedValuesFailClosed() {
        #expect(DonationBuildConfig.current(infoDictionary: [:]) == nil)
        #expect(DonationBuildConfig.current(infoDictionary: info(
            environment: "staging",
            serviceURL: ""
        )) == nil)
        #expect(DonationBuildConfig.current(infoDictionary: info(
            environment: "production",
            serviceURL: "$(WHITENOISE_DONATION_SERVICE_URL)"
        )) == nil)
    }

    @Test func validatesRuntimeStripeModeAndPublishableKeyPrefix() throws {
        let staging = try #require(DonationBuildConfig.current(infoDictionary: info(
            environment: "staging",
            serviceURL: "https://payments-staging.ipf.dev"
        )))

        #expect(staging.validates(DonationRuntimeConfig(
            stripePublishableKey: "pk_test_example",
            stripeMode: .test
        )))
        #expect(!staging.validates(DonationRuntimeConfig(
            stripePublishableKey: "pk_live_example",
            stripeMode: .live
        )))
        #expect(!staging.validates(DonationRuntimeConfig(
            stripePublishableKey: "pk_live_example",
            stripeMode: .test
        )))
    }

    private func info(
        environment: String,
        serviceURL: String,
        merchant: String = "merchant.dev.ipf.whitenoise"
    ) -> [String: Any] {
        [
            DonationBuildConfig.environmentKey: environment,
            DonationBuildConfig.serviceURLKey: serviceURL,
            DonationBuildConfig.merchantIdentifierKey: merchant
        ]
    }
}
