import Foundation
import MarmotKit
import UIKit

nonisolated struct ProductAnalyticsBuildConfig: Equatable, Sendable {
    var endpoint: String?
    var appKey: String?
    var operatorLabel: String
    var retentionDisclosure: String?
    var appVersion: String
    var osMajorVersion: String
    var deviceClass: String
    var environment: String
    var isDebug: Bool

    static func current(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> Self {
        func value(_ key: String) -> String? {
            guard let raw = info[key] as? String else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text.hasPrefix("$(") ? nil : text
        }
#if DEBUG
        let debug = true
#else
        let debug = false
#endif
        let environment = value("WhiteNoiseTelemetryEnvironment") ?? "development"
        return Self(
            endpoint: value("WhiteNoiseProductAnalyticsEndpoint"),
            appKey: value("WhiteNoiseProductAnalyticsAppKey"),
            operatorLabel: value("WhiteNoiseProductAnalyticsOperator") ?? "white_noise",
            retentionDisclosure: value("WhiteNoiseProductAnalyticsRetention"),
            appVersion: value("CFBundleShortVersionString") ?? "0",
            osMajorVersion: String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
            deviceClass: (TelemetryBuildConfig.current().deviceModelIdentifier?.hasPrefix("iPad") == true) ? "tablet" : "phone",
            environment: ["production", "staging", "development"].contains(environment) ? environment : "development",
            isDebug: debug
        )
    }

    var operatorDisplayName: String { operatorLabel == "white_noise" ? "White Noise" : operatorLabel }

    var runtimeConfig: ProductAnalyticsRuntimeConfigFfi {
        ProductAnalyticsRuntimeConfigFfi(
            eventsEndpoint: endpoint, appKey: appKey,
            metadata: ProductAnalyticsMetadataFfi(
                appVersion: appVersion, osFamily: "ios", osMajorVersion: osMajorVersion,
                deviceClass: deviceClass, hostSurface: "native", environment: environment, isDebug: isDebug
            ), registry: [], allowLoopback: false, operator: operatorLabel
        )
    }
}
