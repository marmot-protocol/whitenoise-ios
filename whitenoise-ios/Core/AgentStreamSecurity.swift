import Foundation

/// Compile-time gate that stops the developer-mode Settings toggle from
/// disabling TLS verification for the agent QUIC stream in release builds.
/// Developer mode ships in production, so a runtime-only check would let
/// any user — or attacker who tricks them — MitM the agent stream (#10).
enum AgentStreamSecurity {

    /// Whether the current build is permitted to bypass TLS verification
    /// for a loopback agent broker. True only in DEBUG builds.
    static var buildAllowsInsecureLocal: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The effective `insecureLocal` value to pass to MarmotKit's
    /// `watchAgentTextStream`. Returns true only when the build permits it
    /// (DEBUG) and the user has explicitly enabled developer mode.
    static func insecureLocalEnabled(developerMode: Bool) -> Bool {
        return buildAllowsInsecureLocal && developerMode
    }
}
