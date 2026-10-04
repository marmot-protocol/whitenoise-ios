#if DEBUG
import MarmotKit
import SwiftUI

struct AccountRecoveryScenario: Identifiable {
    enum State: String, CaseIterable {
        case checking = "Getting ready to chat", pending = "Checks waiting", ready = "You’re ready to chat"
        case checkingSecureMessaging = "Checking secure messaging after profile skipped"
        case readyDisconnected = "Checks complete, but progress couldn’t load"
        case opening = "Opening Chats (tap Open Chats to hold progress)"
        case profileSkipped = "Profile skipped, device review required"
        case disconnected = "Progress couldn’t load", stopped = "Progress updates stopped"
        case openingFailed = "Opening Chats failed", cancellationFailed = "Closing setup failed"
        case profile = "Optional profile — review or skip", profileFailed = "Profile lookup failed — review or skip"
        case relays = "Required repair — fix to continue"
    }

    let state: State
    var title: String { state.rawValue }
    var id: String { state.rawValue }

    static let screens = State.allCases.map { Self(state: $0) }
}

struct AccountRecoveryScenarioLauncher: ViewModifier {
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                Button { isPresented = true } label: {
                    Label {
                        Text(verbatim: "Sign-in Checks Scenarios")
                    } icon: {
                        Image(systemName: "ladybug")
                    }
                    .font(.caption)
                    .frame(minHeight: 44)
                }
                .frame(maxWidth: .infinity)
                .background(.bar)
                .accessibilityIdentifier("debug.account-recovery-scenarios")
            }
            .fullScreenCover(isPresented: $isPresented) { AccountRecoveryScenarioBrowser() }
    }
}

private struct AccountRecoveryScenarioBrowser: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: AccountRecoveryScenario?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    rows(AccountRecoveryScenario.screens)
                } header: {
                    Text(verbatim: "Main screen states")
                } footer: {
                    Text(verbatim: "The sign-in checklist with sample progress, review, error, and ready states. Review and Continue opens the existing step screen. No account is created, changed, or signed out. Optional photo selection uses the normal photo tools.")
                }
            }
            .navigationTitle(Text(verbatim: "Sign-in Checks"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(item: $selected) { AccountRecoveryScenarioRunner(scenario: $0) }
        }
        .appAppearance()
    }

    private func rows(_ scenarios: [AccountRecoveryScenario]) -> some View {
        ForEach(scenarios) { scenario in
            Button { selected = scenario } label: {
                HStack {
                    Text(verbatim: scenario.title)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
        }
    }
}

private struct AccountRecoveryScenarioRunner: View {
    @Environment(\.dismiss) private var dismiss
    let scenario: AccountRecoveryScenario
    @State private var session: AccountRecoveryScenarioSession
    @State private var runID = UUID()

    init(scenario: AccountRecoveryScenario) {
        self.scenario = scenario
        _session = State(initialValue: AccountRecoveryScenarioSession(scenario: scenario))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    session.stop()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(Text(verbatim: "Close scenario"))
                VStack(alignment: .leading) {
                    Text(verbatim: scenario.title).font(.caption.bold())
                    Text(verbatim: "Sample data · Debug only").font(.caption2)
                }
                Spacer()
                if session.isHolding {
                    Button { session.isHolding = false } label: { Text(verbatim: "Continue") }
                }
                Button {
                    session.stop()
                    session = AccountRecoveryScenarioSession(scenario: scenario)
                    runID = UUID()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .accessibilityLabel(Text(verbatim: "Reset scenario"))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(8)
            .background(.bar)

            Group {
                if session.completed {
                    ContentUnavailableView {
                        Label { Text(verbatim: "Simulation complete") } icon: { Image(systemName: "checkmark.circle") }
                    } description: {
                        Text(verbatim: "Open Chats succeeded in the sample session. Reset to try again.")
                    }
                } else {
                    NavigationStack {
                        AccountSetupView(model: session.model, onClose: { dismiss() })
                    }
                }
            }
            .id(runID)
            .environment(\.accountSetupScenarioSession, session)
        }
        .appAppearance()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        .onDisappear { session.stop() }
    }
}
#endif
