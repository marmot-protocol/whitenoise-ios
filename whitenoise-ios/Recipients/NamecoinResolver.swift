import Foundation

/// Namecoin `.bit` NIP-05 resolution. `alice@example.bit`, `example.bit`,
/// `d/example`, `id/alice` -> Nostr pubkey hex (+ optional relay hints).
///
/// Same closed loop the NIP-05 HTTPS verifier serves for DNS names, but over
/// Namecoin's censorship-resistant name index via
/// ElectrumX WSS. Ported from whitenoise-linux `app/namecoin.odin`
/// (79447095f2).
///
/// ── TRUST MODEL ───────────────────────────────────────────────────────
///
/// This resolver TRUSTS the pinned ElectrumX operators it talks to. It asks
/// the server for the latest transaction outputs bound to the name's
/// scripthash and reads the `nostr` field out of the value payload. It does
/// NOT verify:
///
///   * that the returned transaction is included in the best Namecoin chain
///     (no SPV proof, no block-header chain check),
///   * that the returned transaction actually spends into the claimed
///     scripthash on-chain (only that the server labelled it so in the
///     history response),
///   * that any of the servers it talked to agree with each other (there is
///     no cross-server quorum: the first Resolved wins).
///
/// A dishonest, compromised, or MITM'd ElectrumX server can therefore return
/// a fabricated name -> pubkey binding. TLS leaf-pubkey pinning (see
/// ElectrumXTransport) rules out network-path MITM against the pinned
/// servers, but does not rule out the operator themselves lying to us. This
/// matches the linux implementation and the Kotlin / TS parallels today;
/// bundled SPV or a local `namecoind` is the planned follow-up.
///
/// ── ASYNC MODEL ───────────────────────────────────────────────────────
///
/// The linux app runs resolver workers and drains completions at the frame
/// boundary; this port is structured concurrency end-to-end. Resolution runs
/// off the main actor inside `RecipientQueryModel`'s debounced task;
/// cancelling the query (typing on, clearing the field, leaving the screen)
/// cancels the in-flight resolve, which is the idiomatic equivalent of the
/// linux pending-intent snapshot/cancel rules: each screen owns its query
/// model, so a stale resolve cannot land its result on the wrong target.
nonisolated enum NamecoinResolver {
    /// Resolution outcome. Distinguishing not-found from unavailable so the
    /// UI can tell "name doesn't exist" apart from "can't reach ElectrumX".
    enum Resolution: Equatable, Sendable {
        case resolved(Resolved)
        case notFound
        case unavailable
    }

    struct ResolutionOutcome: Equatable, Sendable {
        let resolution: Resolution
        let diagnostic: String?
    }

    struct Resolved: Equatable, Sendable {
        /// 64 lowercase hex.
        let pubkeyHex: String
        let relays: [String]
        let namecoinName: String
        let localPart: String
    }

    /// Structured Namecoin lookup request.
    struct ParsedIdentifier: Equatable, Sendable {
        /// e.g. "d/example".
        let namecoinName: String
        /// "_" for the root.
        let localPart: String
        /// false for `id/` identity names.
        let isDomain: Bool
    }

    // MARK: - identifier gate + parsing

    /// True when `identifier` should be routed to Namecoin resolution rather
    /// than a DNS-based NIP-05 verifier. Cheap enough to gate a hot path.
    static func isBitIdentifier(_ identifier: String) -> Bool {
        parse(identifier) != nil
    }

    /// Parses `raw` into a structured request. Returns nil for non-Namecoin
    /// identifiers. Ported from `nc_parse`.
    static func parse(_ raw: String) -> ParsedIdentifier? {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        // Tolerate a leading NIP-21 `nostr:`.
        if input.count >= 6, input.prefix(6).lowercased() == "nostr:" {
            input = String(input.dropFirst(6))
        }
        let lower = input.lowercased()

        if lower.hasPrefix("d/") {
            guard lower.count > 2 else { return nil }
            return ParsedIdentifier(namecoinName: lower, localPart: "_", isDomain: true)
        }
        if lower.hasPrefix("id/") {
            guard lower.count > 3 else { return nil }
            return ParsedIdentifier(namecoinName: lower, localPart: "_", isDomain: false)
        }

        if input.contains("@"), lower.hasSuffix(".bit") {
            guard let atIndex = input.firstIndex(of: "@") else { return nil }
            let localRaw = input[input.startIndex ..< atIndex]
            let local = localRaw.isEmpty ? "_" : localRaw.lowercased()
            let domainRaw = input[input.index(after: atIndex)...].lowercased()
            guard domainRaw.hasSuffix(".bit") else { return nil }
            let domain = domainRaw.dropLast(4)
            guard !domain.isEmpty else { return nil }
            return ParsedIdentifier(namecoinName: "d/\(domain)", localPart: local, isDomain: true)
        }

        if lower.hasSuffix(".bit") {
            let domain = lower.dropLast(4)
            guard !domain.isEmpty else { return nil }
            return ParsedIdentifier(namecoinName: "d/\(domain)", localPart: "_", isDomain: true)
        }
        return nil
    }

    // MARK: - ElectrumX endpoints

    /// Pins belong to individual operators, never to the transport globally.
    /// The testls.space endpoints use ordinary system CA/hostname validation;
    /// the bitcoins.sk and relay.testls.bit endpoints pin their leaf SPKIs.
    ///
    /// Rotation runbook: when a pinned server rotates its cert, regenerate
    /// the pin with
    ///
    ///     echo | openssl s_client -servername <host> -connect <host>:<port> 2>/dev/null \
    ///       | openssl x509 -pubkey -noout \
    ///       | openssl pkey -pubin -outform der \
    ///       | openssl dgst -sha256 -binary | openssl enc -base64
    ///
    /// and update the entry. Removing a pin without replacing it opens the
    /// server to trivial MITM.
    static let defaultServers: [ElectrumXTransport.Server] = [
        ElectrumXTransport.Server(
            host: "electrumx.testls.space",
            port: 50002,
            pinnedPublicKeySHA256: nil
        ),
        ElectrumXTransport.Server(
            host: "nmc2.bitcoins.sk",
            port: 57002,
            pinnedPublicKeySHA256: "tkCCQ6AZPqU4Te1poKHeS5l/CRWYHz5n7J4LH22/LxQ="
        ),
        ElectrumXTransport.Server(
            host: "46.229.238.187",
            port: 57002,
            pinnedPublicKeySHA256: "tkCCQ6AZPqU4Te1poKHeS5l/CRWYHz5n7J4LH22/LxQ=",
            tlsServerName: "nmc2.bitcoins.sk"
        ),
        ElectrumXTransport.Server(
            host: "relay.testls.bit",
            port: 50012,
            pinnedPublicKeySHA256: "Y9Zu+VV8eoqOBanmpk5QzJtnHwqzxb0ynJGiMRKVJBw="
        ),
        ElectrumXTransport.Server(
            host: "23.158.233.10",
            port: 50012,
            pinnedPublicKeySHA256: "Y9Zu+VV8eoqOBanmpk5QzJtnHwqzxb0ynJGiMRKVJBw=",
            tlsServerName: "relay.testls.bit"
        ),
        ElectrumXTransport.Server(
            host: "electrumx2.testls.space",
            port: 50002,
            pinnedPublicKeySHA256: nil
        ),
    ]

    static let connectTimeoutNanoseconds: UInt64 = 10_000_000_000
    static let readTimeoutNanoseconds: UInt64 = 15_000_000_000
    static let overallLookupTimeoutNanoseconds: UInt64 = 20_000_000_000
    static let hedgeDelayNanoseconds: UInt64 = 1_500_000_000
    static let negativeGraceNanoseconds: UInt64 = 1_500_000_000

    /// Name value older than this many blocks is treated as expired. Matches
    /// NC_NAME_EXPIRE_DEPTH.
    static let nameExpireDepth: Int64 = 36_000

    /// ifa-0001 `import` chains are walked serially with the spec-minimum
    /// depth. Matches NC_IMPORT_MAX_DEPTH.
    static let importMaxDepth = 4

    /// One JSON-RPC round trip to one server: sends `request` (already
    /// carrying `wantId`) and returns the reply body whose top-level id
    /// matches. Injectable for tests.
    typealias RoundTrip = @Sendable (
        _ server: ElectrumXTransport.Server,
        _ request: String,
        _ wantId: Int
    ) async throws -> Data

    static let pinnedRoundTrip: RoundTrip = { server, request, wantId in
        try await ElectrumXTransport.call(
            server: server,
            request: request,
            wantId: wantId,
            connectTimeoutNanoseconds: connectTimeoutNanoseconds,
            readTimeoutNanoseconds: readTimeoutNanoseconds
        )
    }

    // MARK: - public entry point

    /// Resolves a `.bit` / `d/` / `id/` identifier to a nostr pubkey. Session
    /// positive/negative cache short-circuits repeat queries; concurrent
    /// queries for the same identifier share one in-flight lookup.
    static func resolve(
        _ identifier: String,
        servers: [ElectrumXTransport.Server] = defaultServers,
        roundTrip: @escaping RoundTrip = pinnedRoundTrip
    ) async -> Resolution {
        await resolveWithDiagnostics(identifier, servers: servers, roundTrip: roundTrip).resolution
    }

    static func resolveWithDiagnostics(
        _ identifier: String,
        servers: [ElectrumXTransport.Server] = defaultServers,
        roundTrip: @escaping RoundTrip = pinnedRoundTrip
    ) async -> ResolutionOutcome {
        guard let parsed = parse(identifier) else {
            return ResolutionOutcome(resolution: .notFound, diagnostic: nil)
        }
        let key = normalize(identifier)
        if let cached = await SessionCache.shared.lookup(key) {
            return ResolutionOutcome(resolution: cached, diagnostic: nil)
        }
        return await SessionCache.shared.resolveOnceDetailed(key) {
            await lookupDetailed(parsed, servers: servers, roundTrip: roundTrip)
        }
    }

    private static func normalize(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Session positive/negative cache keyed by normalized identifier. Only
    /// definitive outcomes are cached — `.unavailable` is retryable and never
    /// stored. Concurrent resolutions of the same identifier share one task
    /// (the moral equivalent of the linux inflight map).
    actor SessionCache {
        static let shared = SessionCache()

        private var positive: [String: Resolution] = [:]
        private var negative: Set<String> = []
        private var inflight: [String: Task<ResolutionOutcome, Never>] = [:]

        func lookup(_ key: String) -> Resolution? {
            if let hit = positive[key] { return hit }
            if negative.contains(key) { return .notFound }
            return nil
        }

        func resolveOnce(
            _ key: String,
            perform: @escaping @Sendable () async -> Resolution
        ) async -> Resolution {
            await resolveOnceDetailed(key) {
                ResolutionOutcome(resolution: await perform(), diagnostic: nil)
            }.resolution
        }

        func resolveOnceDetailed(
            _ key: String,
            perform: @escaping @Sendable () async -> ResolutionOutcome
        ) async -> ResolutionOutcome {
            if let existing = inflight[key] {
                return await withTaskCancellationHandler {
                    await existing.value
                } onCancel: { existing.cancel() }
            }
            let task = Task { await perform() }
            inflight[key] = task
            let outcome = await withTaskCancellationHandler {
                await task.value
            } onCancel: { task.cancel() }
            inflight[key] = nil
            switch outcome.resolution {
            case .resolved:
                positive[key] = outcome.resolution
                negative.remove(key)
            case .notFound:
                if positive[key] == nil {
                    negative.insert(key)
                }
            case .unavailable:
                break
            }
            return outcome
        }
    }

    // MARK: - lookup pipeline

    private static func lookupDetailed(
        _ parsed: ParsedIdentifier,
        servers: [ElectrumXTransport.Server],
        roundTrip: @escaping RoundTrip
    ) async -> ResolutionOutcome {
        let attempt = await hedgedNameShowDetailed(
            parsed.namecoinName,
            servers: servers,
            roundTrip: roundTrip,
            hedgeDelayNanoseconds: hedgeDelayNanoseconds,
            negativeGraceNanoseconds: negativeGraceNanoseconds,
            overallTimeoutNanoseconds: overallLookupTimeoutNanoseconds
        )
        switch attempt.value {
        case .unavailable:
            return ResolutionOutcome(
                resolution: .unavailable,
                diagnostic: attempt.diagnostics.joined(separator: "\n")
            )
        case .notFound:
            return ResolutionOutcome(resolution: .notFound, diagnostic: nil)
        case .value(let valueJSON):
            guard let merged = await resolveValueWithImports(
                valueJSON,
                maxDepth: importMaxDepth,
                servers: servers,
                roundTrip: roundTrip
            ) else { return ResolutionOutcome(resolution: .notFound, diagnostic: nil) }
            return ResolutionOutcome(resolution: extractNostr(from: merged, parsed: parsed), diagnostic: nil)
        }
    }

    /// Intermediate tri-state for the raw name-value fetch: the value JSON
    /// string, a definitive miss, or a transport-level failure.
    enum NameValue: Equatable, Sendable {
        case value(String)
        case notFound
        case unavailable
    }

    struct NameAttempt: Equatable, Sendable {
        let value: NameValue
        let diagnostics: [String]

        init(_ value: NameValue, diagnostics: [String] = []) {
            self.value = value
            self.diagnostics = diagnostics
        }
    }

    private enum HedgeEvent: Sendable {
        case completed(Int, NameAttempt)
        case launch(Int, Int)
        case negativeGraceExpired
        case overallDeadline
    }

    /// Quartz-style staggered hedging: start the first endpoint immediately,
    /// then one every 1.5 seconds (or immediately after a transport failure).
    /// A positive always wins. A definitive miss stops new launches but leaves
    /// existing attempts a short grace period so a slow positive can beat it.
    static func nameShowWithFallback(
        _ name: String,
        servers: [ElectrumXTransport.Server],
        roundTrip: @escaping RoundTrip
    ) async -> NameValue {
        await hedgedNameShow(
            name,
            servers: servers,
            roundTrip: roundTrip,
            hedgeDelayNanoseconds: hedgeDelayNanoseconds,
            negativeGraceNanoseconds: negativeGraceNanoseconds,
            overallTimeoutNanoseconds: overallLookupTimeoutNanoseconds
        )
    }

    static func hedgedNameShow(
        _ name: String,
        servers: [ElectrumXTransport.Server],
        roundTrip: @escaping RoundTrip,
        hedgeDelayNanoseconds: UInt64,
        negativeGraceNanoseconds: UInt64,
        overallTimeoutNanoseconds: UInt64
    ) async -> NameValue {
        await hedgedNameShowDetailed(
            name,
            servers: servers,
            roundTrip: roundTrip,
            hedgeDelayNanoseconds: hedgeDelayNanoseconds,
            negativeGraceNanoseconds: negativeGraceNanoseconds,
            overallTimeoutNanoseconds: overallTimeoutNanoseconds
        ).value
    }

    static func hedgedNameShowDetailed(
        _ name: String,
        servers: [ElectrumXTransport.Server],
        roundTrip: @escaping RoundTrip,
        hedgeDelayNanoseconds: UInt64,
        negativeGraceNanoseconds: UInt64,
        overallTimeoutNanoseconds: UInt64
    ) async -> NameAttempt {
        guard let first = servers.first else { return NameAttempt(.unavailable) }
        return await withTaskGroup(of: HedgeEvent.self) { group in
            group.addTask {
                .completed(0, await nameShowAttempt(name, server: first, roundTrip: roundTrip))
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: hedgeDelayNanoseconds)
                return .launch(0, 1)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: overallTimeoutNanoseconds)
                return .overallDeadline
            }

            var active: Set<Int> = [0]
            var nextIndex = 1
            var launchGeneration = 0
            var definitiveMiss = false
            var graceScheduled = false
            var diagnostics: [String] = []

            while let event = await group.next() {
                switch event {
                case .completed(let index, let attempt):
                    let outcome = attempt.value
                    if case .value(let value) = outcome {
                        group.cancelAll()
                        return NameAttempt(.value(value), diagnostics: diagnostics)
                    }
                    active.remove(index)
                    diagnostics.append(contentsOf: attempt.diagnostics)
                    if outcome == .notFound { definitiveMiss = true }

                    if definitiveMiss {
                        launchGeneration += 1 // invalidate pending launch timers
                        if !graceScheduled, !active.isEmpty {
                            graceScheduled = true
                            group.addTask {
                                try? await Task.sleep(nanoseconds: negativeGraceNanoseconds)
                                return .negativeGraceExpired
                            }
                        }
                    } else if nextIndex < servers.count {
                        // A failed predecessor launches the next endpoint now.
                        launchGeneration += 1
                        let generation = launchGeneration
                        let launched = nextIndex
                        nextIndex += 1
                        active.insert(launched)
                        let server = servers[launched]
                        group.addTask {
                            .completed(launched, await nameShowAttempt(name, server: server, roundTrip: roundTrip))
                        }
                        if nextIndex < servers.count {
                            let followingIndex = nextIndex
                            group.addTask {
                                try? await Task.sleep(nanoseconds: hedgeDelayNanoseconds)
                                return .launch(generation, followingIndex)
                            }
                        }
                    }

                    if active.isEmpty, definitiveMiss || nextIndex == servers.count {
                        group.cancelAll()
                        return NameAttempt(definitiveMiss ? .notFound : .unavailable, diagnostics: diagnostics)
                    }
                case .launch(let generation, let index):
                    guard generation == launchGeneration, !definitiveMiss,
                          index == nextIndex, index < servers.count
                    else { continue }
                    nextIndex += 1
                    active.insert(index)
                    let server = servers[index]
                    group.addTask {
                        .completed(index, await nameShowAttempt(name, server: server, roundTrip: roundTrip))
                    }
                    if nextIndex < servers.count {
                        let followingIndex = nextIndex
                        group.addTask {
                            try? await Task.sleep(nanoseconds: hedgeDelayNanoseconds)
                            return .launch(generation, followingIndex)
                        }
                    }
                case .negativeGraceExpired:
                    group.cancelAll()
                    return NameAttempt(.notFound, diagnostics: diagnostics)
                case .overallDeadline:
                    group.cancelAll()
                    return NameAttempt(definitiveMiss ? .notFound : .unavailable, diagnostics: diagnostics)
                }
            }
            return NameAttempt(definitiveMiss ? .notFound : .unavailable, diagnostics: diagnostics)
        }
    }

    /// One name -> value lookup against one ElectrumX server. Ported from
    /// `nc_name_show`: server.version handshake, history for the locally
    /// derived scripthash, verbose transaction fetch, best-effort expiry
    /// check, then the name-op vout walk.
    static func nameShow(
        _ name: String,
        server: ElectrumXTransport.Server,
        roundTrip: @escaping RoundTrip
    ) async -> NameValue {
        await nameShowAttempt(name, server: server, roundTrip: roundTrip).value
    }

    static func nameShowAttempt(
        _ name: String,
        server: ElectrumXTransport.Server,
        roundTrip: RoundTrip
    ) async -> NameAttempt {
        func failure(_ stage: String, _ error: Error) -> NameAttempt {
            NameAttempt(.unavailable, diagnostics: [
                "\(server.host):\(server.port) \(stage): \(String(reflecting: error))"
            ])
        }
        // server.version handshake — some ElectrumX operators reject calls
        // before it. A handshake failure marks the whole server unavailable.
        let versionRequest =
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server.version\",\"params\":[\"whitenoise-ios/namecoin\",\"1.4\"]}"
        do {
            _ = try await call(server: server, request: versionRequest, wantId: 1, roundTrip: roundTrip)
        } catch { return failure("server.version", error) }

        // Derive the ElectrumX scripthash key for this name — locally, never
        // by asking the server.
        let script = NamecoinScript.buildNameIndexScript(name: Array(name.utf8))
        let scriptHash = NamecoinScript.electrumScriptHash(script: script)

        let historyRequest =
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"blockchain.scripthash.get_history\",\"params\":[\"\(scriptHash)\"]}"
        let historyBody: Data
        do {
            historyBody = try await call(
                server: server, request: historyRequest, wantId: 2, roundTrip: roundTrip
            )
        } catch { return failure("blockchain.scripthash.get_history", error) }
        guard let (txHash, height) = lastHistoryEntry(in: historyBody) else {
            // Empty history is a definitive Namecoin miss (name has never
            // been registered / has no ops).
            return NameAttempt(.notFound)
        }

        let txRequest =
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"blockchain.transaction.get\",\"params\":[\"\(txHash)\",true]}"
        let txBody: Data
        do {
            txBody = try await call(
                server: server, request: txRequest, wantId: 3, roundTrip: roundTrip
            )
        } catch { return failure("blockchain.transaction.get", error) }

        // Best-effort expiry check via headers.subscribe.
        let headRequest = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"blockchain.headers.subscribe\",\"params\":[]}"
        if let headBody = try? await call(server: server, request: headRequest, wantId: 4, roundTrip: roundTrip) {
            let currentHeight = headerHeight(in: headBody)
            if currentHeight > 0, height > 0, currentHeight - height >= nameExpireDepth {
                return NameAttempt(.notFound)
            }
        }

        guard let value = extractValueFromTx(txBody, name: name) else {
            // The tx we got back does not carry this name's value. Treat as
            // definitive miss — the history entry pointed at something that
            // is not our name payload.
            return NameAttempt(.notFound)
        }
        return NameAttempt(.value(value))
    }

    /// One JSON-RPC round trip; succeeds iff the transport returned a body
    /// carrying the matching id. The transport's id filter is a byte-level
    /// walker; re-parse the envelope with a real JSON parser here so a
    /// hostile/broken server can't sneak a non-object reply or a mismatched
    /// id past the RPC boundary (ported from `nc_call`).
    static func call(
        server: ElectrumXTransport.Server,
        request: String,
        wantId: Int,
        roundTrip: RoundTrip
    ) async throws -> Data {
        let body = try await roundTrip(server, request, wantId)
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let replyId = root["id"] as? NSNumber,
              CFGetTypeID(replyId) != CFBooleanGetTypeID(),
              replyId.doubleValue == Double(wantId)
        else { throw ElectrumXTransport.TransportError.noMatchingReply }
        return body
    }

    // MARK: - JSON extraction helpers

    /// Pulls the last entry of a `blockchain.scripthash.get_history` reply:
    /// array of {tx_hash, height}.
    static func lastHistoryEntry(in body: Data) -> (txHash: String, height: Int64)? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let entries = root["result"] as? [Any],
              let last = entries.last as? [String: Any],
              let txHash = last["tx_hash"] as? String,
              let height = (last["height"] as? NSNumber)?.int64Value
        else { return nil }
        return (txHash, height)
    }

    /// Best-effort current chain height out of a headers.subscribe reply;
    /// 0 when the reply doesn't carry one.
    static func headerHeight(in body: Data) -> Int64 {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let height = (result["height"] as? NSNumber)?.int64Value
        else { return 0 }
        return height
    }

    /// Extracts the raw name value string from a verbose transaction reply by
    /// walking its `vout[]` and matching the OP_NAME_UPDATE / FIRSTUPDATE
    /// vout carrying `name`.
    static func extractValueFromTx(_ body: Data, name: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let tx = root["result"] as? [String: Any],
              let vouts = tx["vout"] as? [Any]
        else { return nil }
        let hexes = vouts.compactMap { entry -> String? in
            guard let object = entry as? [String: Any],
                  let scriptPubKey = object["scriptPubKey"] as? [String: Any]
            else { return nil }
            return scriptPubKey["hex"] as? String
        }
        return NamecoinScript.extractNameValue(vouts: hexes, name: name)
    }

    // MARK: - ifa-0001 import chain

    /// Parses `valueJSON` and, if it declares any `import`, returns a fresh
    /// object with those imports expanded and merged in importer-wins order.
    ///
    /// Swift's value semantics give the clone-and-merge ownership contract of
    /// the linux rewrite for free: the parsed tree is never aliased into the
    /// result, so expansion is non-destructive by construction.
    static func resolveValueWithImports(
        _ valueJSON: String,
        maxDepth: Int,
        servers: [ElectrumXTransport.Server],
        roundTrip: @escaping RoundTrip
    ) async -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(valueJSON.utf8)) as? [String: Any]
        else { return nil }
        var visited: Set<String> = []
        return await expandImports(root, budget: maxDepth, visited: &visited, servers: servers, roundTrip: roundTrip)
    }

    /// Recursive import expansion. `object` is read-only; the result is a
    /// fresh dictionary assembled from the object's non-import entries plus
    /// the merged imported sub-objects.
    static func expandImports(
        _ object: [String: Any],
        budget: Int,
        visited: inout Set<String>,
        servers: [ElectrumXTransport.Server],
        roundTrip: @escaping RoundTrip
    ) async -> [String: Any] {
        // Start with a copy of everything except `import`.
        var base = object
        base.removeValue(forKey: "import")

        guard budget > 0, let importValue = object["import"] else { return base }
        let operations = parseImportItem(importValue)
        guard !operations.isEmpty else { return base }

        var accumulator: [String: Any] = [:]
        for operation in operations {
            let visitKey = "\(operation.name)|\(operation.selector)"
            if visited.contains(visitKey) { continue }
            visited.insert(visitKey)
            defer { visited.remove(visitKey) }

            guard case .value(let raw) = await nameShowWithFallback(
                operation.name,
                servers: servers,
                roundTrip: roundTrip
            ), let importedRoot = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                let selected = applySelector(to: importedRoot, selector: operation.selector)
            else { continue }
            let expanded = await expandImports(
                selected,
                budget: budget - 1,
                visited: &visited,
                servers: servers,
                roundTrip: roundTrip
            )
            mergeImporterWins(importer: &accumulator, imported: expanded)
        }
        mergeImporterWins(importer: &base, imported: accumulator)
        return base
    }

    struct ImportOperation: Equatable {
        let name: String
        let selector: String
    }

    /// Parses an `import` directive: the string shorthand, the canonical
    /// `[[name, sel], ...]` form, and the `[name, sel]` shorthand. Selectors
    /// ending in a dot are rejected.
    static func parseImportItem(_ item: Any) -> [ImportOperation] {
        // Shorthand string form: `"import": "d/foo"`.
        if let name = item as? String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [ImportOperation(name: trimmed, selector: "")]
        }
        guard let array = item as? [Any], !array.isEmpty else { return [] }
        // Distinguish canonical [[name, sel], ...] from shorthand [name, sel].
        if array[0] is [Any] {
            return array.compactMap { entry in
                (entry as? [Any]).flatMap(operation(fromArray:))
            }
        }
        return operation(fromArray: array).map { [$0] } ?? []
    }

    private static func operation(fromArray array: [Any]) -> ImportOperation? {
        guard let rawName = array.first as? String else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var selector = ""
        if array.count >= 2 {
            guard let rawSelector = array[1] as? String else { return nil }
            selector = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if selector.hasSuffix(".") { return nil }
        return ImportOperation(name: name, selector: selector)
    }

    /// Walks a DNS-dotted selector into `root`'s `map` chain, priority
    /// exact -> `*` wildcard -> `""` default. Returns nil for a selector that
    /// walks off the tree.
    static func applySelector(to root: [String: Any], selector: String) -> [String: Any]? {
        let labels = selector.split(separator: ".", omittingEmptySubsequences: true)
        guard !labels.isEmpty else { return root }
        var current = root
        for label in labels.reversed() {
            guard let map = current["map"] as? [String: Any] else { return nil }
            let key = String(label)
            if let exact = map[key] as? [String: Any] {
                current = exact
            } else if let wildcard = map["*"] as? [String: Any] {
                current = wildcard
            } else if let fallback = map[""] as? [String: Any] {
                current = fallback
            } else {
                return nil
            }
        }
        return current
    }

    /// Merges `imported` underneath `importer` with importer-wins semantics:
    /// keys the importer already holds are kept; only new keys move across.
    static func mergeImporterWins(importer: inout [String: Any], imported: [String: Any]) {
        for (key, value) in imported where importer[key] == nil {
            importer[key] = value
        }
    }

    // MARK: - nostr field extraction (fail closed)

    /// Pulls pubkey + relays out of the merged value tree.
    static func extractNostr(from value: [String: Any], parsed: ParsedIdentifier) -> Resolution {
        guard let field = value["nostr"] else { return .notFound }

        // Simple form: "nostr": "hex-pubkey".
        if let pubkey = field as? String {
            guard !parsed.isDomain || parsed.localPart == "_",
                  let normalized = Hex.normalized32Bytes(pubkey)
            else { return .notFound }
            return .resolved(Resolved(
                pubkeyHex: normalized,
                relays: [],
                namecoinName: parsed.namecoinName,
                localPart: "_"
            ))
        }

        guard let nostr = field as? [String: Any] else { return .notFound }
        if parsed.isDomain {
            return extractFromDomain(nostr, parsed: parsed)
        }
        return extractFromIdentity(nostr, parsed: parsed)
    }

    /// Domain-shape extraction. FAIL CLOSED: `alice@example.bit` must resolve
    /// to alice's entry, or to nothing. Never fall back to `_`: that would
    /// silently substitute the domain owner's identity for a user the record
    /// does not name. Never scan for "first valid entry": that would
    /// substitute an arbitrary other user's identity for the root when the
    /// record has no `_`.
    static func extractFromDomain(_ nostr: [String: Any], parsed: ParsedIdentifier) -> Resolution {
        guard let names = nostr["names"] as? [String: Any] else {
            // Some d/ records use the identity-style flat shape (bare
            // `"pubkey":...` at the root of the `nostr` object). Accept it
            // only when the caller asked for the root (`_`) — for any other
            // local part the identity-style shape does not name them.
            guard parsed.localPart == "_" else { return .notFound }
            return extractFromIdentity(nostr, parsed: parsed)
        }

        guard let entry = names[parsed.localPart] as? String,
              let normalized = Hex.normalized32Bytes(entry)
        else { return .notFound }

        return .resolved(Resolved(
            pubkeyHex: normalized,
            relays: extractRelays(from: nostr, pubkeyHex: normalized),
            namecoinName: parsed.namecoinName,
            localPart: parsed.localPart
        ))
    }

    /// Identity-shape extraction: accept the top-level `pubkey` binding only.
    /// Reject any `names` sub-object; those belong to domain (`d/`) records,
    /// and treating them as identity-owner keys silently substitutes somebody
    /// else's identity for the requested name.
    ///
    /// For a `d/` root lookup whose record happens to use the identity shape
    /// (`{"nostr":{"pubkey":...}}`) this is also the route; the caller has
    /// already checked `parsed.localPart == "_"` before routing here, so
    /// accepting the flat `pubkey` is well-defined.
    static func extractFromIdentity(_ nostr: [String: Any], parsed: ParsedIdentifier) -> Resolution {
        guard let pubkey = nostr["pubkey"] as? String,
              let normalized = Hex.normalized32Bytes(pubkey)
        else { return .notFound }
        var relays: [String] = []
        if let array = nostr["relays"] as? [Any] {
            relays = array.compactMap { $0 as? String }
        }
        return .resolved(Resolved(
            pubkeyHex: normalized,
            relays: relays,
            namecoinName: parsed.namecoinName,
            localPart: "_"
        ))
    }

    /// Relay hints: domain shape is a map keyed by pubkey; identity shape is
    /// a flat array.
    static func extractRelays(from nostr: [String: Any], pubkeyHex: String) -> [String] {
        guard let raw = nostr["relays"] else { return [] }
        if let map = raw as? [String: Any] {
            let entries = (map[pubkeyHex.lowercased()] ?? map[pubkeyHex]) as? [Any]
            return entries?.compactMap { $0 as? String } ?? []
        }
        if let array = raw as? [Any] {
            return array.compactMap { $0 as? String }
        }
        return []
    }
}
