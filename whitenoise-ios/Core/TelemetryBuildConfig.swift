import Foundation
import MarmotKit

enum TelemetrySettingsActionError: LocalizedError {
    case telemetryNotConfigured

    var errorDescription: String? {
        switch self {
        case .telemetryNotConfigured:
            "Telemetry credentials are not configured for this build."
        }
    }
}

enum AuditLogActionError: LocalizedError {
    case runtimeNotReady

    var errorDescription: String? {
        switch self {
        case .runtimeNotReady:
            "The secure runtime isn't ready yet. Try again in a moment."
        }
    }
}

nonisolated struct TelemetryBuildConfig: Equatable, Sendable {
    static let defaultOtlpEndpoint = "https://otlp.whitenoise.chat/v1/metrics"
    static let defaultAuditOtlpEndpoint = "https://otlp.whitenoise.chat/v1/logs"
    /// Stable identity for MDK's v5 delivery cursor; keep it across token rotation.
    static let auditOtlpDestination = "whitenoise-audit-receiver"

    let otlpEndpoint: String
    let bearerToken: String?
    /// Write token for the v5 audit receiver at `auditOtlpEndpoint`.
    /// Deliberately separate from `bearerToken`: the audit receiver and the OTLP
    /// metrics collector are different services with different credentials, so
    /// reusing the OTLP token here would authenticate against the wrong API.
    let auditLogBearerToken: String?
    var auditOtlpEndpoint: String = Self.defaultAuditOtlpEndpoint
    let deploymentEnvironment: String
    let serviceVersion: String
    let osVersion: String
    let deviceModelIdentifier: String?

    var telemetryCredentialsAvailable: Bool {
        bearerToken != nil
    }

    static func current(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        processInfo: ProcessInfo = .processInfo,
        environment: [String: String]? = nil,
        osVersion: String? = nil,
        deviceModelIdentifier: String? = nil
    ) -> TelemetryBuildConfig {
        let info = infoDictionary ?? [:]
        let environment = environment ?? processInfo.environment
        let deploymentEnvironment = deploymentEnvironment(
            from: stringValue(
                for: "WhiteNoiseTelemetryEnvironment",
                in: info,
                environmentKeys: ["WHITENOISE_TELEMETRY_ENVIRONMENT"],
                environment: environment
            )
        )
        return TelemetryBuildConfig(
            otlpEndpoint: stringValue(
                for: "WhiteNoiseTelemetryOTLPEndpoint",
                in: info,
                environmentKeys: ["WHITENOISE_OTLP_ENDPOINT"],
                environment: environment
            ) ?? defaultOtlpEndpoint,
            bearerToken: stringValue(
                for: "WhiteNoiseTelemetryBearerToken",
                in: info,
                environmentKeys: ["WHITENOISE_OTLP_BEARER_TOKEN", "OTLP_TOKEN_WHITENOISE_IOS"],
                environment: environment
            ),
            auditLogBearerToken: stringValue(
                for: "WhiteNoiseAuditLogBearerToken",
                in: info,
                environmentKeys: [
                    "WHITENOISE_AUDIT_LOG_BEARER_TOKEN",
                    "AUDIT_LOG_TOKEN_WHITENOISE_IOS"
                ],
                environment: environment
            ),
            auditOtlpEndpoint: stringValue(
                for: "WhiteNoiseAuditOTLPEndpoint",
                in: info,
                environmentKeys: ["WHITENOISE_AUDIT_OTLP_ENDPOINT"],
                environment: environment
            ) ?? defaultAuditOtlpEndpoint,
            deploymentEnvironment: deploymentEnvironment,
            serviceVersion: serviceVersion(from: info),
            osVersion: osVersion ?? currentOSVersion(processInfo: processInfo),
            deviceModelIdentifier: deviceModelIdentifier ?? Self.deviceModelIdentifier(environment: environment)
        )
    }

    nonisolated private static func currentOSVersion(processInfo: ProcessInfo) -> String {
        let version = processInfo.operatingSystemVersion
        if version.patchVersion == 0 {
            return "\(version.majorVersion).\(version.minorVersion)"
        }
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    func runtimeConfig(installId: String) -> RelayTelemetryRuntimeConfigFfi {
        RelayTelemetryRuntimeConfigFfi(
            otlpEndpoint: otlpEndpoint,
            authorizationBearerToken: bearerToken,
            resource: RelayTelemetryResourceFfi(
                serviceVersion: serviceVersion,
                serviceInstanceId: installId,
                deploymentEnvironment: deploymentEnvironment,
                tenant: "whitenoise-ios",
                osType: "darwin",
                osVersion: osVersion,
                deviceModelIdentifier: deviceModelIdentifier
            )
        )
    }

    /// v5 OTLP delivery config. Without a token the sender is disabled and
    /// recordings stay local; recording itself is the separate user setting.
    func auditOtlpConfig() -> AuditOtlpConfigV5Ffi {
        guard let auditLogBearerToken else {
            return AuditOtlpConfigV5Ffi(enabled: false, destination: nil, endpoint: nil,
                                        authorizationBearerToken: nil, allowLoopbackDev: false)
        }
        return AuditOtlpConfigV5Ffi(
            enabled: true,
            destination: Self.auditOtlpDestination,
            endpoint: auditOtlpEndpoint,
            authorizationBearerToken: auditLogBearerToken,
            allowLoopbackDev: false
        )
    }

    /// The device source for v5 audit records, matching the telemetry resource.
    func auditLogSource() -> AuditLogSourceFfi {
        AuditLogSourceFfi(hardwareModel: deviceModelIdentifier, platform: AuditLogSourceBuildConfig.platform,
                          appVersion: serviceVersion)
    }

    nonisolated private static func stringValue(
        for key: String,
        in info: [String: Any],
        environmentKeys: [String] = [],
        environment: [String: String] = [:]
    ) -> String? {
        if let raw = info[key] as? String,
           let value = resolvedStringValue(raw) {
            return value
        }
        return environmentKeys.lazy
            .compactMap { environment[$0] }
            .compactMap(resolvedStringValue)
            .first
    }

    nonisolated private static func resolvedStringValue(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isUnresolvedBuildSetting(trimmed) else { return nil }
        return trimmed
    }

    nonisolated private static func deploymentEnvironment(from raw: String?) -> String {
        guard let environment = raw?.lowercased() else { return "staging" }
        switch environment {
        case "production", "staging", "development", "test":
            return environment
        default:
            return "staging"
        }
    }

    nonisolated private static func serviceVersion(from info: [String: Any]) -> String {
        AuditLogSourceBuildConfig.appVersion(from: info)
    }

    nonisolated private static func isUnresolvedBuildSetting(_ value: String) -> Bool {
        value.hasPrefix("$(") && value.hasSuffix(")")
    }

    nonisolated private static func deviceModelIdentifier(environment: [String: String]) -> String? {
        AuditLogSourceBuildConfig.deviceModelIdentifier(environment: environment)
    }
}
