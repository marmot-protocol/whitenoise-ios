import MarmotKit
import Testing
@testable import whitenoise_ios

struct GroupCommitRefusalPresentationTests {
    private func refusal(_ url: String, _ cause: GroupCommitRefusalCauseFfi) -> GroupCommitRefusedRelayFfi {
        GroupCommitRefusedRelayFfi(relayUrl: url, cause: cause, sizeClass: nil)
    }

    @Test func oneRelayIsNamedByHostAndSaysWhenTheChangeWasTooLarge() {
        let tooLarge = GroupCommitRefusalPresentation.message(for: [refusal("wss://Relay.Example/path", .tooLarge)])
        #expect(tooLarge.hasPrefix("relay.example refused"))
        #expect(tooLarge.contains("too large"))
        let rejected = GroupCommitRefusalPresentation.message(for: [refusal("wss://relay.example", .rejected)])
        #expect(rejected.hasPrefix("relay.example refused"))
        #expect(!rejected.contains("too large"))
    }

    @Test func severalRelaysAreCountedAndOnlyBlameSizeWhenEveryOneDid() {
        let mixed = GroupCommitRefusalPresentation.message(for: [
            refusal("wss://a.example", .tooLarge), refusal("wss://b.example", .rejected),
        ])
        #expect(mixed.hasPrefix("2 relays refused"))
        #expect(!mixed.contains("too large"))
        let allLarge = GroupCommitRefusalPresentation.message(for: [
            refusal("wss://a.example", .tooLarge), refusal("wss://b.example", .tooLarge),
        ])
        #expect(allLarge.contains("too large"))
    }
}
