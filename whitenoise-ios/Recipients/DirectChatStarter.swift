import Foundation
import MarmotKit

/// Failure taxonomy for starting a direct chat. On this path a recipient
/// whose identity resolves but who has no usable messaging setup gets an
/// invite prompt, not an error: `MissingKeyPackage`, `InvalidKeyPackageEvent`,
/// and post-resolution `InvalidIdentity` all mean "not reachable on White
/// Noise yet". A recipient with only outdated KeyPackages is on White Noise
/// and needs to update, so that stays a retryable error. Group-membership
/// mutations keep their strict error mapping.
nonisolated enum StartChatFailurePresentation {
    enum Failure: Equatable {
        case missingSetup
        case other(message: String)
    }

    static func failure(for error: Error) -> Failure {
        guard let marmotError = error as? MarmotKitError else {
            return .other(message: UserFacingError.message(for: error))
        }
        switch marmotError {
        case .MissingKeyPackage(_, .obsoleteOnly):
            return .other(message: UserFacingError.message(for: marmotError))
        case .MissingKeyPackage, .InvalidKeyPackageEvent, .InvalidIdentity:
            return .missingSetup
        default:
            return .other(message: UserFacingError.message(for: marmotError))
        }
    }

    static func inviteDetail(recipientName: String?) -> String {
        if let recipientName, !recipientName.isEmpty {
            return L10n.formatted(
                "%@ isn't on White Noise yet. Share the app so you can chat securely.",
                recipientName
            )
        }
        return L10n.string("They aren't on White Noise yet. Share the app so you can chat securely.")
    }

    static func inviteMessage() -> String {
        L10n.string("Let's chat on White Noise — private, secure messaging. Get it at https://whitenoise.chat and share your profile QR with me.")
    }
}

/// Inline follow-up after a failed chat start, shared by New Message and the
/// profile surface: an invite prompt when the recipient has no usable
/// messaging setup, an error with retry otherwise. Carries the start inputs
/// so Retry can re-run the same attempt.
nonisolated struct StartChatPrompt: Equatable {
    enum Kind: Equatable {
        case invite
        case error(message: String)
    }

    let kind: Kind
    let recipientName: String?
    let accountIdHex: String
    let memberRef: String
    let existingGroupIdHex: String?

    static func kind(for failure: StartChatFailurePresentation.Failure) -> Kind {
        switch failure {
        case .missingSetup:
            return .invite
        case .other(let message):
            return .error(message: message)
        }
    }
}

/// Starts (or reopens) a direct chat with one person. Owns the flow-level
/// in-flight guard so a fast double-tap — on the same row or a different one —
/// can't create two groups, and reports a row-scoped identity so only the
/// tapped person's row shows progress.
@MainActor
@Observable
final class DirectChatStarter {
    // Avoid the isolated-deinit task-local crash on older Swift runtimes (including iOS 26.2).
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    enum Outcome: Equatable {
        case opened(groupIdHex: String)
        case created(groupIdHex: String)
        case failed(StartChatFailurePresentation.Failure)
        /// Another start was already in flight; nothing happened.
        case ignored
    }

    /// Account id of the person whose start is in flight, for row-scoped
    /// progress. `nil` when idle.
    private(set) var creatingAccountIdHex: String?

    var isCreating: Bool { creatingAccountIdHex != nil }

    /// Support opens quietly while other entry points keep their existing feedback.
    var playsSuccessHaptic = true

    /// Creates the unnamed two-member group for `accountRef` and `memberRef`.
    typealias CreateGroup = @MainActor (
        _ appState: AppState,
        _ accountRef: String,
        _ memberRef: String
    ) async throws -> CreatedGroupFfi

    @ObservationIgnored private let createGroup: CreateGroup

    init(createGroup: @escaping CreateGroup = DirectChatStarter.createGroupInMarmot) {
        self.createGroup = createGroup
    }

    private static func createGroupInMarmot(
        appState: AppState,
        accountRef: String,
        memberRef: String
    ) async throws -> CreatedGroupFfi {
        try await appState.currentMarmotClient().createGroupWithOptionsDetailed(
            accountRef: accountRef,
            name: "",
            memberRefs: [memberRef],
            options: CreateGroupOptionsFfi(
                description: nil,
                initialImage: nil,
                disappearingMessageSecs: 0
            )
        )
    }

    /// Opens `existingGroupIdHex` when the person already shares an open
    /// direct chat; otherwise creates an unnamed two-member group. The guard
    /// is taken synchronously before the first await.
    func start(
        accountIdHex: String,
        memberRef: String,
        existingGroupIdHex: String?,
        using appState: AppState
    ) async -> Outcome {
        guard creatingAccountIdHex == nil else { return .ignored }
        guard let accountRef = appState.activeAccountRef else {
            return .failed(.other(message: L10n.string("No active account is selected.")))
        }
        if let existingGroupIdHex {
            appState.noteDirectChatPeer(
                accountRef: accountRef,
                groupIdHex: existingGroupIdHex,
                peerAccountIdHex: accountIdHex
            )
            return .opened(groupIdHex: existingGroupIdHex)
        }
        creatingAccountIdHex = accountIdHex
        defer { creatingAccountIdHex = nil }
        let performance = HostActionPerformance.begin()
        do {
            let created = try await createGroup(appState, accountRef, memberRef)
            let groupIdHex = created.groupIdHex
            appState.noteCreatedChatListRow(accountRef: accountRef, row: created.chatListRow)
            HostActionPerformance.groupBecameCanonical(
                groupIdHex: groupIdHex,
                since: performance
            )
            appState.noteDirectChatPeer(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                peerAccountIdHex: accountIdHex
            )
            return .created(groupIdHex: groupIdHex)
        } catch {
            return .failed(StartChatFailurePresentation.failure(for: error))
        }
    }

    enum MappedOutcome: Equatable {
        case open(groupIdHex: String)
        case prompt(StartChatPrompt)
        case ignored
    }

    /// `start` plus haptics and prompt mapping — the shape both New Message
    /// and the profile surface consume.
    func startMapped(
        accountIdHex: String,
        memberRef: String,
        existingGroupIdHex: String?,
        using appState: AppState
    ) async -> MappedOutcome {
        let outcome = await start(
            accountIdHex: accountIdHex,
            memberRef: memberRef,
            existingGroupIdHex: existingGroupIdHex,
            using: appState
        )
        switch outcome {
        case .opened(let groupIdHex), .created(let groupIdHex):
            if playsSuccessHaptic { Haptics.success() }
            return .open(groupIdHex: groupIdHex)
        case .failed(let failure):
            Haptics.error()
            return .prompt(StartChatPrompt(
                kind: StartChatPrompt.kind(for: failure),
                recipientName: appState.knownDisplayName(forAccountIdHex: accountIdHex),
                accountIdHex: accountIdHex,
                memberRef: memberRef,
                existingGroupIdHex: existingGroupIdHex
            ))
        case .ignored:
            return .ignored
        }
    }
}
