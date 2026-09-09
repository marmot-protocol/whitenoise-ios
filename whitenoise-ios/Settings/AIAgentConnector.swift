import Foundation

enum AIAgentConnector: String, CaseIterable, Identifiable {
    case hermes
    case openclaw
    case opencode
    case codex

    var id: Self { self }

    var name: String {
        switch self {
        case .hermes: L10n.string("Hermes")
        case .openclaw: L10n.string("OpenClaw")
        case .opencode: L10n.string("OpenCode")
        case .codex: L10n.string("Codex")
        }
    }

    var subtitle: String {
        switch self {
        case .hermes: L10n.string("Terminal agent by Nous Research")
        case .openclaw: L10n.string("Self-hosted personal AI assistant")
        case .opencode: L10n.string("Open-source coding agent")
        case .codex: L10n.string("OpenAI Codex CLI coding agent")
        }
    }

    func prompt(npub: String) -> String {
        switch self {
        case .hermes:
            L10n.formatted(
                "This is an installation prompt for connecting this Hermes installation to White Noise through Marmot. Read the latest connector guide at https://github.com/marmot-protocol/mdk/blob/master/crates/agent-connector/README.md. Explain to me how the connector works and what the installation will change. Then propose the installation steps for my public npub: %@, and ask for my approval before making any changes. Once I approve, install and verify the connector, then reply with your agent npub.",
                npub
            )
        case .openclaw:
            L10n.formatted(
                "This is an installation prompt for connecting this OpenClaw instance to White Noise through Marmot. Read the latest connector guide at https://github.com/marmot-protocol/mdk/blob/master/crates/agent-connector/README.md. Explain to me how the connector works and what the installation will change. Then propose the installation steps for my public npub: %@, and ask for my approval before making any changes. Once I approve, install and verify the connector, then reply with your agent npub.",
                npub
            )
        case .opencode:
            L10n.formatted(
                "This is an installation prompt for connecting this OpenCode setup to White Noise through Marmot. Read the latest connector guide at https://github.com/marmot-protocol/mdk/blob/master/crates/agent-connector/README.md. Explain to me how the connector works and what the installation will change. Then propose the installation steps for my public npub: %@, and ask for my approval before making any changes. Once I approve, install and verify the connector, then reply with your agent npub.",
                npub
            )
        case .codex:
            L10n.formatted(
                "This is an installation prompt for connecting this Codex setup to White Noise through Marmot. Read the authoritative Codex harness guide at https://github.com/marmot-protocol/mdk/blob/master/integrations/codex/marmot/README.md and the evergreen connector guide at https://github.com/marmot-protocol/mdk/blob/master/crates/agent-connector/README.md. Explain to me how the connector works and what the installation will change. Confirm prerequisites: Codex CLI is installed, authenticated, and available on PATH, and this machine uses the same public relay set as my phone. Then propose the installation steps for my public npub: %@, and ask for my approval before making any changes. Once I approve, use the checksum-verified install-codex-marmot.sh release flow, bootstrap wn-agent for that npub with the allowed welcomer, and verify wn-codex --version. Then reply with your agent npub and ask me to invite it from White Noise and send a test message from this allowed npub over the configured relays. Do not report setup complete until wn-codex returns a reply through White Noise; if that round trip cannot be verified automatically, clearly mark device verification required.",
                npub
            )
        }
    }

    static let documentationURL = URL(
        string: "https://github.com/marmot-protocol/mdk/blob/master/crates/agent-connector/README.md"
    )!
}
