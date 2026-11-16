import Foundation
import MarmotKit

/// The device source MDK stamps on v5 audit records. The app and the
/// Notification Service Extension each set it before opening any account,
/// because an open recorder keeps the source it started with.
nonisolated enum AuditLogSourceBuildConfig {
    static let platform = "ios"

    static func current(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AuditLogSourceFfi {
        AuditLogSourceFfi(
            hardwareModel: deviceModelIdentifier(environment: environment),
            platform: platform,
            appVersion: appVersion(from: infoDictionary ?? [:])
        )
    }

    /// `CFBundleShortVersionString+CFBundleVersion`, or the marketing version alone.
    static func appVersion(from info: [String: Any]) -> String {
        let version = resolvedString(info["CFBundleShortVersionString"]) ?? "unknown"
        guard let build = resolvedString(info["CFBundleVersion"]) else { return version }
        return "\(version)+\(build)"
    }

    /// The system model identifier (for example `iPhone17,3`), never a
    /// user-assigned device name.
    static func deviceModelIdentifier(environment: [String: String]) -> String? {
        if let simulatorModelIdentifier = resolvedString(environment["SIMULATOR_MODEL_IDENTIFIER"]) {
            return simulatorModelIdentifier
        }
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return nil }
        let bytes = Mirror(reflecting: systemInfo.machine).children.compactMap { $0.value as? Int8 }
        return machineIdentifier(fromMachineBytes: bytes)
    }

    /// Decodes the signed `CChar` bytes of `utsname.machine` into a Swift string.
    ///
    /// The bytes are `Int8`, so any byte ≥ 0x80 reads back as a negative value.
    /// `UInt8(_:)` traps on negative input, so the bits must be reinterpreted
    /// with `UInt8(bitPattern:)` instead. Trailing NUL padding is skipped.
    static func machineIdentifier(fromMachineBytes bytes: [Int8]) -> String? {
        let identifier = bytes.reduce(into: "") { result, byte in
            guard byte != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(bitPattern: byte))))
        }
        return identifier.isEmpty ? nil : identifier
    }

    private static func resolvedString(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !(trimmed.hasPrefix("$(") && trimmed.hasSuffix(")")) else { return nil }
        return trimmed
    }
}
