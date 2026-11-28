import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct DeviceLinkStoreTests {
    // Each event must replace the corresponding presented MDK state. A missing
    // switch case or a read wired to the wrong binding leaves the old value up.
    @Test(.marmotRuntimeConcurrencyLimit)
    func eventsRefreshTheirPresentedState() async throws {
        try await withTestClient { client in
            let f = DeviceLinkStoreFixture(client: client)
            let store = f.makeStore()
            await store.refresh(using: f.appState)
            let id = f.primary.accountIdHex
            let label = f.primary.label

            f.snapshots[label] = deviceLinkSnapshot(prompts: [linkPrompt("incoming", .preparing)])
            store.observe(.deviceLinkChanged(accountIdHex: id, accountLabel: label), using: f.appState)
            try await eventually { store.presentedPromptID == "incoming" }

            f.roster = [linkedDevice(slot: hex("b1"), isThisDevice: true), linkedDevice(slot: hex("b2"))]
            f.closed = 3
            f.leftover = 2
            f.fresh = true
            store.observe(.linkedDevicesChanged(accountIdHex: id, accountLabel: label), using: f.appState)
            try await eventually { store.startedFresh }
            #expect(store.thisDevice?.slotIdHex == hex("b1"))
            #expect(store.otherDevices.map(\.slotIdHex) == [hex("b2")])
            #expect(store.device(hex("b2")) == f.roster[1])
            #expect(store.chatsClosedToLinkedDevices == 3)
            #expect(store.leftoverChats == 2)

            f.signIns = [unrecognizedSignIn(slot: hex("c1"))]
            store.observe(.unrecognizedSignInsChanged(accountIdHex: id, accountLabel: label), using: f.appState)
            try await eventually { store.signIns == f.signIns }
            f.warnings = [CompromiseWarningItemFfi(
                reason: .foreignOwnSlotKeyPackage, slotIdHex: hex("d1"), keyPackageRefHex: hex("d2"), occurredAt: 1
            )]
            store.observe(.compromiseWarningChanged(accountIdHex: id, accountLabel: label), using: f.appState)
            try await eventually { store.compromiseWarning == f.warnings }
            #expect(store.attentionBanner(using: f.appState) == .compromiseWarning)

            f.overdue = true
            store.observe(.keyPackageRefreshOverdueChanged(accountIdHex: id, accountLabel: label), using: f.appState)
            try await eventually { store.keyPackageRefreshOverdue }
            f.imports = [ChatHistoryImportFfi(groupIdHex: hex("e1"), state: .receiving(retrying: true))]
            store.observe(.chatHistoryImportsChanged(accountIdHex: id, accountLabel: label), using: f.appState)
            try await eventually { store.historyImports[hex("e1")] == .receiving(retrying: true) }
            f.imports = []
            store.observe(.chatHistoryImportsChanged(accountIdHex: id, accountLabel: label), using: f.appState)
            try await eventually { store.historyImports.isEmpty }
        }
    }

    // Tickets must reject an older completion even when the account and runtime
    // still match. This covers both active and other-profile reads.
    @Test(.marmotRuntimeConcurrencyLimit, arguments: [false, true])
    func newerSnapshotWinsWhenOlderReadCompletesLast(otherProfile: Bool) async throws {
        try await withTestClient { client in
            let f = DeviceLinkStoreFixture(client: client)
            let store = f.makeStore()
            await store.refresh(using: f.appState)
            let account = otherProfile ? f.secondary : f.primary
            let checkpoint = AsyncTestCheckpoint()
            var reads = 0
            f.snapshotRead = { ref in
                guard ref == account.label else { return deviceLinkSnapshot() }
                reads += 1
                if reads == 1 {
                    await checkpoint.pause()
                    return deviceLinkSnapshot(prompts: [linkPrompt("old", .preparing)])
                }
                return deviceLinkSnapshot(prompts: [linkPrompt("new", .preparing)])
            }
            let older = Task { await store.refresh(using: f.appState) }
            await checkpoint.waitUntilPaused()
            await store.refresh(using: f.appState)
            await checkpoint.release()
            await older.value
            if otherProfile {
                #expect(store.otherProfileRequest(using: f.appState)?.promptID == "new")
            } else {
                #expect(store.presentedPromptID == "new")
                #expect(store.prompt("old") == nil)
            }
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func profileSwitchRejectsOldReadsAndClearsOldPresentation() async throws {
        try await withTestClient { client in
            let f = DeviceLinkStoreFixture(client: client)
            let store = f.makeStore()
            await store.refresh(using: f.appState)
            store.present(.linkThisDevice)
            let checkpoint = AsyncTestCheckpoint()
            f.snapshotRead = { [primary = f.primary.label] ref in
                if ref == primary { await checkpoint.pause() }
                return deviceLinkSnapshot(prompts: [linkPrompt(ref, .preparing)])
            }
            let oldRead = Task { await store.refresh(using: f.appState) }
            await checkpoint.waitUntilPaused()
            f.appState.activeAccountRef = f.secondary.label
            // Reject even before the store gets its next refresh/scope update.
            await checkpoint.release()
            await oldRead.value
            #expect(store.snapshot?.prompts.isEmpty == true)
            f.snapshotRead = nil
            f.snapshots[f.secondary.label] = deviceLinkSnapshot(prompts: [linkPrompt("secondary", .preparing)])
            await store.refresh(using: f.appState)
            #expect(store.presentedPromptID == "secondary")
            #expect(store.prompt(f.primary.label) == nil)
            #expect(!store.offersNewDeviceLink)
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func crossProfileEventsDismissalAndReviewKeepTheRequestOnItsOwnProfile() async throws {
        try await withTestClient { client in
            let f = DeviceLinkStoreFixture(client: client)
            let store = f.makeStore()
            await store.refresh(using: f.appState)
            f.snapshots[f.secondary.label] = deviceLinkSnapshot(prompts: [linkPrompt("other", .preparing)])
            store.observe(.deviceLinkChanged(accountIdHex: f.secondary.accountIdHex, accountLabel: f.secondary.label),
                          using: f.appState)
            try await eventually { store.otherProfileRequest(using: f.appState) != nil }
            let request = try #require(store.otherProfileRequest(using: f.appState))
            #expect(store.sheet == nil)
            store.dismissOtherProfileRequest(request)
            #expect(store.otherProfileRequest(using: f.appState) == nil)
            #expect(store.otherProfileRequests(using: f.appState) == [request])

            // A failed switch must restore the banner, so the user can try again.
            f.switchAccount = { _, _ in }
            await store.reviewOtherProfileRequest(request, using: f.appState)
            #expect(store.otherProfileRequest(using: f.appState) == request)
            #expect(store.sheet == nil)
            f.switchAccount = nil
            await store.reviewOtherProfileRequest(request, using: f.appState)
            #expect(f.appState.activeAccountRef == f.secondary.label)
            #expect(store.presentedPromptID == request.promptID)
            #expect(store.otherProfileRequests(using: f.appState).isEmpty)

            f.appState.accountStore.accounts = [f.secondary]
            await store.refresh(using: f.appState)
            #expect(store.otherProfilePrompts.isEmpty)
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func sheetsRespectUserDismissalAndDoNotReplaceTheNewDeviceFlow() async throws {
        try await withTestClient { client in
            let f = DeviceLinkStoreFixture(client: client)
            let store = f.makeStore()
            await store.refresh(using: f.appState)
            store.present(.addDevice)
            await store.refresh(using: f.appState)
            #expect(store.sheet == .addDevice)
            f.snapshots[f.primary.label] = deviceLinkSnapshot(prompts: [linkPrompt("first", .preparing)])
            await store.refresh(using: f.appState)
            #expect(store.presentedPromptID == "first")
            store.sheetDismissed()
            await store.refresh(using: f.appState)
            #expect(store.sheet == nil)
            #expect(store.attentionBanner(using: f.appState) == .linkRequest(promptID: "first"))
            store.present(.approve(promptID: "first"))
            #expect(store.presentedPromptID == "first")

            f.snapshots[f.primary.label] = deviceLinkSnapshot(prompts: [linkPrompt("next", .preparing)])
            await store.refresh(using: f.appState)
            store.sheetDismissed(promptID: "first")
            #expect(store.presentedPromptID == "next")
            store.present(.linkThisDevice)
            f.snapshots[f.primary.label] = deviceLinkSnapshot(prompts: [linkPrompt("latest", .preparing)])
            await store.refresh(using: f.appState)
            #expect(store.sheet == .linkThisDevice)
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func setupOfferIsAccountBoundAndStartsLinkOnlyOnce() async throws {
        try await withTestClient { client in
            let f = DeviceLinkStoreFixture(client: client)
            f.signIns = [unrecognizedSignIn(slot: hex("b1"), beforeThisDevice: true)]
            let store = f.makeStore()
            await store.refresh(using: f.appState)
            #expect(!store.offersNewDeviceLink)
            store.noteSetupFinished(accountIdHex: f.primary.accountIdHex)
            #expect(store.offersNewDeviceLink)
            store.present(.addDevice)
            #expect(!store.offersNewDeviceLink)
            store.sheetDismissed()
            store.dismissNewDeviceOffer()
            #expect(!store.offersNewDeviceLink)
            store.noteSetupFinished(accountIdHex: f.primary.accountIdHex)
            store.linkFromNewDeviceOffer()
            #expect(store.sheet == .linkThisDevice)
            #expect(store.consumeStartsLinkOnPresent())
            #expect(!store.consumeStartsLinkOnPresent())
            store.sheetDismissed()
            #expect(!store.offersNewDeviceLink)
            store.noteSetupFinished(accountIdHex: f.primary.accountIdHex)
            f.appState.activeAccountRef = f.secondary.label
            await store.refresh(using: f.appState)
            #expect(!store.offersNewDeviceLink)
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func firstLinkNamesThisDeviceAfterRosterArrivesAndRetriesOnlyBusy() async throws {
        try await withTestClient { client in
            let f = DeviceLinkStoreFixture(client: client)
            let store = f.makeStore()
            await store.refresh(using: f.appState)
            f.approval = { [primary = f.primary.label] account, prompt, label, chats, history in
                #expect(account == primary)
                #expect(prompt == "request")
                #expect(label == "New iPad")
                #expect(!chats && history)
                return deviceLinkSnapshot(prompts: [linkPrompt(prompt, .linking)])
            }
            try await store.link(promptID: "request", label: "New iPad", addToAllChats: false, bringHistory: true,
                                 thisDeviceLabel: "Work iPhone", using: f.appState)
            #expect(!store.warnsAboutPendingLinkBeforeMove)
            var names: [String] = []
            f.rename = { [primary = f.primary.label] account, slot, name in
                #expect(account == primary)
                #expect(slot == hex("b1"))
                names.append(name)
                if names.count == 1 { throw MarmotKitError.Runtime(details: "device group refused: device_group_busy") }
            }
            f.snapshots[f.primary.label] = deviceLinkSnapshot(prompts: [linkPrompt("request", .linking)])
            f.roster = [linkedDevice(slot: hex("b1"), isThisDevice: true)]
            await store.refresh(using: f.appState)
            #expect(store.warnsAboutPendingLinkBeforeMove)
            #expect(names == ["Work iPhone"])
            await store.refresh(using: f.appState)
            #expect(names == ["Work iPhone", "Work iPhone"])
            await store.refresh(using: f.appState)
            #expect(names.count == 2)
            f.snapshots[f.primary.label] = deviceLinkSnapshot(prompts: [linkPrompt("request", .linked)])
            await store.refresh(using: f.appState)
            #expect(!store.warnsAboutPendingLinkBeforeMove)
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func keyPackageRetryStaysOnCapturedAccountAndDropsItsStaleResult() async throws {
        try await withTestClient { client in
            let f = DeviceLinkStoreFixture(client: client)
            let store = f.makeStore()
            await store.refresh(using: f.appState)
            let checkpoint = AsyncTestCheckpoint()
            var starts: [String] = []
            var rotations: [String] = []
            f.start = { marmot, account in
                #expect(marmot === client.marmot)
                starts.append(account)
                if starts.count == 1 {
                    await checkpoint.pause()
                    throw MarmotKitError.Runtime(details: "device group refused: key_package_not_published")
                }
                return deviceLinkSnapshot(newDevice: .waitingForAnswer)
            }
            f.rotate = { marmot, account in
                #expect(marmot === client.marmot)
                rotations.append(account)
            }
            let action = Task { try await store.startLink(using: f.appState) }
            await checkpoint.waitUntilPaused()
            f.appState.activeAccountRef = f.secondary.label
            await store.refresh(using: f.appState)
            await checkpoint.release()
            try await action.value
            #expect(starts == [f.primary.label, f.primary.label])
            #expect(rotations == [f.primary.label])
            #expect(store.newDeviceStep == .intro)
            #expect(store.snapshot?.newDevice == nil)
        }
    }
}

extension DeviceLinkStoreTests {
    @Test(.marmotRuntimeConcurrencyLimit)
    func transientReadErrorsKeepLastValuesAndSuccessfulReadsClearErrors() async throws {
        try await withTestClient { client in
            let f = DeviceLinkStoreFixture(client: client)
            f.roster = [linkedDevice(slot: hex("b1"))]
            f.signIns = [unrecognizedSignIn(slot: hex("c1"))]
            let store = f.makeStore()
            await store.refresh(using: f.appState)
            let failure = MarmotKitError.Runtime(details: "local device read failed")
            f.rosterRead = { throw failure }
            f.signInsRead = { throw failure }
            await store.refresh(using: f.appState)
            #expect(store.devices == f.roster)
            #expect(store.signIns == f.signIns)
            #expect(store.devicesLoadError == UserFacingError.message(for: failure))
            #expect(store.signInsLoadError == UserFacingError.message(for: failure))
            #expect(store.isAvailable)
            f.rosterRead = nil
            f.signInsRead = nil
            f.roster = []
            f.signIns = []
            await store.refresh(using: f.appState)
            #expect(store.devices.isEmpty && store.signIns.isEmpty)
            #expect(store.devicesLoadError == nil && store.signInsLoadError == nil)
            f.snapshotRead = { _ in throw MarmotKitError.Runtime(details: "device group refused: pairing_unsupported") }
            await store.refresh(using: f.appState)
            #expect(!store.isAvailable)
            #expect(store.attentionBanner(using: f.appState) == nil)
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func failedApprovalRestoresTheEarlierPendingName() async throws {
        try await withTestClient { client in
            let f = DeviceLinkStoreFixture(client: client)
            let store = f.makeStore()
            await store.refresh(using: f.appState)
            f.approval = { _, _, _, _, _ in deviceLinkSnapshot() }
            try await store.link(promptID: "first", label: "iPad", addToAllChats: true, bringHistory: false,
                                 thisDeviceLabel: "Original name", using: f.appState)
            let failure = MarmotKitError.Runtime(details: "device group refused: unknown_prompt")
            f.approval = { _, _, _, _, _ in throw failure }
            await #expect(throws: failure) {
                try await store.link(promptID: "second", label: "Mac", addToAllChats: true, bringHistory: false,
                                     thisDeviceLabel: "Failed name", using: f.appState)
            }
            var names: [String] = []
            f.rename = { _, _, label in names.append(label) }
            f.roster = [linkedDevice(slot: hex("b1"), isThisDevice: true)]
            await store.refresh(using: f.appState)
            #expect(names == ["Original name"])
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit, arguments: [false, true])
    func pendingNameIsRetiredAfterTerminalFailureOrAnExistingRosterName(alreadyNamed: Bool) async throws {
        try await withTestClient { client in
            let f = DeviceLinkStoreFixture(client: client)
            let store = f.makeStore()
            await store.refresh(using: f.appState)
            f.approval = { _, _, _, _, _ in deviceLinkSnapshot() }
            try await store.link(promptID: "p", label: "iPad", addToAllChats: true, bringHistory: true,
                                 thisDeviceLabel: "Proposed", using: f.appState)
            var names: [String] = []
            f.rename = { _, _, label in
                names.append(label)
                throw MarmotKitError.Runtime(details: "device group refused: unknown_device")
            }
            f.roster = [linkedDevice(slot: hex("b1"), isThisDevice: true, label: alreadyNamed ? "Roster name" : "")]
            await store.refresh(using: f.appState)
            f.roster = [linkedDevice(slot: hex("b1"), isThisDevice: true)]
            await store.refresh(using: f.appState)
            #expect(names == (alreadyNamed ? [] : ["Proposed"]))
        }
    }

    // Later retains the launch reminder; removal retires both queued and shown
    // notices. Neither path should drop a different profile's pending alert.
    @Test func unlinkedLaterAndRemovalPreserveOtherProfilesNotices() async throws {
        let state = AppState.test()
        let store = state.deviceLinks
        var profiles = [accountSummary("one", byte: "d1", signedOut: true),
                        accountSummary("two", byte: "d2", signedOut: true),
                        accountSummary("three", byte: "d3", signedOut: true),
                        accountSummary("four", byte: "d4", signedOut: true)]
        for index in profiles.indices { profiles[index].unlinked = true }
        store.remindUnlinkedProfiles(profiles)
        #expect(store.unlinkedNotice?.accountIdHex == profiles[0].accountIdHex)
        store.unlinkedNoticeDismissed() // Later
        store.remindUnlinkedProfiles(profiles)
        #expect(store.unlinkedNotice?.accountIdHex == profiles[1].accountIdHex)
        store.observe(.deviceUnlinked(accountIdHex: profiles[2].accountIdHex, accountLabel: profiles[2].label), using: state)
        store.observe(.deviceUnlinked(accountIdHex: profiles[3].accountIdHex, accountLabel: profiles[3].label), using: state)
        store.retireUnlinkedNotice(profiles[2].accountIdHex) // removed while queued
        store.retireUnlinkedNotice(profiles[1].accountIdHex) // removed while shown
        try await eventually { store.unlinkedNotice?.accountIdHex == profiles[3].accountIdHex }
        store.retireUnlinkedNotice(profiles[3].accountIdHex)
        #expect(store.unlinkedNotice == nil)
        store.remindUnlinkedProfiles(profiles)
        #expect(store.unlinkedNotice == nil)
        // A new launch has a fresh store, so Later is offered again.
        let nextLaunch = DeviceLinkStore()
        nextLaunch.remindUnlinkedProfiles(profiles)
        #expect(nextLaunch.unlinkedNotice?.accountIdHex == profiles[0].accountIdHex)
    }

    @Test(.marmotRuntimeConcurrencyLimit)
    func unlinkingTheActiveProfileClearsItsDeviceStateButKeepsTheNotice() async throws {
        try await withTestClient { client in
            let f = DeviceLinkStoreFixture(client: client)
            f.roster = [linkedDevice(slot: hex("b1"), isThisDevice: true)]
            let store = f.makeStore()
            await store.refresh(using: f.appState)
            store.present(.linkThisDevice)
            store.observe(.deviceUnlinked(accountIdHex: f.primary.accountIdHex, accountLabel: f.primary.label),
                          using: f.appState)
            #expect(!store.isAvailable)
            #expect(store.devices.isEmpty)
            #expect(store.sheet == nil)
            #expect(store.unlinkedNotice?.accountIdHex == f.primary.accountIdHex)
            await #expect(throws: ForegroundRuntimeMutationError.runtimeUnavailable) {
                try await store.startLink(using: f.appState)
            }
        }
    }
}

extension DeviceLinkStoreTests {
    @Test(.marmotRuntimeConcurrencyLimit)
    func runtimeReplacementRejectsOldReadsAndKeepsTheOpenDeviceFlow() async throws {
        try await withTestClient { original in
            try await withTestClient { replacement in
                let state = AppState.test(
                    client: original,
                    runtimeClientFactory: { _, _, _, _ in replacement },
                    runtimeStarter: { _ in }
                )
                let f = DeviceLinkStoreFixture(client: original, state: state)
                // Onboarding owns a runtime without launching chat maintenance.
                state.setPhase(.onboarding)
                f.roster = [linkedDevice(slot: hex("b1"), isThisDevice: true)]
                let store = f.makeStore()
                await store.refresh(using: state)
                store.present(.linkThisDevice)
                let generation = state.runtimeGeneration
                let checkpoint = AsyncTestCheckpoint()
                f.snapshotRead = { [primary = f.primary.label] account in
                    if account == primary { await checkpoint.pause() }
                    return deviceLinkSnapshot(newDevice: .linked)
                }
                let oldRead = Task { await store.refresh(using: state) }
                await checkpoint.waitUntilPaused()
                await state.runtimeLifecycle.startRuntimeSuspension().value
                #expect(!state.canUseLiveRuntime)
                await store.refresh(using: state)
                #expect(store.sheet == .linkThisDevice)
                await state.runtimeLifecycle.startForegroundActivation().value
                #expect(state.runtimeGeneration > generation)
                let liveClient = try state.currentMarmotClient()
                #expect(liveClient === replacement)
                // The isolated MDK account store is empty; restore the presented
                // profile so only runtime generation distinguishes this scope.
                state.accountStore.accounts = [f.primary, f.secondary]
                state.activeAccountRef = f.primary.label
                await checkpoint.release()
                await oldRead.value
                #expect(store.snapshot?.newDevice == nil)
                #expect(store.sheet == .linkThisDevice)

                f.snapshotRead = nil
                let rosterCheckpoint = AsyncTestCheckpoint()
                f.rosterRead = {
                    await rosterCheckpoint.pause()
                    return []
                }
                let newRead = Task { await store.refresh(using: state) }
                await rosterCheckpoint.waitUntilPaused()
                #expect(store.sheet == .linkThisDevice)
                #expect(store.thisDevice?.slotIdHex == hex("b1"))
                await rosterCheckpoint.release()
                await newRead.value
                #expect(store.devices.isEmpty)
                #expect(store.isAvailable)
            }
        }
    }
}
