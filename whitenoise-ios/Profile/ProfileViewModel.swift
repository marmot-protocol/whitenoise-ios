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
    private(set) var isLoadingGroups = false
    private var groupLoadGeneration: UInt64 = 0
    private(set) var addableGroups: [SharedGroupsProjection.SharedGroup] = []
    private(set) var groupsLoadState = SharedGroupsLoadState()
    var verifiedNip05: String? { addressVerification.verifiedNip05 }

    let starter = DirectChatStarter()
    let directory = RecipientDirectory()
    private let addressVerification = ProfileAddressVerificationModel()
    private var resolutionGeneration: UInt64 = 0

    func resolve(
        npub: String,
        using appState: AppState,
        refreshProfile: Bool = true
    ) async {
        guard !Task.isCancelled else { return }
        resolutionGeneration &+= 1
        let generation = resolutionGeneration
        // Resolve before awaiting directory reads; keep a completed badge only
        // when this is still the same identity.
        startPrompt = nil
        conversationChooser = nil
        isPreparingConversationChoices = false
        let resolvedHex = ProfileReferenceResolution.accountIdHex(npub)
        if groupsLoadState.prepare(accountRef: appState.activeAccountRef, peerAccountIdHex: resolvedHex) {
            sharedGroups = []
            addableGroups = []
        }
        guard !Task.isCancelled, generation == resolutionGeneration else { return }
        applyResolvedAccount(resolvedHex)
        guard let resolvedHex else { return }
        if refreshProfile {
            // Trigger enrichment (cached read + background relay fetch).
            _ = appState.profile(forAccountIdHex: resolvedHex)
        }
        guard !Task.isCancelled,
              generation == resolutionGeneration,
              hex == resolvedHex
        else { return }
        await reloadGroups(using: appState)
    }

    func reloadGroups(using appState: AppState, force: Bool = false) async {
        guard let resolvedHex = hex else { return }
        groupLoadGeneration &+= 1
        let loadGeneration = groupLoadGeneration
        let generation = resolutionGeneration
        let accountRef = appState.activeAccountRef
        let runtimeGeneration = appState.runtimeGeneration
        isLoadingGroups = true
        defer {
            if groupLoadGeneration == loadGeneration { isLoadingGroups = false }
        }
        await directory.load(using: appState, force: force, includeAdminMetadata: true)
        guard !Task.isCancelled,
              groupLoadGeneration == loadGeneration,
              generation == resolutionGeneration,
              hex == resolvedHex,
              appState.activeAccountRef == accountRef,
              appState.runtimeGeneration == runtimeGeneration
        else { return }
        guard directory.loadError == nil else { return }
        groupsLoadState.complete(accountRef: accountRef, peerAccountIdHex: resolvedHex)
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

    /// The verified badge is earned per pubkey. A reused profile surface
    /// resolving to a different account must shed it — retaining it would
    /// paint another pubkey's verification, a fail-open trust signal.
    func applyResolvedAccount(_ resolvedHex: String?) {
        if hex != resolvedHex {
            startPrompt = nil
            conversationChooser = nil
        }
        hex = resolvedHex
        addressVerification.applyResolvedAccount(resolvedHex)
    }

    func verifyDeclaredNip05(
        _ declared: String?,
        transport: Nip05Resolver.Transport = Nip05Resolver.pinnedTransport
    ) async {
        await addressVerification.verifyDeclaredNip05(declared, transport: transport)
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
        let generation = resolutionGeneration
        let accountRef = appState.activeAccountRef
        let runtimeGeneration = appState.runtimeGeneration
        isPreparingConversationChoices = true
        defer {
            if generation == resolutionGeneration { isPreparingConversationChoices = false }
        }

        await directory.load(
            using: appState,
            includeAdminMetadata: true
        )
        guard !Task.isCancelled,
              generation == resolutionGeneration,
              appState.activeAccountRef == accountRef,
              appState.runtimeGeneration == runtimeGeneration
        else { return }
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
        let generation = resolutionGeneration
        let accountRef = appState.activeAccountRef
        let runtimeGeneration = appState.runtimeGeneration
        let outcome = await starter.startMapped(
            accountIdHex: accountIdHex,
            memberRef: memberRef,
            existingGroupIdHex: existingGroupIdHex,
            using: appState
        )
        guard !Task.isCancelled,
              generation == resolutionGeneration,
              appState.activeAccountRef == accountRef,
              appState.runtimeGeneration == runtimeGeneration
        else { return }
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
