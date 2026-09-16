import SwiftUI
import MarmotKit

/// Screen-scoped state for the destructive Sign Out & Wipe flow, and the box
/// for its argument-taking async teardown. A SwiftUI view struct must never
/// store an `(AppState) async -> Void` closure directly, so the trigger lives
/// on this `@MainActor final class` and views call a plain synchronous method.
@MainActor
@Observable
final class SignOutAndWipeModel {
    enum Stage: Equatable {
        case confirming
        case wiping
    }

    var isPresented = false
    private(set) var stage: Stage = .confirming
    var confirmInput = ""

    /// The literal the user must type to arm the destructive button.
    let keyword: String

    init(keyword: String = L10n.string("WIPE")) {
        self.keyword = keyword
    }

    var isConfirmed: Bool { WipeConfirmation.isConfirmed(confirmInput, keyword: keyword) }

    func present() {
        confirmInput = ""
        stage = .confirming
        isPresented = true
    }

    func cancel() {
        guard stage == .confirming else { return }
        isPresented = false
        confirmInput = ""
    }

    /// Runs the destructive teardown. Flips to the non-cancellable progress
    /// stage, awaits the wipe, then dismisses the cover — unless the wipe
    /// already popped this screen by routing to onboarding / switching accounts,
    /// in which case this state is torn down with the screen.
    func confirmWipe(using appState: AppState) {
        guard stage == .confirming, isConfirmed else { return }
        stage = .wiping
        Task { @MainActor in
            await appState.signOutAndWipeActiveAccount()
            isPresented = false
            stage = .confirming
            confirmInput = ""
        }
    }
}

/// Full-screen destructive flow: a type-to-confirm gate that lists exactly what
/// gets destroyed, then a non-cancellable staged progress display while the
/// engine's single `signOutAndWipe` call runs.
struct SignOutAndWipeCover: View {
    @Bindable var model: SignOutAndWipeModel
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Group {
            switch model.stage {
            case .confirming:
                confirmation
            case .wiping:
                WipeProgressView()
            }
        }
        .interactiveDismissDisabled(true)
    }

    private var confirmation: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This permanently removes this profile from this device.")
                }

                Section {
                    WipeBullet("The local message database and MLS group state for this profile.")
                    WipeBullet("This profile's key material stored on this device.")
                    WipeBullet("Outstanding key packages published for this profile on relays.")
                } header: {
                    Text("What gets destroyed")
                } footer: {
                    Text("Signing back in with the same key keeps your identity, but past groups, messages, and media can't be recovered on this device. You'll need to be re-invited to any groups.")
                        .font(.footnote)
                }

                Section {
                    Text(L10n.formatted("Type %@ to confirm.", model.keyword))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    WNInput(
                        placeholder: model.keyword,
                        text: $model.confirmInput,
                        submitLabel: .done,
                        autocapitalization: .characters
                    )
                    .font(.body.monospaced())
                    Button(role: .destructive, action: onConfirm) {
                        Text("Sign Out & Wipe")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(.red)
                    .listRowBackground(Color.clear)
                    .disabled(!model.isConfirmed)
                }
            }
            .localizedNavigationTitle("Wipe this profile?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

private struct WipeBullet: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "•")
                .foregroundStyle(.secondary)
            Text(text)
        }
    }
}

/// Non-cancellable staged progress shown while `signOutAndWipe` runs. The FFI
/// is a single async call that reports per-stage results only in its final
/// outcome — there is no streaming progress — so all three stages render as
/// in-flight with indeterminate spinners; they are marked from the outcome
/// afterwards (success toast, or the partial-failure report).
private struct WipeProgressView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                Text("Signing out & wiping…")
                    .font(.title2.weight(.semibold))
                stageRow("Leaving groups…")
                stageRow("Deleting key packages…")
                stageRow("Wiping local data…")
            }
            .padding(28)
        }
    }

    private func stageRow(_ label: LocalizedStringKey) -> some View {
        HStack(spacing: 16) {
            ProgressView()
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}

/// Post-wipe partial-failure report. Renders only the mapped `WipeReport`
/// snapshot — the wiped account's ref is invalid by the time this shows, so
/// nothing here reaches back into the FFI. Hosted by `RootView` because the
/// wipe pops the screen that started it. Shown over the post-wipe end state
/// (next account's chats, or onboarding).
struct WipeOutcomeReportView: View {
    let report: WipeReport
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(report.stages, id: \.stage) { stage in
                    Section {
                        stageSummary(stage)
                        ForEach(Array(stage.failures.enumerated()), id: \.offset) { _, failure in
                            failureRow(failure)
                        }
                    }
                }
            }
            .localizedNavigationTitle("Sign Out & Wipe finished with issues")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
    }

    @ViewBuilder
    private func stageSummary(_ stage: WipeStageReport) -> some View {
        let icon = stage.hasIssues ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        let tint: Color = stage.hasIssues ? .orange : .green
        switch stage.stage {
        case .leavingGroups:
            LabeledContent {
                Text(stage.completedCount ?? 0, format: .number)
                    .foregroundStyle(.secondary)
            } label: {
                Label { Text("Groups left") } icon: {
                    Image(systemName: icon).foregroundStyle(tint)
                }
            }
        case .deletingKeyPackages:
            LabeledContent {
                Text(stage.completedCount ?? 0, format: .number)
                    .foregroundStyle(.secondary)
            } label: {
                Label { Text("Key packages deleted") } icon: {
                    Image(systemName: icon).foregroundStyle(tint)
                }
            }
        case .wipingLocalData:
            Label {
                Text(stage.hasIssues ? "Local data wipe incomplete" : "Local data wiped")
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
        }
    }

    private func failureRow(_ failure: WipeFailureItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let subject = failure.subject {
                Text(subject)
                    .font(.footnote.monospaced())
            }
            Text(failure.reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
