import Foundation
import MarmotKit

/// Screen store for the profile surface: resolves the profile reference to
/// an account id, derives shared groups from chat state, runs the Message
/// action through the shared direct-chat starter (so the invite/retry path
/// matches New Message), and independently verifies a declared NIP-05
/// address before any verified state is shown.
@MainActor
@Observable
final class ProfileViewModel {
    var hex: String?
    var startPrompt: StartChatPrompt?
    var conversationChooser: ConversationChooserPresentation?
    private(set) var isPreparingConversationChoices = false
    private(set) var sharedGroups: [SharedGroupsProjection.SharedGroup] = []
    private(set) var addableGroups: [SharedGroupsProjection.SharedGroup] = []
    private(set) var verifiedNip05: String?
    private(set) var website: String?
    private(set) var isFollowing: Bool?
    private(set) var isLoadingFollow = false
    private(set) var isUpdatingFollow = false

    let starter = DirectChatStarter()
    let directory = RecipientDirectory()
    private var attemptedNip05Verification: String?
    private var resolutionGeneration: UInt64 = 0

    func resolve(
        npub: String,
        using appState: AppState,
        refreshProfile: Bool = true
    ) async {
        resolutionGeneration &+= 1
        let generation = resolutionGeneration
        // A reused profile surface must fail closed while the new identity is
        // resolving. Keeping the previous account visible through a failed
        // client lookup would also keep its trust and shared-group state.
        applyResolvedAccount(nil)
        startPrompt = nil
        conversationChooser = nil
        sharedGroups = []
        addableGroups = []
        let resolvedHex = ProfileReferenceResolution.accountIdHex(npub)
        guard !Task.isCancelled, generation == resolutionGeneration else { return }
        applyResolvedAccount(resolvedHex)
        guard let resolvedHex else { return }
        if refreshProfile {
            // Trigger enrichment (cached read + background relay fetch).
            _ = appState.profile(forAccountIdHex: resolvedHex)
        }
        await refreshWebsite(using: appState)
        guard !Task.isCancelled,
              generation == resolutionGeneration,
              hex == resolvedHex
        else { return }
        await directory.load(using: appState, includeAdminMetadata: true)
        guard !Task.isCancelled,
              generation == resolutionGeneration,
              hex == resolvedHex
        else { return }
        sharedGroups = SharedGroupsProjection.sharedGroups(
            snapshots: directory.snapshots,
            targetAccountIdHex: resolvedHex,
            myAccountIdHex: appState.activeAccount?.accountIdHex
        )
        addableGroups = SharedGroupsProjection.addableGroups(
            snapshots: directory.snapshots,
            targetAccountIdHex: resolvedHex,
            myAccountIdHex: appState.activeAccount?.accountIdHex
        )
    }

    func refreshWebsite(using appState: AppState) async {
        guard let hex else {
            website = nil
            return
        }
        let loadingHex = hex
        let loaded: String?
        do {
            let client = try appState.currentMarmotClient()
            loaded = try await client.userProfileWebsite(accountIdHex: loadingHex)
        } catch {
            return
        }
        guard !Task.isCancelled, hex == loadingHex else { return }
        website = loaded
    }

    /// The verified badge is earned per pubkey. A reused profile surface
    /// resolving to a different account must shed it — retaining it would
    /// paint another pubkey's verification, a fail-open trust signal.
    func applyResolvedAccount(_ resolvedHex: String?) {
        if hex != resolvedHex {
            verifiedNip05 = nil
            attemptedNip05Verification = nil
            website = nil
            startPrompt = nil
            conversationChooser = nil
        }
        hex = resolvedHex
    }

    /// One bounded lookup per declared address; the verified state appears
    /// only when the declaration independently resolves back to this pubkey.
    func verifyDeclaredNip05(
        _ declared: String?,
        transport: Nip05Resolver.Transport = Nip05Resolver.pinnedTransport
    ) async {
        guard let hex,
              let declared = ContentSanitizer.profileAddress(declared),
              attemptedNip05Verification != declared
        else { return }
        let verifyingHex = hex
        attemptedNip05Verification = declared
        let verification = await Nip05Resolver.verification(
            declaredAddress: declared,
            accountIdHex: verifyingHex,
            transport: transport
        )
        // The profile can change while the network lookup is suspended. Only
        // the identity and declaration that started this request may receive
        // its result.
        guard !Task.isCancelled,
              hex == verifyingHex,
              attemptedNip05Verification == declared
        else { return }
        switch verification {
        case .verified:
            verifiedNip05 = declared
        case .mismatch:
            verifiedNip05 = nil
        case .lookupFailed:
            verifiedNip05 = nil
            attemptedNip05Verification = nil
        }
    }

    func prepareFollowStatus(
        initialValue: Bool?,
        load: (() async throws -> Bool)?
    ) async {
        isFollowing = initialValue ?? false
        guard let hex, let load else { return }
        isLoadingFollow = true
        defer { isLoadingFollow = false }
        do {
            let loaded = try await load()
            guard self.hex == hex, !Task.isCancelled else { return }
            isFollowing = loaded
        } catch {
            // Search results already carry a direct-follow bit. If a later
            // refresh fails, keep that known state rather than replacing it.
        }
    }

    func toggleFollow(
        using appState: AppState,
        action: ((Bool) async throws -> Bool)?
    ) async {
        guard let hex,
              !isUpdatingFollow,
              !appState.accounts.contains(where: { $0.accountIdHex == hex }),
              let action
        else { return }
        let desired = !(isFollowing ?? false)
        isUpdatingFollow = true
        defer { isUpdatingFollow = false }

        do {
            let updated = try await action(desired)
            guard self.hex == hex else { return }
            isFollowing = updated
            Haptics.success()
        } catch {
            Haptics.error()
            appState.present(
                UserFacingError.toast(
                    title: L10n.string("Couldn't update follow status"),
                    error: error,
                    fallbackMessage: L10n.string("Please try again.")
                )
            )
        }
    }

    func message(
        npub: String,
        profile: UserProfileMetadataFfi? = nil,
        using appState: AppState,
        onOpen: (String) -> Void
    ) async {
        guard let hex, !isPreparingConversationChoices else { return }
        appState.seedDiscoveredProfile(profile, forAccountIdHex: hex)
        startPrompt = nil
        conversationChooser = nil
        isPreparingConversationChoices = true
        defer { isPreparingConversationChoices = false }

        await directory.load(
            using: appState,
            includeAdminMetadata: true
        )
        guard !Task.isCancelled else { return }
        let memberRef = ProfileReferenceResolution.referenceForResolution(npub) ?? hex
        if let loadError = directory.loadError {
            Haptics.error()
            startPrompt = StartChatPrompt(
                kind: .error(message: loadError),
                recipientName: appState.knownDisplayName(forAccountIdHex: hex),
                accountIdHex: hex,
                memberRef: memberRef,
                existingGroupIdHex: nil
            )
            return
        }

        guard let myAccountIdHex = appState.activeAccount?.accountIdHex else {
            Haptics.error()
            startPrompt = StartChatPrompt(
                kind: .error(message: L10n.string("No active account is selected.")),
                recipientName: appState.knownDisplayName(forAccountIdHex: hex),
                accountIdHex: hex,
                memberRef: memberRef,
                existingGroupIdHex: nil
            )
            return
        }
        let choices = ConversationChoiceProjection.choices(
            in: directory.snapshots,
            targetAccountIdHex: hex,
            myAccountIdHex: myAccountIdHex
        )
        if !choices.isEmpty {
            conversationChooser = ConversationChooserPresentation(
                targetAccountIdHex: hex,
                memberRef: memberRef,
                recipientName: IdentityPresentation.text(
                    accountIdHex: hex,
                    knownName: appState.knownDisplayName(forAccountIdHex: hex)
                ),
                choices: choices
            )
            Haptics.selection()
            return
        }

        await runStart(
            accountIdHex: hex,
            memberRef: memberRef,
            existingGroupIdHex: nil,
            using: appState,
            onOpen: onOpen
        )
    }

    func openConversation(
        _ choice: ConversationChoice,
        using appState: AppState,
        onOpen: (String) -> Void
    ) async {
        guard let chooser = conversationChooser else { return }
        conversationChooser = nil
        await runStart(
            accountIdHex: chooser.targetAccountIdHex,
            memberRef: chooser.memberRef,
            existingGroupIdHex: choice.groupIdHex,
            using: appState,
            onOpen: onOpen
        )
    }

    func startNewConversation(
        using appState: AppState,
        onOpen: (String) -> Void
    ) async {
        guard let chooser = conversationChooser else { return }
        conversationChooser = nil
        await runStart(
            accountIdHex: chooser.targetAccountIdHex,
            memberRef: chooser.memberRef,
            existingGroupIdHex: nil,
            using: appState,
            onOpen: onOpen
        )
    }

    func retryStart(using appState: AppState, onOpen: (String) -> Void) async {
        guard let prompt = startPrompt else { return }
        startPrompt = nil
        await runStart(
            accountIdHex: prompt.accountIdHex,
            memberRef: prompt.memberRef,
            existingGroupIdHex: prompt.existingGroupIdHex,
            using: appState,
            onOpen: onOpen
        )
    }

    private func runStart(
        accountIdHex: String,
        memberRef: String,
        existingGroupIdHex: String?,
        using appState: AppState,
        onOpen: (String) -> Void
    ) async {
        let outcome = await starter.startMapped(
            accountIdHex: accountIdHex,
            memberRef: memberRef,
            existingGroupIdHex: existingGroupIdHex,
            using: appState
        )
        switch outcome {
        case .open(let groupIdHex):
            onOpen(groupIdHex)
        case .prompt(let prompt):
            startPrompt = prompt
        case .ignored:
            break
        }
    }

}
