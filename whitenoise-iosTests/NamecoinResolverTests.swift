import Foundation
import Testing
@testable import whitenoise_ios

/// Pure-function and stubbed-transport tests for the Namecoin `.bit`
/// resolver, ported from whitenoise-linux `tests/app/namecoin_test.odin`
/// (79447095f2). The linux pending-queue lifecycle tests (dedup,
/// cancel-by-account, cancel-by-group) map onto this platform's
/// RecipientQueryModel task cancellation + generation model and are covered
/// by the query-routing tests instead.
struct NamecoinResolverTests {
    private let server = ElectrumXTransport.Server(
        host: "electrumx.test",
        port: 50004,
        pinnedPublicKeySHA256: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    )

    // MARK: - identifier gate

    @Test func isBitPositives() {
        #expect(NamecoinResolver.isBitIdentifier("alice@example.bit"))
        #expect(NamecoinResolver.isBitIdentifier("Alice@Example.BIT"))
        #expect(NamecoinResolver.isBitIdentifier("example.bit"))
        #expect(NamecoinResolver.isBitIdentifier("nostr:example.bit"))
        #expect(NamecoinResolver.isBitIdentifier("d/example"))
        #expect(NamecoinResolver.isBitIdentifier("id/alice"))
        #expect(NamecoinResolver.isBitIdentifier("  d/example  "))
    }

    @Test func isBitNegatives() {
        #expect(!NamecoinResolver.isBitIdentifier(""))
        #expect(!NamecoinResolver.isBitIdentifier(".bit"))
        #expect(!NamecoinResolver.isBitIdentifier("d/"))
        #expect(!NamecoinResolver.isBitIdentifier("id/"))
        #expect(!NamecoinResolver.isBitIdentifier("example.com"))
        #expect(!NamecoinResolver.isBitIdentifier("alice@example.com"))
        #expect(!NamecoinResolver.isBitIdentifier(
            "npub1w90qcnzy9pxxaanl7zt50pgn8gj9tnpwd3wkfnq8fj0h4pft2eus5at3v3"
        ))
    }

    // MARK: - identifier parsing

    @Test func parseBareDomain() {
        let parsed = NamecoinResolver.parse("Example.BIT")
        #expect(parsed?.namecoinName == "d/example")
        #expect(parsed?.localPart == "_")
        #expect(parsed?.isDomain == true)
    }

    @Test func parseUserAtDomain() {
        let parsed = NamecoinResolver.parse("Alice@Example.bit")
        #expect(parsed?.namecoinName == "d/example")
        #expect(parsed?.localPart == "alice")
        #expect(parsed?.isDomain == true)
    }

    @Test func parseEmptyLocalPartFallsBackToRoot() {
        let parsed = NamecoinResolver.parse("@example.bit")
        #expect(parsed?.localPart == "_")
    }

    @Test func parseDSlash() {
        let parsed = NamecoinResolver.parse("d/Foo")
        #expect(parsed?.namecoinName == "d/foo")
        #expect(parsed?.localPart == "_")
        #expect(parsed?.isDomain == true)
    }

    @Test func parseIdSlash() {
        let parsed = NamecoinResolver.parse("id/Alice")
        #expect(parsed?.namecoinName == "id/alice")
        #expect(parsed?.localPart == "_")
        #expect(parsed?.isDomain == false)
    }

    @Test func parseNostrPrefix() {
        let parsed = NamecoinResolver.parse("nostr:example.bit")
        #expect(parsed?.namecoinName == "d/example")
    }

    @Test func parseRejectsNonBit() {
        #expect(NamecoinResolver.parse("example.com") == nil)
        #expect(NamecoinResolver.parse("d/") == nil)
        #expect(NamecoinResolver.parse("") == nil)
    }

    // MARK: - extractFromDomain: fail closed
    //
    // These tests exercise the security-critical branch that previously
    // silently substituted `_` (root) or "first valid entry" for a missing
    // requested identity. Both fallbacks were removed upstream; a missing
    // entry now resolves to notFound instead of another party's pubkey.

    @Test func domainMissingLocalPartFailsClosed() {
        // Looking up alice@example.bit against a record that only names bob
        // and `_` must return notFound — falling back to `_` (the domain
        // owner) would silently attach the wrong identity to alice's invite.
        let nostr: [String: Any] = ["names": [
            "bob": String(repeating: "a", count: 64),
            "_": String(repeating: "b", count: 64),
        ]]
        let parsed = NamecoinResolver.parse("alice@example.bit")!
        #expect(NamecoinResolver.extractFromDomain(nostr, parsed: parsed) == .notFound)
    }

    @Test func domainRootWithoutUnderscoreFailsClosed() {
        // Looking up the root of a domain whose `names` map has entries but
        // no `_` must return notFound. Picking "the first valid key" would
        // have been an attacker-controlled substitution.
        let nostr: [String: Any] = ["names": [
            "alice": String(repeating: "c", count: 64),
            "bob": String(repeating: "d", count: 64),
        ]]
        let parsed = NamecoinResolver.parse("example.bit")!
        #expect(NamecoinResolver.extractFromDomain(nostr, parsed: parsed) == .notFound)
    }

    @Test func domainExactMatchResolves() {
        let pubkey = String(repeating: "1", count: 64)
        let nostr: [String: Any] = ["names": ["alice": pubkey]]
        let parsed = NamecoinResolver.parse("alice@example.bit")!
        let resolution = NamecoinResolver.extractFromDomain(nostr, parsed: parsed)
        #expect(resolution == .resolved(NamecoinResolver.Resolved(
            pubkeyHex: pubkey,
            relays: [],
            namecoinName: "d/example",
            localPart: "alice"
        )))
    }

    @Test func domainRootWithUnderscoreResolves() {
        let root = String(repeating: "2", count: 64)
        let bob = String(repeating: "3", count: 64)
        let nostr: [String: Any] = ["names": ["_": root, "bob": bob]]
        let parsed = NamecoinResolver.parse("example.bit")!
        let resolution = NamecoinResolver.extractFromDomain(nostr, parsed: parsed)
        #expect(resolution == .resolved(NamecoinResolver.Resolved(
            pubkeyHex: root,
            relays: [],
            namecoinName: "d/example",
            localPart: "_"
        )))
    }

    @Test func domainFlatShapeAcceptedOnlyForRoot() {
        // A d/ record in the identity-style flat shape resolves for the root
        // but must not name any other local part.
        let pubkey = String(repeating: "4", count: 64)
        let nostr: [String: Any] = ["pubkey": pubkey]
        let root = NamecoinResolver.parse("example.bit")!
        let alice = NamecoinResolver.parse("alice@example.bit")!
        #expect(NamecoinResolver.extractFromDomain(nostr, parsed: root) == .resolved(
            NamecoinResolver.Resolved(
                pubkeyHex: pubkey,
                relays: [],
                namecoinName: "d/example",
                localPart: "_"
            )
        ))
        #expect(NamecoinResolver.extractFromDomain(nostr, parsed: alice) == .notFound)
    }

    // MARK: - extractFromIdentity: no cross-shape substitution

    @Test func identityRejectsNamesFallback() {
        // `id/alice` record with only a `names` sub-object (no top-level
        // `pubkey`). Must notFound — accepting `names._` would silently
        // return whatever key that map holds instead of the identity's own.
        let nostr: [String: Any] = ["names": ["_": String(repeating: "e", count: 64)]]
        let parsed = NamecoinResolver.parse("id/alice")!
        #expect(NamecoinResolver.extractFromIdentity(nostr, parsed: parsed) == .notFound)
    }

    @Test func identityAcceptsFlatPubkey() {
        let pubkey = String(repeating: "9", count: 64)
        let nostr: [String: Any] = ["pubkey": pubkey]
        let parsed = NamecoinResolver.parse("id/alice")!
        let resolution = NamecoinResolver.extractFromIdentity(nostr, parsed: parsed)
        #expect(resolution == .resolved(NamecoinResolver.Resolved(
            pubkeyHex: pubkey,
            relays: [],
            namecoinName: "id/alice",
            localPart: "_"
        )))
    }

    @Test func identityRelaysAreFlatArray() {
        let pubkey = String(repeating: "8", count: 64)
        let nostr: [String: Any] = ["pubkey": pubkey, "relays": ["wss://one", "wss://two"]]
        let parsed = NamecoinResolver.parse("id/alice")!
        guard case .resolved(let resolved) = NamecoinResolver.extractFromIdentity(nostr, parsed: parsed) else {
            Issue.record("expected resolved")
            return
        }
        #expect(resolved.relays == ["wss://one", "wss://two"])
    }

    @Test func domainRelaysAreKeyedByPubkey() {
        let pubkey = String(repeating: "7", count: 64)
        let nostr: [String: Any] = [
            "names": ["alice": pubkey],
            "relays": [pubkey: ["wss://relay"]],
        ]
        let parsed = NamecoinResolver.parse("alice@example.bit")!
        guard case .resolved(let resolved) = NamecoinResolver.extractFromDomain(nostr, parsed: parsed) else {
            Issue.record("expected resolved")
            return
        }
        #expect(resolved.relays == ["wss://relay"])
    }

    // MARK: - extractNostr simple form

    @Test func nostrStringFormResolvesOnlyForRootOrIdentity() {
        let pubkey = String(repeating: "5", count: 64)
        let value: [String: Any] = ["nostr": pubkey]
        let root = NamecoinResolver.parse("example.bit")!
        let identity = NamecoinResolver.parse("id/alice")!
        let alice = NamecoinResolver.parse("alice@example.bit")!
        #expect(NamecoinResolver.extractNostr(from: value, parsed: root) != .notFound)
        #expect(NamecoinResolver.extractNostr(from: value, parsed: identity) != .notFound)
        // A bare "nostr": "<pubkey>" does not name alice.
        #expect(NamecoinResolver.extractNostr(from: value, parsed: alice) == .notFound)
    }

    // MARK: - import directive parsing

    @Test func importStringShorthand() {
        #expect(NamecoinResolver.parseImportItem("d/foo") == [
            NamecoinResolver.ImportOperation(name: "d/foo", selector: ""),
        ])
    }

    @Test func importCanonicalAndPairForms() {
        let canonical: [Any] = [["d/foo", "www"], ["d/bar", ""]]
        #expect(NamecoinResolver.parseImportItem(canonical) == [
            NamecoinResolver.ImportOperation(name: "d/foo", selector: "www"),
            NamecoinResolver.ImportOperation(name: "d/bar", selector: ""),
        ])
        let pair: [Any] = ["d/foo", "www"]
        #expect(NamecoinResolver.parseImportItem(pair) == [
            NamecoinResolver.ImportOperation(name: "d/foo", selector: "www"),
        ])
    }

    @Test func importRejectsTrailingDotSelector() {
        let pair: [Any] = ["d/foo", "www."]
        #expect(NamecoinResolver.parseImportItem(pair) == [])
    }

    // MARK: - selector walking

    @Test func selectorPriorityExactWildcardDefault() {
        let record: [String: Any] = ["map": [
            "www": ["ip": "1"],
            "*": ["ip": "2"],
            "": ["ip": "3"],
        ]]
        #expect(NamecoinResolver.applySelector(to: record, selector: "www")?["ip"] as? String == "1")
        #expect(NamecoinResolver.applySelector(to: record, selector: "mail")?["ip"] as? String == "2")
        let noWildcard: [String: Any] = ["map": ["": ["ip": "3"]]]
        #expect(NamecoinResolver.applySelector(to: noWildcard, selector: "mail")?["ip"] as? String == "3")
        // Walking off the tree fails.
        let bare: [String: Any] = ["map": [:]]
        #expect(NamecoinResolver.applySelector(to: bare, selector: "mail") == nil)
        // Multi-label selectors walk reversed (DNS order).
        let nested: [String: Any] = ["map": ["com": ["map": ["example": ["ip": "4"]]]]]
        #expect(NamecoinResolver.applySelector(to: nested, selector: "example.com")?["ip"] as? String == "4")
    }

    // MARK: - resolveValueWithImports
    //
    // The linux tests for this path pinned a double-free the reviewer found;
    // Swift's value semantics make expansion non-destructive by construction,
    // so these tests assert the behavioral contract instead.

    @Test func noImportReturnsTreeUnchanged() async {
        let raw = "{\"nostr\":{\"pubkey\":\"\(String(repeating: "a", count: 64))\"}}"
        let merged = await NamecoinResolver.resolveValueWithImports(
            raw,
            maxDepth: 4,
            servers: [server],
            roundTrip: failingRoundTrip
        )
        #expect(merged?["nostr"] != nil)
    }

    @Test func emptyImportReturnsTreeMinusImportKey() async {
        let raw = "{\"import\":[],\"nostr\":{\"pubkey\":\"\(String(repeating: "b", count: 64))\"}}"
        let merged = await NamecoinResolver.resolveValueWithImports(
            raw,
            maxDepth: 4,
            servers: [server],
            roundTrip: failingRoundTrip
        )
        #expect(merged?["import"] == nil)
        #expect(merged?["nostr"] != nil)
    }

    @Test func nestedMapSurvivesExpansion() async {
        let raw = """
        {"import":[],"nostr":{"names":{"alice":"\(String(repeating: "c", count: 64))"},\
        "relays":{"\(String(repeating: "c", count: 64))":["wss://one","wss://two"]}}}
        """
        let merged = await NamecoinResolver.resolveValueWithImports(
            raw,
            maxDepth: 4,
            servers: [server],
            roundTrip: failingRoundTrip
        )
        #expect(merged?["nostr"] != nil)
    }

    @Test func importChainMergesImporterWins() async {
        // d/base carries the nostr record; d/child imports it but overrides
        // one top-level key. Importer wins on collision.
        let baseValue = "{\"nostr\":{\"pubkey\":\"\(String(repeating: "d", count: 64))\"},\"extra\":\"base\"}"
        let childValue = "{\"import\":\"d/base\",\"extra\":\"child\"}"
        let roundTrip = stubbedNameValues(["d/base": baseValue, "d/child": childValue])

        let merged = await NamecoinResolver.resolveValueWithImports(
            childValue,
            maxDepth: 4,
            servers: [server],
            roundTrip: roundTrip
        )
        #expect(merged?["extra"] as? String == "child")
        #expect((merged?["nostr"] as? [String: Any])?["pubkey"] as? String == String(repeating: "d", count: 64))
    }

    @Test func unavailableImportCollapsesToEmptyObject() async {
        // A sub-import that can't be fetched must not fail the whole record.
        let raw = "{\"import\":\"d/missing\",\"nostr\":{\"pubkey\":\"\(String(repeating: "e", count: 64))\"}}"
        let merged = await NamecoinResolver.resolveValueWithImports(
            raw,
            maxDepth: 4,
            servers: [server],
            roundTrip: stubbedNameValues([:]) // everything not found
        )
        #expect((merged?["nostr"] as? [String: Any])?["pubkey"] as? String == String(repeating: "e", count: 64))
    }

    // MARK: - nameShow pipeline over a stubbed transport

    @Test func currentServersKeepTrustPerEndpoint() {
        let servers = NamecoinResolver.defaultServers
        #expect(servers.map(\.host) == [
            "electrumx.testls.space",
            "nmc2.bitcoins.sk",
            "46.229.238.187",
            "relay.testls.bit",
            "23.158.233.10",
            "electrumx2.testls.space",
        ])
        #expect(servers.map(\.port) == [50002, 57002, 57002, 50012, 50012, 50002])
        #expect(servers[0].pinnedPublicKeySHA256 == nil)
        #expect(servers[5].pinnedPublicKeySHA256 == nil)
        let nmcPin = servers[1].pinnedPublicKeySHA256
        let relayPin = servers[3].pinnedPublicKeySHA256
        #expect(nmcPin == "tkCCQ6AZPqU4Te1poKHeS5l/CRWYHz5n7J4LH22/LxQ=")
        #expect(relayPin == "Y9Zu+VV8eoqOBanmpk5QzJtnHwqzxb0ynJGiMRKVJBw=")
        #expect(servers[2].pinnedPublicKeySHA256 == nmcPin)
        #expect(servers[4].pinnedPublicKeySHA256 == relayPin)
        #expect(nmcPin != relayPin)
        #expect(servers[2].tlsServerName == "nmc2.bitcoins.sk")
        #expect(servers[4].tlsServerName == "relay.testls.bit")
        #expect(!servers.contains { $0.host == "electrum.nmc.ethicnology.com" })
    }

    @Test func nameShowWalksHistoryToValue() async {
        let name = "d/example"
        let valueJSON = "{\"nostr\":{\"pubkey\":\"\(String(repeating: "f", count: 64))\"}}"
        let voutScript = nameVoutScript(name: name, value: valueJSON)
        let roundTrip: NamecoinResolver.RoundTrip = { _, request, wantId in
            switch wantId {
            case 1:
                return Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[\"test\",\"1.4\"]}".utf8)
            case 2:
                return Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[{\"tx_hash\":\"ab\",\"height\":100}]}".utf8)
            case 3:
                return Data("""
                {"jsonrpc":"2.0","id":3,"result":{"vout":[\
                {"scriptPubKey":{"hex":"76a914aabbccddeeff112233445566778899aabbccddee88ac"}},\
                {"scriptPubKey":{"hex":"\(voutScript)"}}]}}
                """.utf8)
            case 4:
                return Data("{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"height\":200}}".utf8)
            default:
                Issue.record("unexpected request id \(wantId): \(request)")
                throw ElectrumXTransport.TransportError.noMatchingReply
            }
        }

        let result = await NamecoinResolver.nameShow(name, server: server, roundTrip: roundTrip)
        #expect(result == .value(valueJSON))
    }

    @Test func emptyHistoryIsDefinitiveMiss() async {
        let roundTrip: NamecoinResolver.RoundTrip = { _, _, wantId in
            switch wantId {
            case 1:
                return Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[\"test\",\"1.4\"]}".utf8)
            case 2:
                return Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[]}".utf8)
            default:
                Issue.record("unexpected request id \(wantId)")
                throw ElectrumXTransport.TransportError.noMatchingReply
            }
        }
        let result = await NamecoinResolver.nameShow("d/ghost", server: server, roundTrip: roundTrip)
        #expect(result == .notFound)
    }

    @Test func expiredNameIsNotFound() async {
        let name = "d/old"
        let valueJSON = "{}"
        let voutScript = nameVoutScript(name: name, value: valueJSON)
        let roundTrip: NamecoinResolver.RoundTrip = { _, _, wantId in
            switch wantId {
            case 1:
                return Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[\"test\",\"1.4\"]}".utf8)
            case 2:
                // Height 100; chain is at 100 + 36000 -> expired.
                return Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[{\"tx_hash\":\"ab\",\"height\":100}]}".utf8)
            case 3:
                return Data("""
                {"jsonrpc":"2.0","id":3,"result":{"vout":[\
                {"scriptPubKey":{"hex":"\(voutScript)"}}]}}
                """.utf8)
            case 4:
                return Data("{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"height\":\(100 + NamecoinResolver.nameExpireDepth)}}".utf8)
            default:
                throw ElectrumXTransport.TransportError.noMatchingReply
            }
        }
        let result = await NamecoinResolver.nameShow(name, server: server, roundTrip: roundTrip)
        #expect(result == .notFound)
    }

    @Test func failureLaunchesNextServerAndPositiveWins() async {
        let name = "d/example"
        let valueJSON = "{\"nostr\":\"\(String(repeating: "1", count: 64))\"}"
        let voutScript = nameVoutScript(name: name, value: valueJSON)
        let servers = [
            ElectrumXTransport.Server(host: "fail.test", port: 1, pinnedPublicKeySHA256: ""),
            ElectrumXTransport.Server(host: "hit.test", port: 1, pinnedPublicKeySHA256: ""),
            ElectrumXTransport.Server(host: "miss.test", port: 1, pinnedPublicKeySHA256: ""),
        ]
        let roundTrip: NamecoinResolver.RoundTrip = { server, _, wantId in
            switch server.host {
            case "fail.test":
                throw ElectrumXTransport.TransportError.timeout
            default: // miss.test is not launched after the fast positive.
                switch wantId {
                case 1: return Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[\"t\",\"1.4\"]}".utf8)
                case 2: return Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[{\"tx_hash\":\"ab\",\"height\":1}]}".utf8)
                case 3: return Data("""
                    {"jsonrpc":"2.0","id":3,"result":{"vout":[\
                    {"scriptPubKey":{"hex":"\(voutScript)"}}]}}
                    """.utf8)
                case 4: return Data("{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"height\":2}}".utf8)
                default: throw ElectrumXTransport.TransportError.noMatchingReply
                }
            }
        }
        let result = await NamecoinResolver.nameShowWithFallback(name, servers: servers, roundTrip: roundTrip)
        #expect(result == .value(valueJSON))

    }

    @Test func slowPositiveBeatsFastNegativeDuringGrace() async {
        let name = "d/example"
        let value = "{\"nostr\":\"\(String(repeating: "1", count: 64))\"}"
        let recorder = NamecoinAttemptRecorder()
        let positive = stubbedNameValues([name: value])
        let negative = stubbedNameValues([:])
        let roundTrip: NamecoinResolver.RoundTrip = { server, request, id in
            await recorder.start(server.host)
            if server.host == "slow-positive.test" {
                // Deliberate socket-latency model, not a condition wait.
                if id == 1 {
                    // swiftlint:disable:next no_test_sleep
                    try await Task.sleep(nanoseconds: 60_000_000)
                }
                return try await positive(server, request, id)
            }
            return try await negative(server, request, id)
        }
        let result = await NamecoinResolver.hedgedNameShow(
            name,
            servers: [
                .init(host: "slow-positive.test", port: 1, pinnedPublicKeySHA256: ""),
                .init(host: "fast-negative.test", port: 1, pinnedPublicKeySHA256: ""),
                .init(host: "must-not-start.test", port: 1, pinnedPublicKeySHA256: ""),
            ],
            roundTrip: roundTrip,
            hedgeDelayNanoseconds: 10_000_000,
            negativeGraceNanoseconds: 150_000_000,
            overallTimeoutNanoseconds: 1_000_000_000
        )
        #expect(result == .value(value))
        #expect(await recorder.hosts == ["slow-positive.test", "fast-negative.test"])
    }

    @Test func negativeStopsLaunchesAndExpiresGrace() async {
        let recorder = NamecoinAttemptRecorder()
        let negative = stubbedNameValues([:])
        let roundTrip: NamecoinResolver.RoundTrip = { server, request, id in
            await recorder.start(server.host)
            if server.host == "slow.test", id == 1 {
                // Deliberate stalled-attempt model, cancelled by the grace deadline.
                // swiftlint:disable:next no_test_sleep
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            return try await negative(server, request, id)
        }
        let result = await NamecoinResolver.hedgedNameShow(
            "d/example",
            servers: [
                .init(host: "slow.test", port: 1, pinnedPublicKeySHA256: ""),
                .init(host: "negative.test", port: 1, pinnedPublicKeySHA256: ""),
                .init(host: "must-not-start.test", port: 1, pinnedPublicKeySHA256: ""),
            ],
            roundTrip: roundTrip,
            hedgeDelayNanoseconds: 10_000_000,
            negativeGraceNanoseconds: 30_000_000,
            overallTimeoutNanoseconds: 1_000_000_000
        )
        #expect(result == .notFound)
        #expect(await recorder.hosts == ["slow.test", "negative.test"])
    }

    @Test func emptyServerListIsUnavailable() async {
        let result = await NamecoinResolver.nameShowWithFallback(
            "d/example", servers: [], roundTrip: failingRoundTrip
        )
        #expect(result == .unavailable)
    }

    @Test func overallDeadlineCancelsStalledAttempts() async {
        let stalled: NamecoinResolver.RoundTrip = { _, _, _ in
            // Deliberate non-answering server, cancelled by the overall budget.
            // swiftlint:disable:next no_test_sleep
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw ElectrumXTransport.TransportError.timeout
        }
        let result = await NamecoinResolver.hedgedNameShow(
            "d/example",
            servers: [server],
            roundTrip: stalled,
            hedgeDelayNanoseconds: 1_500_000_000,
            negativeGraceNanoseconds: 1_500_000_000,
            overallTimeoutNanoseconds: 30_000_000
        )
        #expect(result == .unavailable)
    }

    @Test func transportFailureDiagnosticNamesEndpointAndRPCStage() async {
        let attempt = await NamecoinResolver.nameShowAttempt(
            "d/example", server: server, roundTrip: failingRoundTrip
        )
        #expect(attempt.value == .unavailable)
        #expect(attempt.diagnostics.count == 1)
        #expect(attempt.diagnostics[0].contains("electrumx.test:50004 server.version"))
        #expect(attempt.diagnostics[0].contains("timeout"))
    }

    @Test func unavailableOnlyWhenEveryServerFailsTransport() async {
        let fail: NamecoinResolver.RoundTrip = { _, _, _ in
            throw ElectrumXTransport.TransportError.timeout
        }
        let result = await NamecoinResolver.nameShowWithFallback(
            "d/example",
            servers: [server, server],
            roundTrip: fail
        )
        #expect(result == .unavailable)
    }

    // MARK: - envelope re-validation at the RPC boundary

    @Test func callRejectsMismatchedIdAndNonObjectReplies() async {
        let mismatched: NamecoinResolver.RoundTrip = { _, _, _ in
            Data("{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":[]}".utf8)
        }
        await #expect(throws: ElectrumXTransport.TransportError.self) {
            _ = try await NamecoinResolver.call(server: server, request: "{}", wantId: 2, roundTrip: mismatched)
        }
        let arrayReply: NamecoinResolver.RoundTrip = { _, _, _ in Data("[1,2,3]".utf8) }
        await #expect(throws: ElectrumXTransport.TransportError.self) {
            _ = try await NamecoinResolver.call(server: server, request: "{}", wantId: 2, roundTrip: arrayReply)
        }
        let booleanId: NamecoinResolver.RoundTrip = { _, _, _ in
            Data("{\"jsonrpc\":\"2.0\",\"id\":true,\"result\":[]}".utf8)
        }
        await #expect(throws: ElectrumXTransport.TransportError.self) {
            _ = try await NamecoinResolver.call(server: server, request: "{}", wantId: 1, roundTrip: booleanId)
        }
    }

    // MARK: - session cache

    @Test func sessionCacheStoresOnlyDefinitiveOutcomes() async {
        let cache = NamecoinResolver.SessionCache()
        #expect(await cache.lookup("k") == nil)

        let unavailable = await cache.resolveOnce("k") { .unavailable }
        #expect(unavailable == .unavailable)
        #expect(await cache.lookup("k") == nil) // retryable outcomes are not cached

        let miss = await cache.resolveOnce("k") { .notFound }
        #expect(miss == .notFound)
        #expect(await cache.lookup("k") == .notFound)

        let resolved = NamecoinResolver.Resolution.resolved(NamecoinResolver.Resolved(
            pubkeyHex: String(repeating: "6", count: 64),
            relays: [],
            namecoinName: "d/example",
            localPart: "_"
        ))
        _ = await cache.resolveOnce("k2") { resolved }
        #expect(await cache.lookup("k2") == resolved)
    }

    // MARK: - helpers

    /// Builds the hex of an OP_NAME_UPDATE vout carrying `name` / `value`.
    private func nameVoutScript(name: String, value: String) -> String {
        var script: [UInt8] = [NamecoinScript.opNameUpdate]
        NamecoinScript.pushData(&script, Array(name.utf8))
        NamecoinScript.pushData(&script, Array(value.utf8))
        script.append(contentsOf: [
            NamecoinScript.op2Drop,
            NamecoinScript.opDrop,
            NamecoinScript.opReturn,
        ])
        return script.map { String(format: "%02x", $0) }.joined()
    }

    /// A round trip that answers the nameShow pipeline for a fixed name ->
    /// value map; every other name is a definitive miss. The history reply
    /// tags each name with a deterministic per-name tx_hash marker so the
    /// verbose-tx reply can serve the same name's vout without mutable
    /// state.
    private func stubbedNameValues(_ values: [String: String]) -> NamecoinResolver.RoundTrip {
        func txMarker(for name: String) -> String {
            let script = NamecoinScript.buildNameIndexScript(name: Array(name.utf8))
            return String(NamecoinScript.electrumScriptHash(script: script).prefix(16))
        }
        return { _, request, wantId in
            switch wantId {
            case 1:
                return Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[\"t\",\"1.4\"]}".utf8)
            case 2:
                // Recover the queried name from the request's scripthash by
                // matching against the values map (test names are known).
                for name in values.keys {
                    let script = NamecoinScript.buildNameIndexScript(name: Array(name.utf8))
                    let hash = NamecoinScript.electrumScriptHash(script: script)
                    if request.contains(hash) {
                        let marker = txMarker(for: name)
                        return Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[{\"tx_hash\":\"\(marker)\",\"height\":1}]}".utf8)
                    }
                }
                return Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[]}".utf8)
            case 3:
                // Serve the vout of whichever name this tx marker belongs to.
                for (name, value) in values where request.contains(txMarker(for: name)) {
                    let vout = nameVoutScript(name: name, value: value)
                    return Data("""
                    {"jsonrpc":"2.0","id":3,"result":{"vout":[\
                    {"scriptPubKey":{"hex":"\(vout)"}}]}}
                    """.utf8)
                }
                throw ElectrumXTransport.TransportError.noMatchingReply
            case 4:
                return Data("{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"height\":2}}".utf8)
            default:
                throw ElectrumXTransport.TransportError.noMatchingReply
            }
        }
    }

    private var failingRoundTrip: NamecoinResolver.RoundTrip {
        { _, _, _ in throw ElectrumXTransport.TransportError.timeout }
    }
}

private actor NamecoinAttemptRecorder {
    private(set) var hosts: [String] = []
    func start(_ host: String) {
        if !hosts.contains(host) { hosts.append(host) }
    }
}
