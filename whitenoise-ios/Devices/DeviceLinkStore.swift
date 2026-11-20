import Foundation
import MarmotKit

/// The active account's linked devices, link requests, sign-ins and compromise
/// warning, mirrored from MDK for presentation. MDK owns every decision; this
/// re-reads on MDK's events and routes the user's choices back.
@MainActor @Observable
final class DeviceLinkStore {
    // Avoid the task-local isolated-deinit crash on iOS 26.2 and older.
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    enum Sheet: Identifiable, Hashable {
        /// Approve a request from a new device, on a device already signed in.
        case approve(promptID: String)
        /// Ask a device already signed in to link this one.
        case linkThisDevice
        /// On a device already signed in: how to add a new one, waiting for its request.
        case addDevice

        var id: String {
            switch self {
            case .approve(let promptID): "approve:\(promptID)"
            case .linkThisDevice: "linkThisDevice"
            case .addDevice: "addDevice"
            }
        }
    }

    struct UnlinkedNotice: Identifiable, Equatable {
        let id = UUID()
        let accountIdHex: String
    }

    private struct Scope: Equatable {
        let accountRef: String
        let accountIdHex: String
        let runtimeGeneration: Int
    }

    private enum Part: CaseIterable {
        case snapshot, devices, signIns, compromise, keyPackage, historyImports
    }

    private(set) var isAvailable = false
    private(set) var snapshot: DeviceLinkSnapshotFfi?
    private(set) var devices: [LinkedDeviceFfi] = []
    private(set) var devicesLoadError: String?
    private(set) var chatsClosedToLinkedDevices: UInt32 = 0
    private(set) var leftoverChats: UInt32 = 0
    private(set) var signIns: [UnrecognizedSignInFfi] = []
    private(set) var compromiseWarning: [CompromiseWarningItemFfi] = []
    private(set) var startedFresh = false
    private(set) var keyPackageRefreshOverdue = false
    /// Chats whose history from another device is arriving or arrived, by group id.
    private(set) var historyImports: [String: ChatHistoryImportStateFfi] = [:]
    /// Requests waiting for this device's other signed-in profiles, by account id.
    private(set) var otherProfilePrompts: [String: [DeviceLinkPromptFfi]] = [:]
    private var dismissedOtherProfilePromptIDs: Set<String> = []
    /// A request to present once its profile becomes active.
    private var promptAfterSwitch: OtherProfileLinkRequest?

    /// The device sheet MainView presents.
    private(set) var sheet: Sheet?
    var unlinkedNotice: UnlinkedNotice?
    /// Unlinked profiles already raised in this launch.
    private var remindedUnlinkedAccountIDs: Set<String> = []
    /// The account that finished setup on this device in this launch, which
    /// makes it the new device of a link.
    private(set) var setupFinishedAccountIdHex: String?
    private var newDeviceOfferDismissed = false
    /// Set when the user chose to link from the offer; the flow starts at once.
    private var startsLinkOnPresent = false
    /// The name the user gave this device while approving its first link,
    /// applied once its device group exists (there is no roster to rename in
    /// before the link commits).
    private var pendingOwnLabel: String?
    private var applyingOwnLabel = false

    private var dismissedPromptIDs: Set<String> = []
    private var scope: Scope?
    private var tickets: [Part: UUID] = [:]

    // MARK: - Derived

    var hasDeviceGroup: Bool { !devices.isEmpty }
    var otherDevices: [LinkedDeviceFfi] { devices.filter { !$0.isThisDevice } }
    var thisDevice: LinkedDeviceFfi? { devices.first { $0.isThisDevice } }
    var newDeviceStep: NewDeviceLinkStep { NewDeviceLinkStep(snapshot?.newDevice) }
    var pendingPrompts: [DeviceLinkPromptFfi] { DeviceLinkPromptPolicy.pending(snapshot?.prompts ?? []) }
    var deviceGroupStalled: Bool { snapshot?.deviceGroupStalled ?? false }
    var moves: [DeviceGroupMoveViewFfi] { snapshot?.moves ?? [] }
    var chatProgress: [LinkChatProgressFfi] { snapshot?.chatProgress ?? [] }
    var warnsAboutPendingLinkBeforeMove: Bool {
        DeviceGroupMovePresentation.warnsAboutPendingLink(hasDeviceGroup: hasDeviceGroup, prompts: snapshot?.prompts ?? [])
    }

    var presentedPromptID: String? {
        if case .approve(let promptID) = sheet { promptID } else { nil }
    }

    func prompt(_ promptID: String) -> DeviceLinkPromptFfi? {
        snapshot?.prompts.first { $0.promptId == promptID }
    }

    func device(_ slotIdHex: String) -> LinkedDeviceFfi? {
        devices.first { $0.slotIdHex == slotIdHex }
    }

    func attentionBanner(using appState: AppState) -> DeviceAttentionBanner? {
        guard isAvailable else { return nil }
        return DeviceAttentionBanner.select(
            compromiseWarningCount: compromiseWarning.count,
            pendingPromptIDs: pendingPrompts.map(\.promptId),
            presentedPromptID: presentedPromptID,
            newDeviceStep: newDeviceStep,
            newDeviceFlowVisible: sheet == .linkThisDevice,
            otherProfileRequest: otherProfileRequest(using: appState)
        )
    }

    /// The first request for another signed-in profile, which comparing needs
    /// that profile active for.
    func otherProfileRequest(using appState: AppState) -> OtherProfileLinkRequest? {
        guard isAvailable else { return nil }
        let accounts = appState.accounts
            .filter { !$0.signedOut && $0.accountIdHex != scope?.accountIdHex }
            .map { (accountIdHex: $0.accountIdHex, accountRef: $0.label) }
        return OtherProfileLinkRequest.first(
            accounts: accounts, prompts: otherProfilePrompts, dismissedPromptIDs: dismissedOtherProfilePromptIDs
        )
    }

    /// Every request waiting for another profile, put away or not, for the Devices screen.
    func otherProfileRequests(using appState: AppState) -> [OtherProfileLinkRequest] {
        guard isAvailable else { return [] }
        return appState.accounts
            .filter { !$0.signedOut && $0.accountIdHex != scope?.accountIdHex }
            .flatMap { account in
                DeviceLinkPromptPolicy.pending(otherProfilePrompts[account.accountIdHex] ?? []).map {
                    OtherProfileLinkRequest(accountIdHex: account.accountIdHex, accountRef: account.label, promptID: $0.promptId)
                }
            }
    }

    func dismissOtherProfileRequest(_ request: OtherProfileLinkRequest) {
        dismissedOtherProfilePromptIDs.insert(request.promptID)
    }

    /// Review: switch to that profile, then present its request there.
    func reviewOtherProfileRequest(_ request: OtherProfileLinkRequest, using appState: AppState) async {
        dismissedOtherProfilePromptIDs.insert(request.promptID)
        promptAfterSwitch = request
        await appState.activateAccount(request.accountRef)
        await refresh(using: appState)
    }

    var offersNewDeviceLink: Bool {
        isAvailable && sheet == nil && NewDeviceLinkOffer.shouldOffer(
            finishedSetupThisLaunch: setupFinishedAccountIdHex != nil
                && setupFinishedAccountIdHex == scope?.accountIdHex,
            dismissed: newDeviceOfferDismissed,
            signIns: signIns,
            hasDeviceGroup: hasDeviceGroup,
            startedFresh: startedFresh,
            newDeviceState: snapshot?.newDevice
        )
    }

    func noteSetupFinished(accountIdHex: String) {
        setupFinishedAccountIdHex = accountIdHex
        newDeviceOfferDismissed = false
    }

    func dismissNewDeviceOffer() {
        newDeviceOfferDismissed = true
    }

    /// "Link This iPhone" on the offer: open the flow and start the link.
    func linkFromNewDeviceOffer() {
        newDeviceOfferDismissed = true
        startsLinkOnPresent = true
        present(.linkThisDevice)
    }

    /// Whether the flow just opened should start the link itself, once.
    func consumeStartsLinkOnPresent() -> Bool {
        defer { startsLinkOnPresent = false }
        return startsLinkOnPresent
    }

    // MARK: - Sheets

    func present(_ sheet: Sheet) {
        if case .approve(let promptID) = sheet { dismissedPromptIDs.remove(promptID) }
        self.sheet = sheet
    }

    /// The user closed the sheet. A request put away this way stays listed on
    /// the Devices screen and the Chats banner but no longer presents itself.
    func sheetDismissed() {
        if let presentedPromptID { dismissedPromptIDs.insert(presentedPromptID) }
        sheet = nil
    }

    private func updatePromptPresentation() {
        // Never replace the new-device flow with a request; Add a New Device waits for one.
        guard sheet == nil || sheet == .addDevice || presentedPromptID != nil else { return }
        let next = DeviceLinkPromptPolicy.promptToPresent(
            prompts: snapshot?.prompts ?? [],
            presentedID: presentedPromptID,
            dismissedIDs: dismissedPromptIDs
        )
        if next != presentedPromptID, next != nil || sheet != .addDevice {
            sheet = next.map { .approve(promptID: $0) }
        }
    }

    // MARK: - Reads

    func refresh(using appState: AppState) async {
        guard prepareScope(using: appState) else { return }
        await withTaskGroup(of: Void.self) { group in
            for part in Part.allCases {
                group.addTask { await self.refresh(part, using: appState) }
            }
            group.addTask { await self.refreshOtherProfiles(using: appState) }
        }
    }

    /// Reads link requests for the other signed-in profiles; it never answers one.
    private func refreshOtherProfiles(only accountIdHex: String? = nil, using appState: AppState) async {
        guard isAvailable, let client = try? appState.currentMarmotClient() else { return }
        let others = appState.accounts.filter {
            !$0.signedOut && $0.accountIdHex != scope?.accountIdHex
                && (accountIdHex == nil || $0.accountIdHex == accountIdHex)
        }
        if accountIdHex == nil {
            otherProfilePrompts = otherProfilePrompts.filter { id, _ in others.contains { $0.accountIdHex == id } }
        }
        for account in others {
            guard let snapshot = try? await client.marmot.deviceLinkSnapshot(accountRef: account.label) else { continue }
            otherProfilePrompts[account.accountIdHex] = snapshot.prompts
        }
    }

    /// Re-reads what each MDK event says changed. `DeviceUnlinked` can name any
    /// signed-in account; the rest refresh only the active one.
    func observe(_ event: MarmotEventFfi, using appState: AppState) {
        let part: Part
        let accountID: String
        switch event {
        case .deviceLinkChanged(let id, _): (part, accountID) = (.snapshot, id)
        case .linkedDevicesChanged(let id, _): (part, accountID) = (.devices, id)
        case .unrecognizedSignInsChanged(let id, _): (part, accountID) = (.signIns, id)
        case .compromiseWarningChanged(let id, _): (part, accountID) = (.compromise, id)
        case .keyPackageRefreshOverdueChanged(let id, _): (part, accountID) = (.keyPackage, id)
        case .chatHistoryImportsChanged(let id, _): (part, accountID) = (.historyImports, id)
        case .deviceUnlinked(let id, _):
            remindedUnlinkedAccountIDs.insert(id)
            unlinkedNotice = UnlinkedNotice(accountIdHex: id)
            if id == scope?.accountIdHex { clear() }
            // The alert's Remove or Later routes away from it.
            Task { try? await appState.refreshAccounts() }
            return
        default:
            return
        }
        guard appState.activeAccount?.accountIdHex == accountID else {
            if part == .snapshot {
                Task { await self.refreshOtherProfiles(only: accountID, using: appState) }
            }
            return
        }
        Task {
            guard self.prepareScope(using: appState) else { return }
            await self.refresh(part, using: appState)
        }
    }

    /// Binds reads to the active account and runtime. While the runtime is
    /// suspended for background, everything stays as it was. A new runtime for
    /// the same account keeps the open sheet: the user may have switched apps
    /// mid-link, and the sheet then shows how MDK resumed it.
    private func prepareScope(using appState: AppState) -> Bool {
        guard appState.canUseRuntimeForForegroundWork,
              let accountRef = appState.activeAccountRef,
              let accountIdHex = appState.activeAccount?.accountIdHex,
              (try? appState.currentMarmotClient()) != nil else {
            return false
        }
        let next = Scope(accountRef: accountRef, accountIdHex: accountIdHex,
                         runtimeGeneration: appState.runtimeGeneration)
        if scope != next {
            clear(keepingPresentation: scope?.accountRef == accountRef)
            scope = next
        }
        isAvailable = true
        return isAvailable
    }

    private func refresh(_ part: Part, using appState: AppState) async {
        guard let scope, let client = try? appState.currentMarmotClient() else { return }
        let ticket = UUID()
        tickets[part] = ticket
        let marmot = client.marmot
        let account = scope.accountRef
        func current() -> Bool { tickets[part] == ticket && self.scope == scope && matches(appState) }
        do {
            switch part {
            case .snapshot:
                let next = try await marmot.deviceLinkSnapshot(accountRef: account)
                guard current() else { return }
                apply(next)
            case .devices:
                let next = try await marmot.linkedDevices(accountRef: account)
                async let closed = marmot.chatsClosedToLinkedDevices(accountRef: account)
                async let leftover = marmot.removedDeviceLeftoverChats(accountRef: account)
                async let fresh = marmot.startedFresh(accountRef: account)
                let counts = (try? await closed, try? await leftover, try? await fresh)
                guard current() else { return }
                devices = next
                devicesLoadError = nil
                chatsClosedToLinkedDevices = counts.0 ?? 0
                leftoverChats = counts.1 ?? 0
                startedFresh = counts.2 ?? false
                await applyPendingOwnLabel(using: appState)
            case .signIns:
                let next = try await marmot.unrecognizedSignIns(accountRef: account)
                guard current() else { return }
                signIns = next
            case .compromise:
                let next = try await marmot.compromiseWarning(accountRef: account)
                guard current() else { return }
                compromiseWarning = next
            case .keyPackage:
                let next = try await marmot.keyPackageRefreshOverdue(accountRef: account)
                guard current() else { return }
                keyPackageRefreshOverdue = next
            case .historyImports:
                let next = try await marmot.chatHistoryImports(accountRef: account)
                guard current() else { return }
                historyImports = Dictionary(next.map { ($0.groupIdHex, $0.state) }, uniquingKeysWith: { _, last in last })
            }
        } catch {
            guard current() else { return }
            if DeviceGroupRefusal(error: error)?.isUnsupported == true {
                isAvailable = false
            } else if part == .devices {
                devicesLoadError = UserFacingError.message(for: error)
            }
        }
    }

    private func apply(_ next: DeviceLinkSnapshotFfi) {
        snapshot = next
        if let request = promptAfterSwitch, request.accountIdHex == scope?.accountIdHex {
            promptAfterSwitch = nil
            if next.prompts.contains(where: { $0.promptId == request.promptID }) {
                present(.approve(promptID: request.promptID))
            }
        }
        updatePromptPresentation()
    }

    func clear(keepingPresentation: Bool = false) {
        if !keepingPresentation {
            sheet = nil
            dismissedPromptIDs = []
            startsLinkOnPresent = false
            pendingOwnLabel = nil
        }
        snapshot = nil
        devices = []
        devicesLoadError = nil
        chatsClosedToLinkedDevices = 0
        leftoverChats = 0
        signIns = []
        compromiseWarning = []
        startedFresh = false
        keyPackageRefreshOverdue = false
        historyImports = [:]
        isAvailable = false
        scope = nil
        tickets = [:]
    }

    private func matches(_ appState: AppState) -> Bool {
        appState.canUseRuntimeForForegroundWork && appState.activeAccountRef == scope?.accountRef
            && appState.runtimeGeneration == scope?.runtimeGeneration
    }

    // MARK: - Actions

    /// Runs one user action against the live runtime for this store's account.
    private func mutate<Result>(
        using appState: AppState,
        _ body: (Marmot, String) async throws -> Result
    ) async throws -> Result {
        guard let scope, matches(appState) else { throw ForegroundRuntimeMutationError.runtimeUnavailable }
        let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { appState.runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        return try await body(lease.client.marmot, scope.accountRef)
    }

    private func mutateSnapshot(
        using appState: AppState,
        _ body: (Marmot, String) async throws -> DeviceLinkSnapshotFfi
    ) async throws {
        let scope = self.scope
        let next = try await mutate(using: appState, body)
        guard self.scope == scope else { return }
        apply(next)
    }

    /// New device: ask a device already signed in to link this one. The request
    /// names this device's published KeyPackage; if there is none it publishes
    /// one first, since the user asked to link.
    func startLink(using appState: AppState) async throws {
        do {
            try await mutateSnapshot(using: appState) { marmot, account in
                try await marmot.startDeviceLink(accountRef: account)
            }
        } catch where DeviceGroupRefusal(error: error)?.reason == "key_package_not_published" {
            try await mutateSnapshot(using: appState) { marmot, account in
                _ = try await marmot.rotateKeyPackage(accountRef: account)
                return try await marmot.startDeviceLink(accountRef: account)
            }
        }
    }

    func confirmMatch(using appState: AppState) async throws {
        try await mutateSnapshot(using: appState) { marmot, account in
            try await marmot.confirmDeviceLinkMatch(accountRef: account)
        }
    }

    func cancelLink(using appState: AppState) async throws {
        try await mutateSnapshot(using: appState) { marmot, account in
            try await marmot.cancelDeviceLink(accountRef: account)
        }
    }

    /// Existing device: Link device. MDK's commit is the approval.
    /// `thisDeviceLabel` names this device too, when it has no name yet.
    func link(
        promptID: String, label: String, addToAllChats: Bool, bringHistory: Bool,
        thisDeviceLabel: String? = nil, using appState: AppState
    ) async throws {
        if let thisDeviceLabel { pendingOwnLabel = thisDeviceLabel }
        try await mutateSnapshot(using: appState) { marmot, account in
            try await marmot.linkDevice(
                accountRef: account, promptId: promptID, label: label,
                addToAllChats: addToAllChats, bringHistory: bringHistory
            )
        }
    }

    /// Names this device once the roster lists it, while it still has no
    /// name. A busy device group keeps the name for the next roster change.
    private func applyPendingOwnLabel(using appState: AppState) async {
        guard let label = pendingOwnLabel, !applyingOwnLabel, let me = thisDevice else { return }
        guard me.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pendingOwnLabel = nil
            return
        }
        applyingOwnLabel = true
        defer { applyingOwnLabel = false }
        do {
            try await mutate(using: appState) { marmot, account in
                try await marmot.renameLinkedDevice(accountRef: account, slotIdHex: me.slotIdHex, label: label)
            }
            pendingOwnLabel = nil
        } catch where DeviceGroupRefusal(error: error)?.reason == "device_group_busy" {
            // Tried again on the next roster change.
        } catch {
            pendingOwnLabel = nil
        }
    }

    /// Existing device: Not now.
    func decline(promptID: String, using appState: AppState) async throws {
        try await mutateSnapshot(using: appState) { marmot, account in
            try await marmot.declineDeviceLink(accountRef: account, promptId: promptID)
        }
    }

    func rename(slotIdHex: String, label: String, using appState: AppState) async throws {
        try await mutate(using: appState) { marmot, account in
            try await marmot.renameLinkedDevice(accountRef: account, slotIdHex: slotIdHex, label: label)
        }
        await refresh(.devices, using: appState)
    }

    /// `nil` keeps the roster's current value, so one toggle never restores
    /// another from a stale screen.
    func updateSettings(
        slotIdHex: String,
        addToAllChats: Bool? = nil,
        bringHistory: Bool? = nil,
        keepWhileInactive: Bool? = nil,
        using appState: AppState
    ) async throws {
        try await mutate(using: appState) { marmot, account in
            try await marmot.updateLinkedDeviceSettings(
                accountRef: account, slotIdHex: slotIdHex, addToAllChats: addToAllChats,
                bringHistory: bringHistory, keepWhileInactive: keepWhileInactive
            )
        }
        await refresh(.devices, using: appState)
    }

    func remove(slotIdHex: String, using appState: AppState) async throws {
        try await mutate(using: appState) { marmot, account in
            try await marmot.removeLinkedDevice(accountRef: account, slotIdHex: slotIdHex)
        }
        await refresh(.devices, using: appState)
    }

    func answerSignIn(slotIdHex: String, response: SignInResponseFfi, using appState: AppState) async throws {
        try await mutate(using: appState) { marmot, account in
            try await marmot.answerSignIn(accountRef: account, slotIdHex: slotIdHex, response: response)
        }
        await refresh(.signIns, using: appState)
        await refresh(.compromise, using: appState)
    }

    func checkSignIns(using appState: AppState) async throws {
        let scope = self.scope
        let next = try await mutate(using: appState) { marmot, account in
            try await marmot.checkSignIns(accountRef: account)
        }
        guard self.scope == scope else { return }
        signIns = next
    }

    func startFresh(using appState: AppState) async throws {
        try await mutate(using: appState) { marmot, account in
            try await marmot.startFresh(accountRef: account)
        }
        await refresh(.devices, using: appState)
        await refresh(.signIns, using: appState)
    }

    func dismissCompromiseWarning(using appState: AppState) async throws {
        try await mutate(using: appState) { marmot, account in
            try await marmot.dismissCompromiseWarning(accountRef: account)
        }
        await refresh(.compromise, using: appState)
    }

    /// Ends one "still in your old device list" hint. It neither links nor
    /// removes that device.
    func dismissMoveSibling(moveId: String, slotIdHex: String, using appState: AppState) async throws {
        try await mutateSnapshot(using: appState) { marmot, account in
            try await marmot.dismissDeviceGroupMoveSibling(accountRef: account, moveId: moveId, slotIdHex: slotIdHex)
        }
    }

    /// After a relaunch, raises the unlinked notice again for a profile whose
    /// removal the user put off with Later.
    func remindUnlinkedProfiles(_ accounts: [AccountSummaryFfi]) {
        guard let id = UnlinkedProfileReminder.next(
            accounts: accounts, reminded: remindedUnlinkedAccountIDs, showing: unlinkedNotice?.accountIdHex
        ) else { return }
        remindedUnlinkedAccountIDs.insert(id)
        unlinkedNotice = UnlinkedNotice(accountIdHex: id)
    }

    /// Discards this device's stalled device-group copy and publishes a fresh
    /// KeyPackage, ready for a new compared-code link. Keeps chats and keys.
    func resetForRepair(using appState: AppState) async throws {
        try await mutateSnapshot(using: appState) { marmot, account in
            let snapshot = try await marmot.resetDeviceGroupForRepair(accountRef: account)
            _ = try await marmot.rotateKeyPackage(accountRef: account)
            return snapshot
        }
        await refresh(.devices, using: appState)
    }
}

/// The unlinked profile's data is still on this device.
struct UnlinkedAccountRemovalError: LocalizedError {
    var errorDescription: String? {
        L10n.string("This profile’s data is still on this device. Keep White Noise open and try again.")
    }
}
