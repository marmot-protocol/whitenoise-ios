import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct AccountSetupRelayDraftTests {
    @Test func editingAProposalPreservesEachRelaysRoles() throws {
        let draft = AccountSetupRelayDraft(proposal: proposal(
            reads: ["wss://read.example.com", "wss://both.example.com"],
            writes: ["wss://both.example.com", "wss://write.example.com"]
        ))
        #expect(draft.entries.count == 3)
        let selection = try draft.selection()
        #expect(selection.reads == ["wss://read.example.com", "wss://both.example.com"])
        #expect(selection.writes == ["wss://both.example.com", "wss://write.example.com"])
    }

    @Test func invalidProposalAddressRemainsAvailableForCorrectionAndBlocksTheWholeList() throws {
        var draft = AccountSetupRelayDraft(proposal: proposal(
            reads: ["ws://127.0.0.1"], writes: ["wss://write.example.com"]
        ))
        let invalid = try #require(draft.entries.first)
        #expect(invalid.address == "ws://127.0.0.1")
        #expect(throws: AccountSetupRelayDraft.ValidationError.invalidAddress(invalid.id)) {
            try draft.selection()
        }
        draft.entries[0].address = "wss://read.example.com"
        let selection = try draft.selection()
        #expect(selection.reads == ["wss://read.example.com"])
        #expect(selection.writes == ["wss://write.example.com"])
    }

    @Test func duplicateEntriesCombineRolesWithoutLosingEitherUse() throws {
        var draft = AccountSetupRelayDraft()
        draft.entries = [
            .init(address: "WSS://RELAY.EXAMPLE.COM", reads: true, writes: false),
            .init(address: "wss://relay.example.com", reads: false, writes: true)
        ]
        let selection = try draft.selection()
        #expect(selection.reads == ["wss://relay.example.com"])
        #expect(selection.writes == ["wss://relay.example.com"])
    }

    @Test func removingTheLastWriteRoleRequiresCorrection() {
        let draft = AccountSetupRelayDraft(proposal: proposal(reads: ["wss://read.example.com"], writes: []))
        #expect(throws: AccountSetupRelayDraft.ValidationError.missingWriteRelay) {
            try draft.selection()
        }
    }

    @Test func addressWithoutASelectedRoleIsNotSilentlyDropped() throws {
        var draft = AccountSetupRelayDraft(proposal: proposal(reads: [], writes: ["wss://write.example.com"]))
        let unused = AccountSetupRelayDraft.Entry(address: "wss://other.example.com", reads: false, writes: false)
        draft.entries.append(unused)
        #expect(throws: AccountSetupRelayDraft.ValidationError.missingRole(unused.id)) {
            try draft.selection()
        }
    }

    @Test func inboxRelaysDoNotRequireOrPublishWriteRoles() throws {
        var draft = AccountSetupRelayDraft()
        draft.entries = [
            .init(address: "WSS://INBOX.EXAMPLE.COM", reads: true, writes: false),
            .init(address: "wss://inbox.example.com", reads: true, writes: false),
            .init(address: "wss://other.example.com", reads: true, writes: false)
        ]
        let selection = try draft.selection(for: .inboxRelays)
        #expect(selection.reads == ["wss://inbox.example.com", "wss://other.example.com"])
        #expect(selection.writes.isEmpty)
    }

    @Test func emptyInboxReplacementCannotBeSubmitted() {
        let draft = AccountSetupRelayDraft()
        #expect(throws: AccountSetupRelayDraft.ValidationError.missingInboxRelay) {
            try draft.selection(for: .inboxRelays)
        }
    }

    @Test(arguments: [
        "wss://one.example.com\nwss://two.example.com",
        "wss://one.example.com/path wss://two.example.com"
    ])
    func oneRelayFieldCannotSilentlyCombineTwoPastedAddresses(_ address: String) {
        var draft = AccountSetupRelayDraft()
        let invalid = AccountSetupRelayDraft.Entry(address: address)
        draft.entries = [.init(address: "wss://valid.example.com"), invalid]
        #expect(throws: AccountSetupRelayDraft.ValidationError.invalidAddress(invalid.id)) {
            try draft.selection(for: .inboxRelays)
        }
    }

    @Test func inboxReplacementKeepsTheExistingSixteenRelayLimit() throws {
        var draft = AccountSetupRelayDraft()
        draft.entries = (1 ... 16).map { .init(address: "wss://relay\($0).example.com", writes: false) }
        #expect(try draft.selection(for: .inboxRelays).reads.count == 16)
        draft.entries.append(.init(address: "wss://extra.example.com", writes: false))
        #expect(throws: AccountSetupRelayDraft.ValidationError.tooManyRelays) {
            try draft.selection(for: .inboxRelays)
        }
    }

    @Test func selectionLimitCountsUniqueAddressesAcrossBothRoles() throws {
        var draft = AccountSetupRelayDraft()
        draft.entries = (0..<16).map { .init(address: "wss://relay\($0).example.com") }
        let accepted = try draft.selection()
        #expect(accepted.reads.count == 16)
        #expect(accepted.writes.count == 16)
        draft.entries.append(.init(address: "wss://relay0.example.com"))
        #expect(try draft.selection() == accepted)
        draft.entries.append(.init(address: "wss://overflow.example.com", reads: true, writes: false))
        #expect(throws: AccountSetupRelayDraft.ValidationError.tooManyRelays) {
            try draft.selection()
        }
    }

    @Test(arguments: ["wss://127.0.0.1", "wss://[::1]", "wss://user:password@relay.example.com",
                      "wss://relay.example.com/\u{202E}path", "wss://" + String(repeating: "a", count: 2048)])
    func unsafeAddressBlocksTheWholeDraft(_ address: String) {
        var draft = AccountSetupRelayDraft()
        let unsafe = AccountSetupRelayDraft.Entry(address: address)
        draft.entries = [.init(address: "wss://valid.example.com"), unsafe]
        #expect(throws: AccountSetupRelayDraft.ValidationError.invalidAddress(unsafe.id)) {
            try draft.selection()
        }
    }

    private func proposal(reads: [String], writes: [String]) -> OnboardingRepairProposalFfi {
        .init(step: .relays, revision: 1, previousEventId: nil,
              readRelays: reads, writeRelays: writes, profile: nil, follows: nil)
    }
}
