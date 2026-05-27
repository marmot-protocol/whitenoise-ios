import Foundation

/// Compile-time gate that prevents the developer-mode toggle from disabling
/// TLS verification for the agent QUIC stream in release builds.
///
/// Developer mode is a user-facing Settings switch that points the stream
/// at a loopback broker with no real certificate. If a release build let
/// that switch turn off TLS verification, anyone who flips it — the user,
/// or an attacker who tricks them — would be exposed to a MitM on the
/// agent stream. Gating at compile time keeps the production path safe
/// while still letting developers exercise the loopback broker in DEBUG.
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
