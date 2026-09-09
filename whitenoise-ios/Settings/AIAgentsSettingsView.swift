import SwiftUI
import UIKit
import MarmotKit

struct AIAgentsSettingsView: View {
    @Environment(AppState.self) private var appState

    private var npub: String? {
        guard let account = appState.activeAccount else { return nil }
        return NostrProfileReference.npub(fromAccountIdHex: account.accountIdHex)
    }

    var body: some View {
        Form {
            Section {
                Text("White Noise works with AI agents. Your agent runs on your own machine or server as a separate Marmot account; you chat with it here like any contact, end-to-end encrypted.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("About AI Agents")
            }

            Section {
                Text("These are installation prompts. Choose your agent, copy its prompt, and paste it into that agent to connect it to White Noise. The prompt includes your npub (a public key, not a secret) and asks the agent to explain how the connector works before requesting your approval to install it. Only use an agent you run and trust; your private key is never included.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(AIAgentConnector.allCases) { connector in
                    AIAgentConnectorRow(connector: connector, npub: npub) { prompt in
                        UIPasteboard.general.string = prompt
                        Haptics.selection()
                        appState.present(.success(L10n.string("Prompt copied — paste it into your agent.")))
                    }
                }
            } header: {
                Text("Connectors")
            }

            Section {
                Text(L10n.formatted(
                    "After the agent shares its npub, add it as a contact from %@ and start chatting. See the agent connector docs for full details.",
                    L10n.string("New Chat")
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)

                if let npub {
                    LabeledContent("npub") {
                        Button {
                            UIPasteboard.general.string = npub
                            Haptics.selection()
                            appState.present(.success(L10n.string("Copied")))
                        } label: {
                            HStack(spacing: 8) {
                                Text(npub)
                                    .font(.subheadline.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Image(systemName: "doc.on.doc")
                                    .font(.footnote)
                            }
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.formatted("Copy %@", L10n.string("npub")))
                    }
                    .accessibilityIdentifier("aiAgents.copyNpub")
                } else {
                    Text("No active account.")
                        .foregroundStyle(.secondary)
                }

                Link(destination: AIAgentConnector.documentationURL) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Agent connector documentation")
                            Text("Install scripts, health checks, and troubleshooting")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(.primary)
                }
                .accessibilityIdentifier("aiAgents.documentation")
            } header: {
                Text("Manual Setup")
            }
        }
        .localizedNavigationTitle("AI Agents")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("aiAgents.screen")
    }
}

private struct AIAgentConnectorRow: View {
    let connector: AIAgentConnector
    let npub: String?
    let onCopy: (String) -> Void
    @State private var isExpanded = false

    var body: some View {
        // Separate Form rows keep the header stationary as the prompt row animates.
        Group {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connector.name)
                                .font(.headline)
                            Text(connector.subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded
                    ? L10n.formatted("Hide %@ setup prompt", connector.name)
                    : L10n.formatted("Show %@ setup prompt", connector.name))
                .accessibilityIdentifier("aiAgents.\(connector.rawValue).toggle")

                Button {
                    if let npub { onCopy(connector.prompt(npub: npub)) }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .tint(.primary)
                .accessibilityLabel(L10n.formatted("Copy %@ setup prompt", connector.name))
                .accessibilityIdentifier("aiAgents.\(connector.rawValue).copy")
            }
            .disabled(npub == nil)
            .listRowSeparator(isExpanded && npub != nil ? .hidden : .visible)

            if isExpanded, let npub {
                Text(connector.prompt(npub: npub))
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .accessibilityIdentifier("aiAgents.\(connector.rawValue).prompt")
            }
        }
    }
}
