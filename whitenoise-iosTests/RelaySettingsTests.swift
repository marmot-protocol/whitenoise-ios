import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct RelaySettingsTests {

    @Test func editableRelayListComesFromMarmotAccountRelayLists() {
        let lists = AccountRelayListsFfi(
            complete: true,
            missing: [],
            defaultRelays: ["wss://nip65.example"],
            bootstrapRelays: ["wss://source.example"],
            nip65: RelayListFfi(kind: 10002, relays: ["wss://nip65.example"]),
            inbox: RelayListFfi(kind: 39000, relays: ["wss://inbox.example"])
        )

        #expect(RelaySettings.editableRelays(from: lists) == ["wss://nip65.example"])
        #expect(RelaySettings.bootstrapRelays(from: lists) == ["wss://source.example"])
    }

    @Test func relayInputRequiresPublicSecureWebsocketDestinations() {
        #expect(RelaySettings.normalizedRelayURL("  ws://relay.example  ") == nil)
        #expect(RelaySettings.normalizedRelayURL("wss://relay.example") == "wss://relay.example")
        #expect(RelaySettings.normalizedRelayURL("wss://localhost") == nil)
        #expect(RelaySettings.normalizedRelayURL("wss://127.0.0.1") == nil)
        #expect(RelaySettings.normalizedRelayURL("wss://10.0.0.1") == nil)
        #expect(RelaySettings.normalizedRelayURL("wss://[::1]") == nil)
        #expect(RelaySettings.normalizedRelayURL("https://relay.example") == nil)
        #expect(RelaySettings.normalizedRelayURL("relay.example") == nil)
        #expect(RelaySettings.normalizedRelayURL("wss://") == nil)
        #expect(RelaySettings.normalizedRelayURL("wss:// ") == nil)
        #expect(RelaySettings.normalizedRelayURL("ws://\n") == nil)
    }

    @Test func relayNormalizationDeduplicatesSchemeAndHostCase() {
        #expect(
            RelaySettings.normalizedRelayURL("WSS://Relay.DAMUS.IO/Nostr?Token=ABC")
                == "wss://relay.damus.io/Nostr?Token=ABC"
        )
        #expect(RelaySettings.normalizedRelayURLs([
            "WSS://Relay.DAMUS.IO",
            "wss://relay.damus.io"
        ]) == ["wss://relay.damus.io"])
    }

    @Test func relayNormalizationRejectsUserinfoAndBoundsInput() {
        #expect(RelaySettings.normalizedRelayURL("wss://user:pass@relay.example") == nil)
        #expect(RelaySettings.normalizedRelayURL("wss://relay.example/path?q=token#frag") == "wss://relay.example/path?q=token")
        #expect(RelaySettings.normalizedRelayURL("wss://relay.example:443/path") == "wss://relay.example:443/path")
        #expect(RelaySettings.normalizedRelayURL("wss://relay.example/" + String(repeating: "a", count: 4096)) == nil)
    }

    @Test func savingRelaysPublishesOnlyTheEditedList() async throws {
        let lists = relayLists(
            bootstrapRelays: ["wss://source.example"],
            nip65: ["wss://wn.example", "wss://general.example"],
            inbox: ["wss://wn.example"]
        )
        let manager = FakeAccountRelayListManager(lists: lists, failNip65: false)
        _ = try await RelaySettings.saveAccountRelays(
            accountRef: "account-a",
            relays: ["wss://wn.example", "wss://general.example", "wss://added.example"],
            target: .nip65,
            currentLists: lists,
            manager: manager
        )
        _ = try await RelaySettings.saveAccountRelays(
            accountRef: "account-a",
            relays: ["wss://wn.example", "wss://inbox.example"],
            target: .inbox,
            currentLists: lists,
            manager: manager
        )
        #expect(manager.calls == [
            .nip65(
                relays: ["wss://wn.example", "wss://general.example", "wss://added.example"],
                bootstrapRelays: ["wss://source.example"]
            ),
            .inbox(
                relays: ["wss://wn.example", "wss://inbox.example"],
                bootstrapRelays: ["wss://source.example"]
            )
        ])
    }

    @Test func savingRelaysReloadsAuthoritativeListsWhenFinalPublishFails() async throws {
        let oldLists = relayLists(
            bootstrapRelays: ["wss://source.example"],
            nip65: ["wss://old.example"],
            inbox: ["wss://old.example"]
        )
        let manager = FakeAccountRelayListManager(lists: oldLists, failNip65: true)

        do {
            _ = try await RelaySettings.saveAccountRelays(
                accountRef: "account-a",
                relays: ["  wss://new.example  "],
                target: .nip65,
                currentLists: oldLists,
                manager: manager
            )
            Issue.record("Expected relay save to fail")
        } catch let failure as RelaySettingsSaveFailure {
            #expect(failure.reloadedLists == oldLists)
            #expect(manager.calls == [
                .nip65(relays: ["wss://new.example"], bootstrapRelays: ["wss://source.example"]),
                .reload(accountRef: "account-a")
            ])
        } catch {
            Issue.record("Expected RelaySettingsSaveFailure, got \(error)")
        }
    }
}

private enum RelayManagerCall: Equatable {
    case reload(accountRef: String)
    case inbox(relays: [String], bootstrapRelays: [String])
    case nip65(relays: [String], bootstrapRelays: [String])
}

private enum RelayManagerError: LocalizedError {
    case nip65Rejected

    var errorDescription: String? {
        "NIP-65 relay update rejected"
    }
}

private final class FakeAccountRelayListManager: AccountRelayListManaging {
    var calls: [RelayManagerCall] = []

    private var lists: AccountRelayListsFfi
    private let failNip65: Bool

    init(lists: AccountRelayListsFfi, failNip65: Bool) {
        self.lists = lists
        self.failNip65 = failNip65
    }

    func accountRelayLists(accountRef: String) throws -> AccountRelayListsFfi {
        calls.append(.reload(accountRef: accountRef))
        return lists
    }

    func setAccountInboxRelays(
        accountRef: String,
        relays: [String],
        bootstrapRelays: [String]
    ) async throws -> AccountRelayListsFfi {
        calls.append(.inbox(relays: relays, bootstrapRelays: bootstrapRelays))
        lists.inbox = RelayListFfi(kind: 39000, relays: relays)
        return lists
    }

    func setAccountNip65Relays(
        accountRef: String,
        relays: [String],
        bootstrapRelays: [String]
    ) async throws -> AccountRelayListsFfi {
        calls.append(.nip65(relays: relays, bootstrapRelays: bootstrapRelays))
        if failNip65 {
            throw RelayManagerError.nip65Rejected
        }
        lists.nip65 = RelayListFfi(kind: 10002, relays: relays)
        return lists
    }
}
