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

struct TelemetryBuildConfig: Equatable {
    static let defaultOtlpEndpoint = "https://otlp.ipf.dev/v1/metrics"
    static let defaultAuditUploadEndpoint = "https://goggles.ipf.dev/audits"

    let otlpEndpoint: String
    let bearerToken: String?
    let deploymentEnvironment: String
    let auditUploadEndpoint: String
    let serviceVersion: String
    let osVersion: String
    let deviceModelIdentifier: String?

    var telemetryCredentialsAvailable: Bool {
        bearerToken != nil
    }

    static func current(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        processInfo: ProcessInfo = .processInfo
    ) -> TelemetryBuildConfig {
        let info = infoDictionary ?? [:]
        return TelemetryBuildConfig(
            otlpEndpoint: stringValue(
                for: "DarkmatterTelemetryOTLPEndpoint",
                in: info
            ) ?? defaultOtlpEndpoint,
            bearerToken: stringValue(
                for: "DarkmatterTelemetryBearerToken",
                in: info
            ),
            deploymentEnvironment: deploymentEnvironment(
                from: stringValue(for: "DarkmatterTelemetryEnvironment", in: info)
            ),
            auditUploadEndpoint: stringValue(
                for: "DarkmatterAuditUploadEndpoint",
                in: info
            ) ?? defaultAuditUploadEndpoint,
            serviceVersion: serviceVersion(from: info),
            osVersion: processInfo.operatingSystemVersionString,
            deviceModelIdentifier: deviceModelIdentifier()
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
                osType: "ios",
                osVersion: osVersion,
                deviceModelIdentifier: deviceModelIdentifier
            )
        )
    }

    func auditTrackerConfig() -> AuditLogTrackerConfigFfi {
        AuditLogTrackerConfigFfi(
            endpoint: auditUploadEndpoint,
            authorizationBearerToken: bearerToken,
            source: AuditLogUploadSourceFfi(
                accountLabel: nil,
                deviceLabel: deviceModelIdentifier,
                platform: "ios",
                appVersion: serviceVersion
            )
        )
    }

    private static func stringValue(for key: String, in info: [String: Any]) -> String? {
        guard let raw = info[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isUnresolvedBuildSetting(trimmed) else { return nil }
        return trimmed
    }

    private static func deploymentEnvironment(from raw: String?) -> String {
        switch raw?.lowercased() {
        case "production":
            "production"
        default:
            "staging"
        }
    }

    private static func serviceVersion(from info: [String: Any]) -> String {
        let version = stringValue(for: "CFBundleShortVersionString", in: info) ?? "unknown"
        guard let build = stringValue(for: "CFBundleVersion", in: info) else {
            return version
        }
        return "\(version)+\(build)"
    }

    private static func isUnresolvedBuildSetting(_ value: String) -> Bool {
        value.hasPrefix("$(") && value.hasSuffix(")")
    }

    private static func deviceModelIdentifier() -> String? {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? nil : identifier
    }
}
