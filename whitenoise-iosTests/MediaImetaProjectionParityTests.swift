import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

/// Pins the generated MDK `imeta` parser plus the app's narrow display-safety
/// projection. MDK owns the wire contract; iOS only bounds peer-controlled
/// filename/media-type strings and drops malformed optional display hints.
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
            name: "legacy V1 media type spelling is preserved for AAD",
            imeta: [imetaValues(file: "a.jpg", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/jpg", dim: nil)],
            sourceEpoch: 1,
            expected: [ref(file: "a.jpg", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/jpg", sourceEpoch: 1, dim: nil)]
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
            name: "legacy blurhash field is rejected by MDK",
            imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil, extra: ["blurhash LEHV6nWB2yk8pyo0adR*"])],
            sourceEpoch: 3,
            expected: nil
        ),
        Case(
            name: "encrypted-media-v2 is accepted and remains typed v2",
            imeta: [imetaValues(
                file: "v2.png",
                ciphertext: c,
                plaintext: p,
                nonce: n,
                mediaType: "image/png",
                dim: nil,
                version: EncryptedMediaVersionFfi.v2.wireValue
            )],
            sourceEpoch: 4,
            expected: [ref(
                file: "v2.png",
                ciphertext: c,
                plaintext: p,
                nonce: n,
                mediaType: "image/png",
                sourceEpoch: 4,
                dim: nil,
                version: .v2
            )]
        ),

        // --- Malformed required fields degrade that attachment to nil ---
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
        Case(name: "legacy V1 minimally structured media type is preserved",
             imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/", dim: nil)],
             sourceEpoch: 1,
             expected: [ref(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/", sourceEpoch: 1, dim: nil)]),
        Case(name: "invalid dim is ignored",
             imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: "640")],
             sourceEpoch: 1,
             expected: [ref(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", sourceEpoch: 1, dim: nil)]),
        Case(name: "overlong thumbhash is ignored",
             imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil, extra: ["thumbhash \(String(repeating: "x", count: 129))"])],
             sourceEpoch: 1,
             expected: [ref(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", sourceEpoch: 1, dim: nil)]),
        Case(name: "filename at 255-byte cap -> valid",
             imeta: [imetaValues(file: String(repeating: "a", count: 255), ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil)],
             sourceEpoch: 1,
             expected: [ref(file: String(repeating: "a", count: 255), ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", sourceEpoch: 1, dim: nil)]),
        Case(name: "filename over 255-byte cap -> nil",
             imeta: [imetaValues(file: String(repeating: "a", count: 256), ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil)],
             sourceEpoch: 1, expected: nil),
        Case(name: "media type at 127-byte cap -> valid",
             imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/\(String(repeating: "a", count: 121))", dim: nil)],
             sourceEpoch: 1,
             expected: [ref(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/\(String(repeating: "a", count: 121))", sourceEpoch: 1, dim: nil)]),
        Case(name: "media type over 127-byte cap -> nil",
             imeta: [imetaValues(file: "a.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/\(String(repeating: "a", count: 122))", dim: nil)],
             sourceEpoch: 1, expected: nil),

        // --- The drop-bad rule across multiple attachments ---
        Case(
            name: "one valid + one malformed -> keep valid attachment",
            imeta: [
                imetaValues(file: "good.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil),
                imetaValues(file: "bad.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil, omitLocator: true),
            ],
            sourceEpoch: 1,
            expected: [ref(file: "good.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", sourceEpoch: 1, dim: nil)]
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

    /// A single bad `imeta` among valid ones drops only the malformed
    /// attachment, so a hostile or corrupt optional attachment cannot hide
    /// valid encrypted media in the same message.
    @Test func oneMalformedImetaKeepsValidAttachments() {
        let good = imetaValues(file: "good.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil)
        let bad = imetaValues(file: "bad.png", ciphertext: c, plaintext: p, nonce: n, mediaType: "image/png", dim: nil, omitLocator: true)

        let bothValid = MessageSemantics.mediaAttachments(
            from: [good, good].map { MessageTagFfi(values: $0) }, sourceEpoch: 1)
        #expect(bothValid?.count == 2)

        let oneBad = MessageSemantics.mediaAttachments(
            from: [good, bad].map { MessageTagFfi(values: $0) }, sourceEpoch: 1)
        #expect(oneBad?.map(\.fileName) == ["good.png"])
    }

    /// Peer-controlled `filename` / `m` are byte-length capped, mirroring the
    /// thumbhash/dim bounds. A field one byte over its cap degrades the whole
    /// message to chat text; at the cap it still parses. Guards against
    /// flood-sized attacker strings entering the model/UI/transcript export.
    @Test func filenameAndMediaTypeAreByteLengthCapped() {
        func attachment(filename: String, mediaType: String) -> [MediaAttachmentReferenceFfi]? {
            let tag = MessageTagFfi(values: imetaValues(
                file: filename, ciphertext: c, plaintext: p, nonce: n, mediaType: mediaType, dim: nil))
            return MessageSemantics.mediaAttachments(from: [tag], sourceEpoch: 1)
        }

        #expect(attachment(filename: String(repeating: "a", count: 255), mediaType: "image/png") != nil)
        #expect(attachment(filename: String(repeating: "a", count: 256), mediaType: "image/png") == nil)

        #expect(attachment(filename: "a.png", mediaType: "image/\(String(repeating: "a", count: 121))") != nil)
        #expect(attachment(filename: "a.png", mediaType: "image/\(String(repeating: "a", count: 122))") == nil)
    }

    @Test func imetaTagCountIsCappedBeforeParsing() {
        let tags = (0..<(MessageSemantics.maxImetaTags + 3)).map { index in
            MessageTagFfi(values: imetaValues(
                file: "file-\(index).png",
                ciphertext: hex32(String(format: "%02x", index + 1)),
                plaintext: hex32(String(format: "%02x", index + 41)),
                nonce: n,
                mediaType: "image/png",
                dim: nil
            ))
        }

        let attachments = MessageSemantics.mediaAttachments(from: tags, sourceEpoch: 1)

        #expect(attachments?.count == MessageSemantics.maxImetaTags)
        #expect(attachments?.last?.fileName == "file-\(MessageSemantics.maxImetaTags - 1).png")
    }

    // MARK: - Bindings landed (whitenoise 127fe17): how parity is enforced now
    //
    // PR whitenoise#570 resolves `media: [MediaAttachmentReferenceFfi]` on
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
    // STATUS: the media slice has landed. The conversation now mirrors
    // `record.media` into the media projection cache at ingest and the
    // `listMedia` timeline path + its index maps are deleted. `MessageSemantics`
    // `mediaAttachments` is RETAINED as the fallback for local/optimistic records
    // that have no row projection yet, so this corpus pins the same tolerant
    // drop-bad behavior expected from the Rust row path (`record.media`).
}

// MARK: - Fixtures (file-private; mirror encryptedMediaTag in MessageSemanticsTests)

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
    version: String = EncryptedMediaVersionFfi.v1.wireValue,
    extra: [String] = [],
    omitLocator: Bool = false
) -> [String] {
    var values = [MessageSemantics.imetaTag, "v \(version)"]
    if !omitLocator {
        values.append("locator blossom-v1 https://media.example/\(ciphertext).bin")
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
    thumbhash: String? = nil,
    version: EncryptedMediaVersionFfi = .v1
) -> MediaAttachmentReferenceFfi {
    MediaAttachmentReferenceFfi(
        locators: [MediaLocatorFfi(kind: "blossom-v1", value: "https://media.example/\(ciphertext).bin")],
        ciphertextSha256: ciphertext.lowercased(),
        plaintextSha256: plaintext.lowercased(),
        nonceHex: nonce.lowercased(),
        fileName: file,
        mediaType: mediaType,
        version: version,
        sourceEpoch: sourceEpoch,
        dim: dim,
        thumbhash: thumbhash
    )
}
