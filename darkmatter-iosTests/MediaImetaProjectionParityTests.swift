import Foundation
import Testing
@testable import darkmatter_ios
@testable import MarmotKit

/// Phase 0 parity oracle for the thin-shell refactor (see
/// `docs/thin-shell-refactor.md`, Phase 3).
///
/// The one binding change the refactor needs is a resolved
/// `media: [MediaAttachmentReferenceFfi]` projected onto each timeline row by
/// the Rust runtime, replacing the iOS-side `imeta`-tag parsing that
/// `MessageSemantics.mediaAttachments(from:sourceEpoch:)` does today. Before we
/// delete that Swift path we must be able to prove the Rust projection produces
/// *byte-identical* references for the same input.
///
/// These tests pin the current Swift behavior exactly, so the future parity
/// assertion (see PARITY HOOK at the bottom) is a one-line addition once the
/// `media` field exists on `TimelineMessageRecordFfi`.
///
/// Two behaviors here are easy to get wrong on the Rust side and are pinned
/// deliberately:
///   1. `sourceEpoch` is NOT an `imeta` field — it is the message's own record
///      epoch, threaded into every reference. The projection must carry it.
///   2. The current Swift parser is **all-or-nothing per message**: if any
///      `imeta` tag fails validation, the whole list degrades to `nil` (message
///      renders as chat text, no media). A message with one good + one bad
///      `imeta` shows *neither* attachment today.
///
/// DECISION (2026-06-22): the Rust `media` projection will instead **drop only
/// the malformed attachment and keep the valid ones**. This is the single
/// intentional behavior change in the swap (see `oneMalformedImetaDropsAllAttachments`
/// and the PARITY HOOK). The corpus below pins *today's* Swift behavior so this
/// file stays a truthful snapshot; the parity hook flips that one case to the
/// drop-bad target when the binding lands.
struct MediaImetaProjectionParityTests {

    // MARK: - Canonical corpus (input imeta -> reference the projection must emit)

    /// One projection case: raw `imeta` tag value arrays + the record's source
    /// epoch, and the references `mediaAttachments` currently returns (`nil`
    /// means the message degrades to chat text).
    fileprivate struct Case {
        let name: String
        let imeta: [[String]]
        let sourceEpoch: UInt64
        let expected: [MediaAttachmentReferenceFfi]?
    }

    fileprivate static let corpus: [Case] = [
        Case(
            name: "single image, all fields, epoch 42",
            imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: "640x480")],
            sourceEpoch: 42,
            expected: [ref(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", sourceEpoch: 42, dim: "640x480")]
        ),
        Case(
            name: "two attachments preserve order, share epoch 7",
            imeta: [
                imetaValues(file: "first.jpg", ciphertext: hex32("41"), plaintext: hex32("31"), nonce: n, mediaType: "image/jpeg", dim: nil),
                imetaValues(file: "second.jpg", ciphertext: hex32("42"), plaintext: hex32("32"), nonce: n, mediaType: "image/jpeg", dim: nil),
            ],
            sourceEpoch: 7,
            expected: [
                ref(file: "first.jpg", ciphertext: hex32("41"), plaintext: hex32("31"), nonce: n, mediaType: "image/jpeg", sourceEpoch: 7, dim: nil),
                ref(file: "second.jpg", ciphertext: hex32("42"), plaintext: hex32("32"), nonce: n, mediaType: "image/jpeg", sourceEpoch: 7, dim: nil),
            ]
        ),
        Case(
            name: "epoch 0 propagates as 0",
            imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil)],
            sourceEpoch: 0,
            expected: [ref(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", sourceEpoch: 0, dim: nil)]
        ),
        Case(
            name: "media type image/jpg canonicalizes to image/jpeg",
            imeta: [imetaValues(file: "a.jpg", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/jpg", dim: nil)],
            sourceEpoch: 1,
            expected: [ref(file: "a.jpg", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/jpeg", sourceEpoch: 1, dim: nil)]
        ),
        Case(
            name: "uppercase hashes/nonce are lowercased in output",
            imeta: [imetaValues(file: "a.png", ciphertext: c.uppercased(), plaintext: p.uppercased(), nonce: n.uppercased(), mediaType: "image/png", dim: nil)],
            sourceEpoch: 5,
            expected: [ref(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", sourceEpoch: 5, dim: nil)]
        ),
        Case(
            name: "valid thumbhash preserved",
            imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil, extra: ["thumbhash Abc123+/=_-"])],
            sourceEpoch: 9,
            expected: [ref(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", sourceEpoch: 9, dim: nil, thumbhash: "Abc123+/=_-")]
        ),
        Case(
            name: "unknown blurhash field is ignored, not rejected",
            imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil, extra: ["blurhash LEHV6nWB2yk8pyo0adR*"])],
            sourceEpoch: 3,
            expected: [ref(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", sourceEpoch: 3, dim: nil)]
        ),

        // --- Malformed: every branch degrades the whole message to nil ---
        Case(name: "missing locator -> nil",
             imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil, omitLocator: true)],
             sourceEpoch: 1, expected: nil),
        Case(name: "ciphertext hash wrong length -> nil",
             imeta: [imetaValues(file: "a.png", ciphertext: String(c.dropLast(2)), plaintext: p, nonce: n, mediaType: "image/png", dim: nil)],
             sourceEpoch: 1, expected: nil),
        Case(name: "plaintext hash wrong length -> nil",
             imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: String(p.dropLast(2)), nonce: n, mediaType: "image/png", dim: nil)],
             sourceEpoch: 1, expected: nil),
        Case(name: "nonce wrong length -> nil",
             imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: p, nonce: String(repeating: "22", count: 11), mediaType: "image/png", dim: nil)],
             sourceEpoch: 1, expected: nil),
        Case(name: "missing filename -> nil",
             imeta: [imetaValues(file: "", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil)],
             sourceEpoch: 1, expected: nil),
        Case(name: "wrong version -> nil",
             imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil, version: "mip04-v2")],
             sourceEpoch: 1, expected: nil),
        Case(name: "invalid media type -> nil",
             imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/", dim: nil)],
             sourceEpoch: 1, expected: nil),
        Case(name: "invalid dim -> nil",
             imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: "640")],
             sourceEpoch: 1, expected: nil),
        Case(name: "overlong thumbhash -> nil",
             imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil, extra: ["thumbhash \(String(repeating: "x", count: 129))"])],
             sourceEpoch: 1, expected: nil),

        // --- The all-or-nothing rule across multiple attachments ---
        // INTENTIONAL DIVERGENCE: today's Swift parser returns nil here; the
        // agreed Rust target keeps the valid attachment (drop-bad). Pinned to
        // today's value so this snapshot stays green; flipped in the parity hook.
        Case(
            name: "one valid + one malformed -> nil today (target: drop-bad)",
            imeta: [
                imetaValues(file: "good.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil),
                imetaValues(file: "bad.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil, omitLocator: true),
            ],
            sourceEpoch: 1,
            expected: nil
        ),

        Case(name: "no imeta tags -> nil (not a media message)",
             imeta: [],
             sourceEpoch: 1, expected: nil),
    ]

    // MARK: - The pin

    @Test func mediaAttachmentsMatchesPinnedProjection() {
        for testCase in Self.corpus {
            let tags = testCase.imeta.map { MessageTagFfi(values: $0) }
            let got = MessageSemantics.mediaAttachments(from: tags, sourceEpoch: testCase.sourceEpoch)
            #expect(got == testCase.expected, "\(testCase.name)")
        }
    }

    // MARK: - Headline Phase-3 invariants (crisp failures, not buried in the loop)

    /// The single most important behavior the Rust `media` projection must
    /// reproduce: the message's record epoch lands on every reference. The
    /// `imeta` bytes are identical across epochs; only `sourceEpoch` differs.
    @Test func sourceEpochThreadsIntoEveryReference() {
        let tags = [MessageTagFfi(values: imetaValues(
            file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil))]

        #expect(MessageSemantics.mediaAttachments(from: tags, sourceEpoch: 0)?.first?.sourceEpoch == 0)
        #expect(MessageSemantics.mediaAttachments(from: tags, sourceEpoch: 42)?.first?.sourceEpoch == 42)

        // Everything except sourceEpoch must be invariant to the epoch.
        let lo = MessageSemantics.mediaAttachments(from: tags, sourceEpoch: 1)?.first
        let hi = MessageSemantics.mediaAttachments(from: tags, sourceEpoch: 999)?.first
        #expect(lo?.plaintextSha256 == hi?.plaintextSha256)
        #expect(lo?.ciphertextSha256 == hi?.ciphertextSha256)
        #expect(lo?.locators == hi?.locators)
    }

    /// Pins TODAY's all-or-nothing Swift behavior: a single bad `imeta` among
    /// valid ones drops the *whole* message's media. The agreed target (drop-bad)
    /// changes this; when the binding lands, the Rust field returns the valid
    /// attachment here and this assertion moves to the parity hook. Keeping it
    /// green now documents exactly what behavior we are consciously changing.
    @Test func oneMalformedImetaDropsAllAttachments() {
        let good = imetaValues(file: "good.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil)
        let bad = imetaValues(file: "bad.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil, omitLocator: true)

        let bothValid = MessageSemantics.mediaAttachments(
            from: [good, good].map { MessageTagFfi(values: $0) }, sourceEpoch: 1)
        #expect(bothValid?.count == 2)

        let oneBad = MessageSemantics.mediaAttachments(
            from: [good, bad].map { MessageTagFfi(values: $0) }, sourceEpoch: 1)
        #expect(oneBad == nil)
    }

    // MARK: - Bindings landed (darkmatter 127fe17): how parity is enforced now
    //
    // PR darkmatter#570 resolves `media: [MediaAttachmentReferenceFfi]` on
    // `TimelineMessageRecordFfi` / `TimelineReplyPreviewFfi` in Rust, from each
    // message's `imeta` + its own `source_epoch`. Note the row does NOT expose a
    // row-level source epoch — each resolved reference carries its own
    // `sourceEpoch`. So a Swift-constructed `TimelineMessageRecordFfi` fixture
    // cannot exercise the Rust resolution (its `media` is just whatever the test
    // sets), which is why there is no pure-unit parity test here.
    //
    // Cross-language parity is instead enforced by:
    //   1. Rust — `timeline_media_references_match_list_media_for_same_message`
    //      (PR #570): the row resolver == `list_media`'s resolver.
    //   2. This oracle — the `corpus` expectations ARE what Rust must produce for
    //      a given `imeta` + epoch, doubling as a hand-checkable golden set
    //      against the Rust conversion tests in `conversions/media.rs`.
    //
    // When iOS adopts `record.media` (Phase 5 — delete `MessageSemantics`
    // `mediaAttachments`, `mediaRecordsByMessageId`, `mediaRecordReferencesByKey`,
    // and the timeline `listMedia` path), validate consumption with an
    // integration test over a real runtime timeline (real rows carry resolved
    // `media`), not a hand-built fixture. That swap is also where the DECIDED
    // drop-bad behavior takes effect: a message with one valid + one malformed
    // `imeta` will then surface the valid attachment, where today's Swift parser
    // surfaces none — flip the corpus "drop-bad" case from `nil` to `[valid]`
    // at that point.
}

// MARK: - Fixtures (file-private; mirror encryptedMediaTag in darkmatter_iosTests)

/// 32-byte hex (64 chars) by repeating a byte, matching the suite's `hex(_:)`.
private func hex32(_ byte: String) -> String { String(repeating: byte, count: 32) }

/// Canonical 12-byte (24-char) nonce / ciphertext / plaintext used across cases.
private let n = String(repeating: "22", count: 12)
private let c = hex32("44")
private let p = hex32("33")

/// Build an `imeta` tag value array, with knobs for producing malformed inputs.
private func imetaValues(
    file: String,
    ciphertext: String,
    plaintext: String,
    nonce: String,
    mediaType: String,
    dim: String?,
    version: String = MessageSemantics.encryptedMediaVersion,
    extra: [String] = [],
    omitLocator: Bool = false
) -> [String] {
    var values = [MessageSemantics.imetaTag, "v \(version)"]
    if !omitLocator {
        values.append("locator blossom-v1 https://media.example/\(file)")
    }
    values.append("ciphertext_sha256 \(ciphertext)")
    values.append("plaintext_sha256 \(plaintext)")
    values.append("nonce \(nonce)")
    values.append("m \(mediaType)")
    values.append("filename \(file)")
    if let dim { values.append("dim \(dim)") }
    values.append(contentsOf: extra)
    return values
}

/// The reference `mediaAttachment` is expected to produce for a valid `imeta`:
/// hashes/nonce lowercased, media type canonicalized by the caller.
private func ref(
    file: String,
    ciphertext: String,
    plaintext: String,
    nonce: String,
    mediaType: String,
    sourceEpoch: UInt64,
    dim: String?,
    thumbhash: String? = nil
) -> MediaAttachmentReferenceFfi {
    MediaAttachmentReferenceFfi(
        locators: [MediaLocatorFfi(kind: "blossom-v1", value: "https://media.example/\(file)")],
        ciphertextSha256: ciphertext.lowercased(),
        plaintextSha256: plaintext.lowercased(),
        nonceHex: nonce.lowercased(),
        fileName: file,
        mediaType: mediaType,
        version: MessageSemantics.encryptedMediaVersion,
        sourceEpoch: sourceEpoch,
        dim: dim,
        thumbhash: thumbhash
    )
}
