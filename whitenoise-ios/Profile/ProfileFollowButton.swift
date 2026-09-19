import SwiftUI
import MarmotKit

struct ProfileFollowButton: View {
    @Environment(AppState.self) private var appState
    @State private var model = ProfileFollowModel()

    let accountIdHex: String
    var onChanged: ((Bool) -> Void)?

    var body: some View {
        if Hex.is32Bytes(accountIdHex) {
            Button {
                Task {
                    if model.loadFailed {
                        await load()
                    } else {
                        await toggle()
                    }
                }
            } label: {
                HStack {
                    Label(
                        model.loadFailed ? L10n.string("Retry")
                            : L10n.string(model.isFollowing == true ? "Remove Contact" : "Add Contact"),
                        systemImage: model.loadFailed ? "arrow.clockwise"
                            : (model.isFollowing == true ? "person.badge.minus" : "person.badge.plus")
                    )
                    Spacer()
                    if model.isLoading || model.isUpdating {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(context == nil || model.isLoading || model.isUpdating
                || (model.isFollowing == nil && !model.loadFailed))
            .accessibilityLabel(model.loadFailed ? L10n.string("Couldn't load contact status. Retry.")
                : L10n.string(model.isFollowing == true ? "Remove Contact" : "Add Contact"))
            .task(id: context) { await load() }
        }
    }

    // Keep the prototype row visible; developers still need to resolve the
    // stored-account eligibility rule before enabling those mutations.
    private var context: ProfileFollowContext? {
        guard let accountRef = appState.activeAccountRef,
              ProfileFollowContext.canFollow(accountIdHex, localAccountIds: appState.accounts.map(\.accountIdHex)),
              appState.canUseRuntimeForForegroundWork else { return nil }
        return ProfileFollowContext(
            accountRef: accountRef,
            peerAccountIdHex: accountIdHex.lowercased(),
            runtimeGeneration: appState.runtimeGeneration
        )
    }

    private func load() async {
        let loadingContext = context
        await model.load(context: loadingContext) {
            guard let loadingContext else { throw CancellationError() }
            return try await appState.currentMarmotClient().isFollowing(
                accountRef: loadingContext.accountRef,
                userRef: loadingContext.peerAccountIdHex
            )
        }
    }

    private func toggle() async {
        guard let context else { return }
        do {
            let updated = try await model.toggle(context: context) { desired in
                try await appState.currentMarmotClient().setFollowing(
                    accountRef: context.accountRef,
                    accountIdHex: context.peerAccountIdHex,
                    isFollowing: desired
                )
            }
            guard self.context == context, let updated else { return }
            onChanged?(updated)
            Haptics.success()
        } catch {
            guard self.context == context else { return }
            Haptics.error()
            appState.present(UserFacingError.toast(
                title: L10n.string("Couldn't update contact"),
                error: error,
                fallbackMessage: L10n.string("Please try again.")
            ))
        }
    }
}
