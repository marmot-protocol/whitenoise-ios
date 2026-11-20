import Foundation
import MarmotKit

/// MDK's `device group refused: <reason>` runtime refusals, read from the
/// `MarmotKitError.Runtime` details so the app can word them.
nonisolated struct DeviceGroupRefusal: Equatable {
    static let prefix = "device group refused:"

    let reason: String

    init(reason: String) {
        self.reason = reason
    }

    init?(error: Error) {
        guard let error = error as? MarmotKitError, case .Runtime(let details) = error,
              let range = details.range(of: Self.prefix) else { return nil }
        let rest = details[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let reason = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !reason.isEmpty else { return nil }
        self.reason = String(reason)
    }

    var isUnsupported: Bool {
        reason == "pairing_unsupported" || reason == "roster_unsupported"
    }

    var message: String {
        switch reason {
        case "pairing_unsupported", "roster_unsupported":
            L10n.string("Linking devices isn’t turned on in this build.")
        case "pairing_in_progress":
            L10n.string("This device is already linking. Finish or cancel that first.")
        case "no_link_in_progress":
            L10n.string("There’s no link in progress.")
        case "key_package_not_published":
            L10n.string("This device couldn’t publish its messaging key. Check your connection and try again.")
        case "unknown_prompt":
            L10n.string("This request is no longer active. Start linking again on the new device.")
        case "link_unavailable":
            L10n.string("This device can’t be linked right now. Make sure only one new device is asking to link.")
        case "device_already_linked":
            L10n.string("That device is already linked.")
        case "sign_in_rejected":
            L10n.string("This sign-in was marked as not you, so it can’t be linked.")
        case "too_many_devices":
            L10n.string("Your profile already has 20 devices. Remove one before linking another.")
        case "label_invalid", "label_too_long":
            L10n.string("Enter a shorter device name.")
        case "no_device_group":
            L10n.string("This device isn’t linked to any other devices.")
        case "unknown_device":
            L10n.string("That device is no longer in your device list.")
        case "device_group_busy":
            L10n.string("Your devices are still syncing an earlier change. Try again in a moment.")
        case "this_device":
            L10n.string("To remove this device, sign out on it instead.")
        case "device_link_pending":
            L10n.string("That device hasn’t finished linking yet. Try again later.")
        case "roster_unavailable":
            L10n.string("Couldn’t read your device list.")
        case "key_packages_unreachable":
            L10n.string("Couldn’t reach your relays to check for sign-ins. Check your connection and try again.")
        case "sign_ins_unchecked":
            L10n.string("This device hasn’t finished checking for other sign-ins. Try again in a moment.")
        case "device_group_exists":
            L10n.string("This device is already linked to your other devices.")
        case "sign_in_unknown":
            L10n.string("That sign-in is no longer listed.")
        case "sign_in_answered":
            L10n.string("That sign-in was already answered.")
        case "sign_in_answered_elsewhere":
            L10n.string("That sign-in was answered on another device.")
        case "sign_in_unanswered":
            L10n.string("That sign-in hasn’t been answered on another device yet.")
        default:
            L10n.string("Something went wrong with your linked devices. Try again.")
        }
    }
}

/// Why a link ended, worded for either side.
nonisolated enum DeviceLinkEndPresentation {
    static func message(for reason: DeviceLinkEndReasonFfi) -> String {
        switch reason {
        case .cancelled:
            L10n.string("Linking was cancelled.")
        case .cancelledElsewhere:
            L10n.string("Linking was cancelled on the other device.")
        case .codesDiffer:
            L10n.string("The emoji didn’t match, so the devices weren’t linked.")
        case .verificationFailed:
            L10n.string("The devices couldn’t verify each other, so they weren’t linked. If this keeps happening, someone else may have your private key.")
        case .timedOut:
            L10n.string("Linking took too long and stopped. Try again with both devices open.")
        case .answeredElsewhere:
            L10n.string("Another of your devices answered this request.")
        case .cannotLink:
            L10n.string("These devices can’t be linked. One of them may need to update White Noise.")
        case .rejected:
            L10n.string("This sign-in was marked as not you, so it wasn’t linked.")
        case .linkFailed:
            L10n.string("Linking didn’t finish. Try again with both devices open.")
        }
    }
}

/// The new device's side of a link, from `DeviceLinkSnapshotFfi.newDevice`.
nonisolated enum NewDeviceLinkStep: Equatable {
    /// Nothing started yet, or the user is starting over after a finished link.
    case intro
    case waitingForAnswer
    case comparing([DeviceLinkEmojiFfi])
    case waitingForOtherDevice
    case joining
    case linked
    case ended(DeviceLinkEndReasonFfi)

    init(_ state: NewDeviceLinkStateFfi?) {
        switch state {
        case nil: self = .intro
        case .waitingForAnswer: self = .waitingForAnswer
        case .comparing(let code): self = .comparing(code)
        case .waitingForOtherDevice: self = .waitingForOtherDevice
        case .joining: self = .joining
        case .linked: self = .linked
        case .ended(let reason): self = .ended(reason)
        }
    }

    /// A link MDK is still running, which Cancel ends.
    var isInProgress: Bool {
        switch self {
        case .waitingForAnswer, .comparing, .waitingForOtherDevice, .joining: true
        case .intro, .linked, .ended: false
        }
    }

    var isFinished: Bool {
        switch self {
        case .linked, .ended: true
        default: false
        }
    }

    /// The step a freshly opened flow shows. A finished link from an earlier
    /// attempt is history, so the flow opens on the intro instead.
    static func opening(_ state: NewDeviceLinkStateFfi?) -> NewDeviceLinkStep {
        let step = NewDeviceLinkStep(state)
        return step.isFinished ? .intro : step
    }
}

/// What the device already signed in shows for one link request.
nonisolated enum DeviceLinkPromptPresentation {
    /// Whether the request still waits on this device, so it may present itself.
    /// One MDK can't link yet presents itself too, saying why, as on the Mac.
    static func needsAttention(_ state: DeviceLinkPromptStateFfi) -> Bool {
        switch state {
        case .preparing, .comparing, .competingRequests, .rateLimited, .cannotLink, .tooManyDevices, .linking: true
        case .linked, .addedElsewhere, .ended: false
        }
    }

    /// Not Now is offered while the request still waits on this device's answer.
    static func canDecline(_ state: DeviceLinkPromptStateFfi) -> Bool {
        switch state {
        case .preparing, .comparing, .competingRequests, .rateLimited, .cannotLink, .tooManyDevices: true
        case .linking, .linked, .addedElsewhere, .ended: false
        }
    }

    static func isFinished(_ state: DeviceLinkPromptStateFfi) -> Bool {
        switch state {
        case .linked, .addedElsewhere, .ended: true
        default: false
        }
    }

    static func summary(_ state: DeviceLinkPromptStateFfi, now: Date = .now) -> String {
        switch state {
        case .preparing:
            L10n.string("Checking the new device…")
        case .comparing:
            L10n.string("Compare the emoji on both devices.")
        case .competingRequests:
            L10n.string("More than one device is asking to link at the same time. To keep your profile safe, none of them can be linked. Cancel on the new device and try again.")
        case .rateLimited(let retryAt):
            L10n.formatted(
                "Too many link requests. Try again %@.",
                DeviceTimePresentation.relative(unixSeconds: retryAt, now: now)
            )
        case .cannotLink:
            L10n.string("This device can’t be linked. It may need to update White Noise.")
        case .tooManyDevices:
            L10n.string("Your profile already has 20 devices. Remove one before linking another.")
        case .linking:
            L10n.string("Linking… Keep White Noise open on both devices.")
        case .linked:
            L10n.string("The new device is linked.")
        case .addedElsewhere(let deviceLabel, let addedByLabel):
            L10n.formatted(
                "%@ was added by %@.",
                LinkedDevicePresentation.name(label: deviceLabel),
                LinkedDevicePresentation.name(label: addedByLabel)
            )
        case .ended(let reason):
            DeviceLinkEndPresentation.message(for: reason)
        }
    }
}

/// Which link request, if any, presents itself on the device already signed in.
nonisolated enum DeviceLinkPromptPolicy {
    /// Keeps the request already on screen while MDK still lists it, through
    /// its finished states, so the user sees the outcome. Otherwise the newest
    /// request that needs attention and that the user hasn't put away.
    static func promptToPresent(
        prompts: [DeviceLinkPromptFfi],
        presentedID: String?,
        dismissedIDs: Set<String>
    ) -> String? {
        if let presentedID, prompts.contains(where: { $0.promptId == presentedID }) {
            return presentedID
        }
        return prompts.last {
            !dismissedIDs.contains($0.promptId) && DeviceLinkPromptPresentation.needsAttention($0.state)
        }?.promptId
    }

    /// Requests still waiting here, newest first, for the Devices screen and
    /// the Chats banner.
    static func pending(_ prompts: [DeviceLinkPromptFfi]) -> [DeviceLinkPromptFfi] {
        prompts.filter { DeviceLinkPromptPresentation.needsAttention($0.state) }.reversed()
    }
}

/// The name a user gives the new device on the device that links it.
nonisolated enum DeviceLabelInput {
    /// MDK's limit, in UTF-8 bytes.
    static let maxBytes = 64

    /// The label to send, or nil while blank or too long.
    static func validated(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxBytes else { return nil }
        return trimmed
    }

    static func isTooLong(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > maxBytes
    }
}

nonisolated enum LinkedDevicePresentation {
    static func name(label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.string("Unnamed device") : trimmed
    }

    /// A device nobody named reads as what it runs ("iOS · whitenoise"), as on the Mac.
    static func name(_ device: LinkedDeviceFfi) -> String {
        let trimmed = device.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if device.isThisDevice { return L10n.string("This device") }
        return clientLine(device) ?? name(label: "")
    }

    /// The device list's detail line: what it runs, unless that is already its name.
    static func detailClientLine(_ device: LinkedDeviceFfi) -> String? {
        let named = !device.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return named || device.isThisDevice ? clientLine(device) : nil
    }

    /// How far a newly linked device is through its chats, while some remain.
    /// On the device that approved the link, the count is chats it has added
    /// the new device to; on the new device, chats it has joined. MDK reports
    /// nothing once progress is unavailable, so neither does this.
    static func chatProgress(_ device: LinkedDeviceFfi, progress: [LinkChatProgressFfi]) -> String? {
        guard let entry = progress.first(where: { $0.slotIdHex == device.slotIdHex }),
              entry.remaining > 0, entry.total >= entry.remaining else { return nil }
        let done = String(entry.total - entry.remaining)
        let total = String(entry.total)
        return entry.onNewDevice
            ? L10n.formatted("Joining chats: %1$@ of %2$@", done, total)
            : L10n.formatted("Adding to chats: %1$@ of %2$@", done, total)
    }

    /// "iOS · whitenoise", or nil before the device has announced either.
    static func clientLine(_ device: LinkedDeviceFfi) -> String? {
        let parts = [device.platform, device.client]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func symbol(_ device: LinkedDeviceFfi) -> String {
        switch device.platform.lowercased() {
        case "ios", "ipados": "iphone"
        case "android": "smartphone"
        case "macos": "laptopcomputer"
        case "linux", "windows": "desktopcomputer"
        default: device.isThisDevice ? "iphone" : "rectangle.on.rectangle"
        }
    }

    /// A short status for the device list, or nil for an ordinary active device.
    static func status(_ device: LinkedDeviceFfi) -> String? {
        if device.removalPending { return L10n.string("Removing…") }
        switch device.status {
        case .leaving: return L10n.string("Signing out…")
        case .moved: return L10n.string("Moved to another device list")
        case .inactive: return L10n.string("Inactive")
        case .active: break
        }
        return device.inactive ? L10n.string("Not seen for 30 days") : nil
    }

    static func lastActive(_ device: LinkedDeviceFfi, now: Date = .now) -> String? {
        guard !device.isThisDevice else { return L10n.string("Active now") }
        guard let lastActiveAt = device.lastActiveAt else { return nil }
        return L10n.formatted(
            "Last active %@", DeviceTimePresentation.relative(unixSeconds: lastActiveAt, now: now)
        )
    }

    /// MDK's own "Inactive" mark without Keep: offer Keep and Remove.
    static func offersInactiveChoice(_ device: LinkedDeviceFfi) -> Bool {
        !device.isThisDevice && device.status == .inactive && !device.keepWhileInactive && !device.removalPending
    }

    static func canRemove(_ device: LinkedDeviceFfi) -> Bool {
        !device.isThisDevice && !device.removalPending && device.status != .leaving
    }

    static func chatCounts(closedToLinkedDevices: UInt32, leftoverChats: UInt32) -> [String] {
        var lines: [String] = []
        if closedToLinkedDevices > 0 {
            lines.append(L10n.plural("%lld chats can’t add your other devices.", Int64(closedToLinkedDevices)))
        }
        if leftoverChats > 0 {
            lines.append(L10n.plural(
                "%lld chats still include a device you removed. A chat admin can remove it.", Int64(leftoverChats)
            ))
        }
        return lines
    }
}

nonisolated enum UnrecognizedSignInPresentation {
    static func title(_ signIn: UnrecognizedSignInFfi) -> String {
        switch signIn.state {
        case .linkedElsewhere: return L10n.string("Linked on another device")
        case .rejectedElsewhere: return L10n.string("Marked as not you on another device")
        case .prompt, .notNow: break
        }
        if signIn.beforeThisDevice { return L10n.string("Signed in before this device") }
        return L10n.string("New sign-in")
    }

    static func detail(_ signIn: UnrecognizedSignInFfi, now: Date = .now) -> String {
        var parts: [String] = []
        let client = signIn.client.trimmingCharacters(in: .whitespacesAndNewlines)
        if !client.isEmpty { parts.append(client) }
        if signIn.beforeThisDevice {
            parts.append(L10n.formatted(
                "last seen %@", DeviceTimePresentation.relative(unixSeconds: signIn.lastSeenAt, now: now)
            ))
        } else {
            parts.append(L10n.formatted(
                "appeared %@", DeviceTimePresentation.relative(unixSeconds: signIn.appearedAt, now: now)
            ))
        }
        if !signIn.signedIn { parts.append(L10n.string("signed out")) }
        return parts.joined(separator: " · ")
    }

    /// Dismiss only ends a sign-in another device already answered.
    static func answeredElsewhere(_ signIn: UnrecognizedSignInFfi) -> Bool {
        signIn.state == .linkedElsewhere || signIn.state == .rejectedElsewhere
    }

    /// "No, start fresh" applies before this device trusts a device group, to
    /// sign-ins found by its first check.
    static func offersStartFresh(signIns: [UnrecognizedSignInFfi], hasDeviceGroup: Bool, startedFresh: Bool) -> Bool {
        !hasDeviceGroup && !startedFresh && signIns.contains { $0.beforeThisDevice && $0.state == .prompt }
    }
}

nonisolated enum CompromiseWarningPresentation {
    static func detail(_ item: CompromiseWarningItemFfi, now: Date = .now) -> String {
        let when = DeviceTimePresentation.relative(unixSeconds: item.occurredAt, now: now)
        switch item.reason {
        case .rejectedSignIn:
            return L10n.formatted("A sign-in marked as not you, %@", when)
        case .foreignOwnSlotKeyPackage:
            return L10n.formatted("A messaging key this device didn’t make, %@", when)
        }
    }
}

nonisolated enum DeviceTimePresentation {
    static func date(unixSeconds: UInt64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(Int64(clamping: unixSeconds)))
    }

    static func relative(unixSeconds: UInt64, now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.currentLocale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date(unixSeconds: unixSeconds), relativeTo: now)
    }
}

/// The one device item the Chats list shows above the chats, most urgent first.
nonisolated enum DeviceAttentionBanner: Equatable {
    case compromiseWarning
    case linkRequest(promptID: String)
    case linkingThisDevice
    case otherProfileLinkRequest(OtherProfileLinkRequest)

    static func select(
        compromiseWarningCount: Int,
        pendingPromptIDs: [String],
        presentedPromptID: String?,
        newDeviceStep: NewDeviceLinkStep,
        newDeviceFlowVisible: Bool,
        otherProfileRequest: OtherProfileLinkRequest? = nil
    ) -> DeviceAttentionBanner? {
        if compromiseWarningCount > 0 { return .compromiseWarning }
        if let promptID = pendingPromptIDs.first(where: { $0 != presentedPromptID }) {
            return .linkRequest(promptID: promptID)
        }
        if newDeviceStep.isInProgress, !newDeviceFlowVisible { return .linkingThisDevice }
        if let otherProfileRequest { return .otherProfileLinkRequest(otherProfileRequest) }
        return nil
    }
}

/// "Signed in on another device?" after setup: offered only on the device that
/// just finished setup in this launch, so it is the new one. An established
/// device's first sign-in check sees every other installation as earlier, and
/// would otherwise be pointed at the wrong side of the link.
nonisolated enum NewDeviceLinkOffer {
    static func shouldOffer(
        finishedSetupThisLaunch: Bool,
        dismissed: Bool,
        signIns: [UnrecognizedSignInFfi],
        hasDeviceGroup: Bool,
        startedFresh: Bool,
        newDeviceState: NewDeviceLinkStateFfi?
    ) -> Bool {
        finishedSetupThisLaunch && !dismissed && newDeviceState == nil
            && UnrecognizedSignInPresentation.offersStartFresh(
                signIns: signIns, hasDeviceGroup: hasDeviceGroup, startedFresh: startedFresh
            )
    }
}

nonisolated enum AccountDevicesActivationPresentation {
    /// Why MDK refused to turn it on. Group details offers the action only on
    /// `eligible`, so this words a refusal that raced a membership change.
    static func blocker(_ activation: AccountDevicesActivationFfi) -> String? {
        switch activation {
        case .eligible, .alreadyEnabled: nil
        case .notAdmin: L10n.string("Only admins can let members’ linked devices join this chat.")
        case .legacyGroup: L10n.string("This chat is too old to add linked devices.")
        case .membersNeedUpdate: L10n.string("Some members need to update White Noise first.")
        case .devicesNeedReplacement:
            L10n.string("A member’s device needs to leave and be added again first.")
        case .deviceLimitExceeded: L10n.string("A member has too many devices in this chat.")
        }
    }
}

/// A link request waiting for one of this device's other signed-in profiles.
nonisolated struct OtherProfileLinkRequest: Identifiable, Equatable {
    let accountIdHex: String
    let accountRef: String
    let promptID: String
    var id: String { "\(accountIdHex):\(promptID)" }

    /// The first request, in the account list's order, still waiting and not
    /// put away. Comparing the emoji needs that profile active, so these are
    /// offered as a switch rather than presented.
    static func first(
        accounts: [(accountIdHex: String, accountRef: String)],
        prompts: [String: [DeviceLinkPromptFfi]],
        dismissedPromptIDs: Set<String>
    ) -> OtherProfileLinkRequest? {
        for account in accounts {
            let waiting = DeviceLinkPromptPolicy.pending(prompts[account.accountIdHex] ?? [])
            if let prompt = waiting.first(where: { !dismissedPromptIDs.contains($0.promptId) }) {
                return OtherProfileLinkRequest(
                    accountIdHex: account.accountIdHex, accountRef: account.accountRef, promptID: prompt.promptId
                )
            }
        }
        return nil
    }
}

/// This device moving to another device list: linking it while it already has
/// one. MDK keeps the old list until the move is Made.
nonisolated enum DeviceGroupMovePresentation {
    static func title(_ state: DeviceGroupMoveStateFfi) -> String {
        switch state {
        case .waitingForWelcome: L10n.string("Waiting to join your other device’s list")
        case .joining: L10n.string("Joining your other device’s list")
        case .made: L10n.string("Moved to your other device’s list")
        case .failed: L10n.string("Couldn’t move to your other device’s list")
        }
    }

    /// Devices left in the old list that MDK recognizes. Each one links from
    /// its own side, as only a new device can start a link.
    static func siblings(_ move: DeviceGroupMoveViewFfi) -> [DeviceGroupMoveSiblingFfi] {
        move.oldSiblings.filter(\.questionSuppressed)
    }

    static func siblingMessage(_ sibling: DeviceGroupMoveSiblingFfi) -> String {
        L10n.formatted(
            "%@ is still in your old device list. Link it from that device.",
            LinkedDevicePresentation.name(label: sibling.label)
        )
    }

    /// Moving while a link this device approved is still joining can end that
    /// link and skip its chat additions, so MDK advises finishing it first.
    static func warnsAboutPendingLink(hasDeviceGroup: Bool, prompts: [DeviceLinkPromptFfi]) -> Bool {
        hasDeviceGroup && prompts.contains { $0.state == .linking }
    }
}

/// Raises the unlinked notice again after a relaunch for a profile the user
/// put off removing, once per launch each, as the Mac does.
nonisolated enum UnlinkedProfileReminder {
    static func next(
        accounts: [AccountSummaryFfi],
        reminded: Set<String>,
        showing: String?
    ) -> String? {
        guard showing == nil else { return nil }
        return accounts.first { $0.unlinked && $0.signedOut && !reminded.contains($0.accountIdHex) }?.accountIdHex
    }
}
