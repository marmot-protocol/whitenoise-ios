import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct DeviceLinkPresentationTests {
    // MARK: Refusals

    @Test func readsTheReasonFromMDKsRuntimeRefusal() {
        let refusal = DeviceGroupRefusal(
            error: MarmotKitError.Runtime(details: "device group refused: device_group_busy")
        )
        #expect(refusal?.reason == "device_group_busy")
        #expect(refusal?.isUnsupported == false)
        #expect(DeviceGroupRefusal(
            error: MarmotKitError.Runtime(details: "device group refused: pairing_unsupported (dev only)")
        )?.isUnsupported == true)
    }

    @Test func otherErrorsAreNotDeviceGroupRefusals() {
        #expect(DeviceGroupRefusal(error: MarmotKitError.Runtime(details: "relay timeout")) == nil)
        #expect(DeviceGroupRefusal(error: MarmotKitError.Runtime(details: "device group refused: ")) == nil)
        #expect(DeviceGroupRefusal(error: CancellationError()) == nil)
    }

    @Test func refusalsAreWordedForPeopleNotAsTheirReasonCode() {
        let reasons = ["device_group_busy", "too_many_devices", "this_device", "something_new"]
        for reason in reasons {
            let message = DeviceGroupRefusal(reason: reason).message
            #expect(!message.isEmpty)
            #expect(!message.contains(reason))
        }
        let error = MarmotKitError.Runtime(details: "device group refused: unknown_device")
        #expect(UserFacingError.message(for: error) == DeviceGroupRefusal(reason: "unknown_device").message)
    }

    // MARK: New device

    @Test func cancelIsOfferedOnlyWhileALinkRuns() {
        let running: [NewDeviceLinkStateFfi] = [.waitingForAnswer, .comparing(code: linkCode()),
                                                .waitingForOtherDevice, .joining]
        #expect(running.allSatisfy { NewDeviceLinkStep($0).isInProgress })
        let stopped: [NewDeviceLinkStateFfi?] = [nil, .linked, .ended(reason: .timedOut)]
        #expect(stopped.allSatisfy { !NewDeviceLinkStep($0).isInProgress })
    }

    @Test func reopeningAfterAFinishedLinkStartsOver() {
        #expect(NewDeviceLinkStep.opening(.linked) == .intro)
        #expect(NewDeviceLinkStep.opening(.ended(reason: .codesDiffer)) == .intro)
        #expect(NewDeviceLinkStep.opening(.joining) == .joining)
        #expect(NewDeviceLinkStep.opening(nil) == .intro)
    }

    // MARK: Requests on a device already signed in

    @Test func theNewestRequestNeedingAttentionPresentsItself() {
        let prompts = [
            linkPrompt("limited", .rateLimited(retryAt: 1)),
            linkPrompt("old", .comparing(code: linkCode())),
            linkPrompt("new", .preparing),
            linkPrompt("done", .ended(reason: .cancelled)),
        ]
        #expect(DeviceLinkPromptPolicy.promptToPresent(prompts: prompts, presentedID: nil, dismissedIDs: []) == "new")
        #expect(DeviceLinkPromptPolicy.promptToPresent(
            prompts: prompts, presentedID: nil, dismissedIDs: ["new"]
        ) == "old")
        // One MDK can't link yet still presents itself, to say why.
        #expect(DeviceLinkPromptPolicy.promptToPresent(
            prompts: prompts, presentedID: nil, dismissedIDs: ["new", "old"]
        ) == "limited")
        #expect(DeviceLinkPromptPolicy.promptToPresent(
            prompts: prompts, presentedID: nil, dismissedIDs: ["new", "old", "limited"]
        ) == nil)
    }

    @Test func aRequestThatCantBeLinkedYetOffersOnlyNotNow() {
        let waiting: [DeviceLinkPromptStateFfi] = [
            .rateLimited(retryAt: 1), .cannotLink(missing: ["x"]), .tooManyDevices, .competingRequests,
        ]
        for state in waiting {
            #expect(DeviceLinkPromptPresentation.needsAttention(state))
            #expect(DeviceLinkPromptPresentation.canDecline(state))
        }
        // Once linking runs or ends there is nothing left to decline.
        for state: DeviceLinkPromptStateFfi in [.linking, .linked, .ended(reason: .cancelled)] {
            #expect(!DeviceLinkPromptPresentation.canDecline(state))
        }
    }

    @Test func aRequestOnScreenStaysThroughItsOutcome() {
        let prompts = [linkPrompt("a", .linked), linkPrompt("b", .preparing)]
        #expect(DeviceLinkPromptPolicy.promptToPresent(prompts: prompts, presentedID: "a", dismissedIDs: []) == "a")
        // Once MDK stops listing it, the sheet moves on.
        #expect(DeviceLinkPromptPolicy.promptToPresent(
            prompts: [linkPrompt("b", .preparing)], presentedID: "a", dismissedIDs: []
        ) == "b")
    }

    @Test func pendingRequestsListNewestFirstAndSkipFinishedOnes() {
        let prompts = [
            linkPrompt("first", .comparing(code: linkCode())),
            linkPrompt("finished", .addedElsewhere(deviceLabel: "Mac", addedByLabel: "Phone")),
            linkPrompt("second", .linking),
        ]
        #expect(DeviceLinkPromptPolicy.pending(prompts).map(\.promptId) == ["second", "first"])
    }

    // MARK: Device names

    @Test func aDeviceNameMustBeNonBlankAndFitMDKsByteLimit() {
        #expect(DeviceLabelInput.validated("  Work iPhone ") == "Work iPhone")
        #expect(DeviceLabelInput.validated("   ") == nil)
        let fits = String(repeating: "a", count: DeviceLabelInput.maxBytes)
        #expect(DeviceLabelInput.validated(fits) == fits)
        // Few characters, but too many UTF-8 bytes.
        let emoji = String(repeating: "📱", count: DeviceLabelInput.maxBytes / 4 + 1)
        #expect(emoji.count < DeviceLabelInput.maxBytes)
        #expect(DeviceLabelInput.validated(emoji) == nil)
        #expect(DeviceLabelInput.isTooLong(emoji))
    }

    @Test func anUnnamedDeviceStillHasAName() {
        let this = linkedDevice(slot: hex("a"), isThisDevice: true)
        let other = linkedDevice(slot: hex("b"))
        #expect(!LinkedDevicePresentation.name(this).isEmpty)
        #expect(!LinkedDevicePresentation.name(other).isEmpty)
        #expect(LinkedDevicePresentation.name(this) != LinkedDevicePresentation.name(other))
        #expect(LinkedDevicePresentation.name(linkedDevice(slot: hex("c"), label: " iPad ")) == "iPad")
        // An unnamed sibling reads as what it runs, and its detail line doesn't repeat that.
        #expect(LinkedDevicePresentation.name(other) == LinkedDevicePresentation.clientLine(other))
        #expect(LinkedDevicePresentation.detailClientLine(other) == nil)
        #expect(LinkedDevicePresentation.detailClientLine(linkedDevice(slot: hex("c"), label: "iPad")) != nil)
        // Before it announces a platform or client, it still has a name.
        var bare = other
        bare.platform = ""
        bare.client = ""
        #expect(!LinkedDevicePresentation.name(bare).isEmpty)
    }

    /// Progress shows on the device MDK names, only while chats remain, and says
    /// which side of the link this device is on.
    @Test func chatProgressShowsOnlyWhileChatsRemain() {
        let newDevice = linkedDevice(slot: hex("b"))
        func progress(_ entries: [LinkChatProgressFfi]) -> String? {
            LinkedDevicePresentation.chatProgress(newDevice, progress: entries)
        }
        let approving = LinkChatProgressFfi(slotIdHex: hex("b"), onNewDevice: false, total: 10, remaining: 3)
        let joining = LinkChatProgressFfi(slotIdHex: hex("b"), onNewDevice: true, total: 10, remaining: 3)
        #expect(progress([approving]) != nil)
        #expect(progress([joining]) != nil)
        #expect(progress([approving]) != progress([joining]))
        #expect(progress([]) == nil)
        #expect(progress([LinkChatProgressFfi(slotIdHex: hex("c"), onNewDevice: false, total: 10, remaining: 3)]) == nil)
        #expect(progress([LinkChatProgressFfi(slotIdHex: hex("b"), onNewDevice: false, total: 10, remaining: 0)]) == nil)
        // A count MDK can't have meant shows nothing rather than a negative number.
        #expect(progress([LinkChatProgressFfi(slotIdHex: hex("b"), onNewDevice: false, total: 2, remaining: 5)]) == nil)
    }

    // MARK: Device actions

    @Test func keepAndRemoveAreOfferedOnlyForAnUnkeptInactiveSibling() {
        #expect(LinkedDevicePresentation.offersInactiveChoice(linkedDevice(slot: hex("a"), status: .inactive)))
        #expect(!LinkedDevicePresentation.offersInactiveChoice(
            linkedDevice(slot: hex("a"), status: .inactive, keepWhileInactive: true)
        ))
        #expect(!LinkedDevicePresentation.offersInactiveChoice(linkedDevice(slot: hex("a"), status: .active)))
        #expect(!LinkedDevicePresentation.offersInactiveChoice(
            linkedDevice(slot: hex("a"), isThisDevice: true, status: .inactive)
        ))
    }

    @Test func thisDeviceAndOnesAlreadyLeavingCantBeRemoved() {
        #expect(LinkedDevicePresentation.canRemove(linkedDevice(slot: hex("a"))))
        #expect(!LinkedDevicePresentation.canRemove(linkedDevice(slot: hex("a"), isThisDevice: true)))
        #expect(!LinkedDevicePresentation.canRemove(linkedDevice(slot: hex("a"), removalPending: true)))
        #expect(!LinkedDevicePresentation.canRemove(linkedDevice(slot: hex("a"), status: .leaving)))
    }

    // MARK: Sign-ins

    @Test func startFreshAppliesOnlyToAnUnlinkedDeviceWithEarlierSignIns() {
        let earlier = [unrecognizedSignIn(slot: hex("a"), beforeThisDevice: true)]
        #expect(UnrecognizedSignInPresentation.offersStartFresh(
            signIns: earlier, hasDeviceGroup: false, startedFresh: false
        ))
        #expect(!UnrecognizedSignInPresentation.offersStartFresh(
            signIns: earlier, hasDeviceGroup: true, startedFresh: false
        ))
        #expect(!UnrecognizedSignInPresentation.offersStartFresh(
            signIns: earlier, hasDeviceGroup: false, startedFresh: true
        ))
        #expect(!UnrecognizedSignInPresentation.offersStartFresh(
            signIns: [unrecognizedSignIn(slot: hex("a"))], hasDeviceGroup: false, startedFresh: false
        ))
        #expect(!UnrecognizedSignInPresentation.offersStartFresh(
            signIns: [unrecognizedSignIn(slot: hex("a"), beforeThisDevice: true, state: .notNow)],
            hasDeviceGroup: false, startedFresh: false
        ))
    }

    // MARK: Chats banner

    @Test func theChatsBannerShowsTheMostUrgentDeviceItem() {
        func select(
            warnings: Int = 0, pending: [String] = [], presented: String? = nil,
            step: NewDeviceLinkStep = .intro, flowVisible: Bool = false
        ) -> DeviceAttentionBanner? {
            DeviceAttentionBanner.select(
                compromiseWarningCount: warnings, pendingPromptIDs: pending, presentedPromptID: presented,
                newDeviceStep: step, newDeviceFlowVisible: flowVisible
            )
        }
        #expect(select(warnings: 1, pending: ["p"]) == .compromiseWarning)
        #expect(select(pending: ["p"]) == .linkRequest(promptID: "p"))
        // The request already on screen needs no banner.
        #expect(select(pending: ["p"], presented: "p") == nil)
        #expect(select(step: .joining) == .linkingThisDevice)
        #expect(select(step: .joining, flowVisible: true) == nil)
        #expect(select() == nil)
    }

    @Test func onlyADeviceThatJustFinishedSetupIsOfferedToLinkItself() {
        func offer(
            finished: Bool = true, dismissed: Bool = false,
            signIns: [UnrecognizedSignInFfi] = [unrecognizedSignIn(slot: hex("a"), beforeThisDevice: true)],
            hasDeviceGroup: Bool = false, newDevice: NewDeviceLinkStateFfi? = nil
        ) -> Bool {
            NewDeviceLinkOffer.shouldOffer(
                finishedSetupThisLaunch: finished, dismissed: dismissed, signIns: signIns,
                hasDeviceGroup: hasDeviceGroup, startedFresh: false, newDeviceState: newDevice
            )
        }
        #expect(offer())
        // An established device sees every other installation as earlier: never offered there.
        #expect(!offer(finished: false))
        #expect(!offer(dismissed: true))
        #expect(!offer(signIns: [unrecognizedSignIn(slot: hex("a"))]))
        #expect(!offer(hasDeviceGroup: true))
        #expect(!offer(newDevice: .waitingForAnswer))
        #expect(!offer(newDevice: .ended(reason: .timedOut)))
    }

    // MARK: Group activation

    @Test func onlyAnEligibleChatOffersTurningOnLinkedDevices() {
        let all: [AccountDevicesActivationFfi] = [
            .eligible, .notAdmin, .alreadyEnabled, .legacyGroup, .membersNeedUpdate,
            .devicesNeedReplacement, .deviceLimitExceeded,
        ]
        for activation in all {
            let explained = AccountDevicesActivationPresentation.blocker(activation) != nil
            #expect(explained == (activation != .eligible && activation != .alreadyEnabled))
        }
    }
}

extension DeviceLinkPresentationTests {
    @Test func anotherProfilesWaitingRequestIsOfferedInAccountOrderUntilPutAway() {
        let accounts = [(accountIdHex: hex("a1"), accountRef: "first"), (accountIdHex: hex("a2"), accountRef: "second")]
        let prompts = [
            hex("a1"): [linkPrompt("finished", .linked)],
            hex("a2"): [linkPrompt("waiting", .comparing(code: linkCode()))],
        ]
        let offered = OtherProfileLinkRequest.first(accounts: accounts, prompts: prompts, dismissedPromptIDs: [])
        #expect(offered?.accountRef == "second")
        #expect(offered?.promptID == "waiting")
        #expect(OtherProfileLinkRequest.first(accounts: accounts, prompts: prompts, dismissedPromptIDs: ["waiting"]) == nil)
        #expect(OtherProfileLinkRequest.first(accounts: accounts, prompts: [:], dismissedPromptIDs: []) == nil)
    }
}

// MARK: Moving this device

extension DeviceLinkPresentationTests {
    @Test func onlyRecognizedOldDevicesAreOfferedWithTheirNames() {
        let move = DeviceGroupMoveViewFfi(
            moveId: "move",
            state: .made,
            oldSiblings: [
                DeviceGroupMoveSiblingFfi(slotIdHex: hex("b1"), label: "Work Mac", questionSuppressed: true),
                DeviceGroupMoveSiblingFfi(slotIdHex: hex("b2"), label: "Old Phone", questionSuppressed: false),
                DeviceGroupMoveSiblingFfi(slotIdHex: hex("b3"), label: "  ", questionSuppressed: true),
            ],
            overriddenRejectionSlots: []
        )
        let offered = DeviceGroupMovePresentation.siblings(move)
        #expect(offered.map(\.slotIdHex) == [hex("b1"), hex("b3")])
        #expect(DeviceGroupMovePresentation.siblingMessage(offered[0]).contains("Work Mac"))
        #expect(DeviceGroupMovePresentation.siblingMessage(offered[1])
            .contains(LinkedDevicePresentation.name(label: "")))
    }

    @Test func movingWarnsOnlyWhileALinkThisDeviceApprovedIsStillJoining() {
        let joining = [linkPrompt("p1", .linking)]
        #expect(DeviceGroupMovePresentation.warnsAboutPendingLink(hasDeviceGroup: true, prompts: joining))
        #expect(!DeviceGroupMovePresentation.warnsAboutPendingLink(hasDeviceGroup: false, prompts: joining))
        let settled = [linkPrompt("p2", .comparing(code: linkCode())), linkPrompt("p3", .linked)]
        #expect(!DeviceGroupMovePresentation.warnsAboutPendingLink(hasDeviceGroup: true, prompts: settled))
    }

    // MARK: Unlinked profiles

    @Test func anUnlinkedProfileIsRaisedAgainOncePerLaunchAndOneAtATime() {
        var unlinked = accountSummary("old", byte: "c1", signedOut: true)
        unlinked.unlinked = true
        var other = accountSummary("other", byte: "c2", signedOut: true)
        other.unlinked = true
        let signedOut = accountSummary("plain", byte: "c3", signedOut: true)
        let accounts = [signedOut, unlinked, other]

        #expect(UnlinkedProfileReminder.next(accounts: accounts, reminded: [], showing: nil) == hex("c1"))
        #expect(UnlinkedProfileReminder.next(accounts: accounts, reminded: [hex("c1")], showing: nil) == hex("c2"))
        #expect(UnlinkedProfileReminder.next(accounts: accounts, reminded: [], showing: hex("c2")) == nil)
        #expect(UnlinkedProfileReminder.next(accounts: accounts, reminded: [hex("c1"), hex("c2")], showing: nil) == nil)
        #expect(UnlinkedProfileReminder.next(accounts: [signedOut], reminded: [], showing: nil) == nil)
    }
}
