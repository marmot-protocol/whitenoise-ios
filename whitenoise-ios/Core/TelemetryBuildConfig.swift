import Foundation
import MarmotKit
import UIKit

enum TelemetrySettingsActionError: LocalizedError {
    case telemetryNotConfigured

    var errorDescription: String? {
        switch self {
        case .telemetryNotConfigured:
            "Telemetry credentials are not configured for this build."
        }
    }
}

struct TelemetryBuildConfig: Equatable {
    static let defaultOtlpEndpoint = "https://otlp.ipf.dev/v1/metrics"

    let otlpEndpoint: String
    let bearerToken: String?
    /// Bearer token for the forensic audit-log tracker (Goggles) upload API.
    /// Deliberately separate from `bearerToken`: the audit tracker and the OTLP
    /// metrics collector are different services with different credentials, so
    /// reusing the OTLP token here would authenticate against the wrong API.
    let auditLogBearerToken: String?
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
        osVersion: String = UIDevice.current.systemVersion,
        deviceModelIdentifier: String? = nil
    ) -> TelemetryBuildConfig {
        let info = infoDictionary ?? [:]
        let environment = environment ?? processInfo.environment
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
                environmentKeys: [
                    "WHITENOISE_OTLP_BEARER_TOKEN",
                    "OTLP_TOKEN_WHITENOISE_IOS"
                ],
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
            deploymentEnvironment: deploymentEnvironment(
                from: stringValue(
                    for: "WhiteNoiseTelemetryEnvironment",
                    in: info,
                    environmentKeys: ["WHITENOISE_TELEMETRY_ENVIRONMENT"],
                    environment: environment
                )
            ),
            serviceVersion: serviceVersion(from: info),
            osVersion: osVersion,
            deviceModelIdentifier: deviceModelIdentifier ?? Self.deviceModelIdentifier(environment: environment)
        )
    }

    func runtimeConfig(installId: String) -> RelayTelemetryRuntimeConfigFfi {
        RelayTelemetryRuntimeConfigFfi(
            otlpEndpoint: otlpEndpoint,
            authorizationBearerToken: bearerToken,
            resource: RelayTelemetryResourceFfi(
                serviceVersion: serviceVersion,
                serviceInstanceId: installId,
                deploymentEnvironment: deploymentEnvironment,
                tenant: "WhiteNoise-ios",
                osType: "darwin",
                osVersion: osVersion,
                deviceModelIdentifier: deviceModelIdentifier
            )
        )
    }

    func auditTrackerConfig() -> AuditLogTrackerConfigFfi {
        AuditLogTrackerConfigFfi(
            endpoint: nil,
            authorizationBearerToken: auditLogBearerToken,
            source: AuditLogUploadSourceFfi(
                accountLabel: nil,
                deviceLabel: deviceModelIdentifier,
                platform: "ios",
                appVersion: serviceVersion
            )
        )
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
        let version = stringValue(for: "CFBundleShortVersionString", in: info) ?? "unknown"
        guard let build = stringValue(for: "CFBundleVersion", in: info) else {
            return version
        }
        return "\(version)+\(build)"
    }

    nonisolated private static func isUnresolvedBuildSetting(_ value: String) -> Bool {
        value.hasPrefix("$(") && value.hasSuffix(")")
    }

    nonisolated private static func deviceModelIdentifier(environment: [String: String]) -> String? {
        if let simulatorModelIdentifier = environment["SIMULATOR_MODEL_IDENTIFIER"].flatMap(resolvedStringValue) {
            return simulatorModelIdentifier
        }

        var systemInfo = utsname()
        uname(&systemInfo)
        let bytes = Mirror(reflecting: systemInfo.machine).children.compactMap { $0.value as? Int8 }
        return machineIdentifier(fromMachineBytes: bytes)
    }

    /// Decodes the signed `CChar` bytes of `utsname.machine` into a Swift string.
    ///
    /// The bytes are `Int8`, so any byte ≥ 0x80 reads back as a negative value.
    /// `UInt8(_:)` traps on negative input, so the bits must be reinterpreted
    /// with `UInt8(bitPattern:)` instead. Trailing NUL padding is skipped.
    nonisolated static func machineIdentifier(fromMachineBytes bytes: [Int8]) -> String? {
        let identifier = bytes.reduce(into: "") { result, byte in
            guard byte != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(bitPattern: byte))))
        }
        return identifier.isEmpty ? nil : identifier
    }
}
