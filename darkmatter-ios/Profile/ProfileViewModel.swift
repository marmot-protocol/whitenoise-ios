import Foundation
import MarmotKit

/// Screen store for `ProfileView`: resolves the scanned/deep-linked profile
/// reference to an account id and runs the "Message" action (start a 2-member
/// group), holding the resolved id + in-flight/error state. The view keeps the
/// pure display helpers (title / reference / isSelf) and the pasteboard copy.
/// `npub` and the view's `dismiss` are passed in rather than retained.
@MainActor
@Observable
final class ProfileViewModel {
    var hex: String?
    var creating = false
    var error: String?
    var copied = false

    func resolve(npub: String, using appState: AppState) async {
        guard let reference = ProfileReferenceResolution.referenceForResolution(npub) else {
            hex = nil
            return
        }
        guard let client = try? appState.currentMarmotClient() else { return }
        let resolvedHex = await client.accountIdHex(reference: reference)
        guard !Task.isCancelled else { return }
        hex = resolvedHex
        if let hex {
            // Trigger enrichment (cached read + background relay fetch).
            _ = appState.profile(forAccountIdHex: hex)
        }
    }

    func message(npub: String, title: String, using appState: AppState, dismiss: () -> Void) async {
        // Take the in-flight guard synchronously before the first await so a
        // fast double-tap can't start two concurrent createGroup calls (which
        // would create two duplicate 2-member groups with the same peer),
        // mirroring NewChatSheetViewModel.create (#403).
        guard !creating, let accountRef = appState.activeAccountRef else { return }
        creating = true
        defer { creating = false }
        error = nil
        do {
            let client = try appState.currentMarmotClient()
            let groupIdHex = try await client.createGroup(
                accountRef: accountRef,
                name: "",
                memberRefs: [hex ?? npub],
                description: nil
            )
            Haptics.success()
            dismiss()
            appState.presentChat(groupIdHex: groupIdHex)
        } catch let marmotError as MarmotKitError {
            Haptics.error()
            if case .MissingKeyPackage = marmotError {
                error = L10n.formatted(
                    "%@ hasn't published a compatible key package, so they can't be messaged yet.",
                    title
                )
            } else {
                error = marmotError.localizedDescription
            }
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
    }
}
