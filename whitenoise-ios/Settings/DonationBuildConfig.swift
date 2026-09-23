import Foundation

nonisolated enum DonationScreenRoute: Equatable {
    case applePay
    case website
    case unavailable

    static let websiteURL = URL(string: "https://ipf.dev/donate")!

    static func current(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> Self {
        switch infoDictionary[DonationBuildConfig.environmentKey] as? String {
        case DonationBuildConfig.Environment.production.rawValue: .applePay
        case DonationBuildConfig.Environment.staging.rawValue: .website
        default: .unavailable
        }
    }
}

nonisolated struct DonationBuildConfig: Equatable, Sendable {
    enum Environment: String, Equatable, Sendable {
        case production
        case staging

        var stripeMode: DonationStripeMode {
            switch self {
            case .production: .live
            case .staging: .test
            }
        }

        var publishableKeyPrefix: String {
            switch self {
            case .production: "pk_live_"
            case .staging: "pk_test_"
            }
        }
    }

    static let environmentKey = "WhiteNoiseDonationEnvironment"
    static let serviceURLKey = "WhiteNoiseDonationServiceURL"
    static let merchantIdentifierKey = "WhiteNoiseApplePayMerchantIdentifier"

    let environment: Environment
    let serviceURL: URL
    let merchantIdentifier: String

    var managementURL: URL {
        serviceURL.appendingPathComponent("manage")
    }

    static func current(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> DonationBuildConfig? {
        func value(_ key: String) -> String? {
            guard let raw = infoDictionary[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
            return trimmed
        }

        guard let environmentRaw = value(environmentKey),
              let environment = Environment(rawValue: environmentRaw),
              let serviceURLRaw = value(serviceURLKey),
              let serviceURL = URL(string: serviceURLRaw),
              serviceURL.scheme?.lowercased() == "https",
              serviceURL.host?.isEmpty == false,
              serviceURL.user == nil,
              serviceURL.password == nil,
              serviceURL.query == nil,
              serviceURL.fragment == nil,
              let merchantIdentifier = value(merchantIdentifierKey),
              merchantIdentifier.hasPrefix("merchant."),
              !merchantIdentifier.contains(where: \.isWhitespace)
        else { return nil }

        return DonationBuildConfig(
            environment: environment,
            serviceURL: serviceURL,
            merchantIdentifier: merchantIdentifier
        )
    }

    func validates(_ runtimeConfig: DonationRuntimeConfig) -> Bool {
        runtimeConfig.stripeMode == environment.stripeMode
            && runtimeConfig.stripePublishableKey.hasPrefix(environment.publishableKeyPrefix)
    }
}
