import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
import UniformTypeIdentifiers
@testable import whitenoise_ios
@testable import MarmotKit

struct MediaAttachmentPolicyTests {

    @Test func acceptsAudioVideoAndDocumentMediaTypes() {
        #expect(MediaAttachmentPolicy.isSupported(mediaType: "audio/mp4"))
        #expect(MediaAttachmentPolicy.isSupported(mediaType: "video/mp4"))
        #expect(MediaAttachmentPolicy.isSupported(mediaType: "application/pdf"))
        #expect(MediaAttachmentPolicy.isSupported(mediaType: "text/plain"))
        #expect(!MediaAttachmentPolicy.isSupported(mediaType: "application/x-msdownload"))
    }

    @Test func rejectsSVGFromImageClassificationAndSupport() {
        #expect(MediaAttachmentPolicy.isDecodableImageMediaType("image/png"))
        #expect(MediaAttachmentPolicy.isDecodableImageMediaType("image/jpeg"))
        #expect(!MediaAttachmentPolicy.isDecodableImageMediaType("image/svg+xml"))
        #expect(!MediaAttachmentPolicy.isDecodableImageMediaType("image/svg+xml; charset=utf-8"))
        #expect(!MediaAttachmentPolicy.isDecodableImageMediaType("IMAGE/SVG+XML"))

        // SVG must not classify as an image (it would otherwise reach the
        // ImageIO thumbnail decoder via the peer-controlled MLS media path).
        #expect(MediaAttachmentKind.classify(mediaType: "image/png") == .image)
        #expect(MediaAttachmentKind.classify(mediaType: "image/svg+xml") == .unsupported)
        #expect(!MediaAttachmentPolicy.isSupported(mediaType: "image/svg+xml"))
    }

    @Test func fileExtensionFallsBackWhenPeerFilenameExtensionIsUnsafe() {
        #expect(MediaAttachmentPolicy.fileExtension(for: "image/png", fileName: "safe.PNG") == "png")
        #expect(MediaAttachmentPolicy.fileExtension(for: "image/png", fileName: "nested/x/y") == "png")
        #expect(MediaAttachmentPolicy.fileExtension(for: "application/pdf", fileName: "report.\(String(repeating: "a", count: 13))") == "pdf")
        #expect(MediaAttachmentPolicy.mediaType(forFileExtension: "x/y") == nil)
    }

    @Test(arguments: ["zip", ".md", "README"])
    func extensionlessPeerFilenamesFallBackToTheMediaType(fileName: String) {
        #expect(
            MediaAttachmentPolicy.fileExtension(for: "application/pdf", fileName: fileName)
                == MediaAttachmentPolicy.fileExtension(for: "application/pdf")
        )
    }

    @Test func trailingSlashPeerFilenameKeepsItsExtension() {
        #expect(
            MediaAttachmentPolicy.fileExtension(for: "application/pdf", fileName: "a.md/")
                == MediaAttachmentPolicy.fileExtension(for: "text/markdown")
        )
    }

    @Test func genericDraftPreservesNonImageBytesForUpload() throws {
        let data = Data("hello".utf8)
        let attachment = try MediaDraftProcessor.attachment(
            from: data,
            fileName: "note.txt",
            typeIdentifier: "public.plain-text"
        )

        #expect(attachment.fileName == "note.txt")
        #expect(attachment.mediaType == "text/plain")
        #expect(attachment.data == data)
        #expect(attachment.kind == .document)
        #expect(attachment.thumbhash == nil)
    }

    static let textAndArchiveDocuments: [(fileName: String, typeIdentifier: String?)] = [
        ("README.md", "net.daringfireball.markdown"),
        ("notes.markdown", nil),
        ("config.yaml", "public.yaml"),
        ("compose.yml", nil),
        ("feed.xml", "public.xml"),
        ("bundle.zip", "public.zip-archive"),
        ("page.html", "public.html"),
        ("index.htm", nil),
    ]

    @Test(arguments: textAndArchiveDocuments)
    func markdownYAMLXMLZIPAndHTMLDraftAsDocuments(fileName: String, typeIdentifier: String?) throws {
        let data = Data("<p>hi</p>\n- a: 1\n".utf8)
        let attachment = try MediaDraftProcessor.attachment(
            from: data,
            fileName: fileName,
            typeIdentifier: typeIdentifier
        )

        #expect(attachment.kind == .document)
        #expect(attachment.data == data)
        #expect(MediaAttachmentPolicy.isSupported(mediaType: attachment.mediaType))
        #expect(MediaAttachmentKind.classify(mediaType: attachment.mediaType) == .document)
    }

    @Test(arguments: textAndArchiveDocuments.compactMap { document in
        document.typeIdentifier.map { (document.fileName, $0) }
    })
    func pickedAndFileNameOnlyDraftsSendTheSameMediaType(fileName: String, typeIdentifier: String) throws {
        let data = Data("a: 1\n".utf8)
        let picked = try MediaDraftProcessor.attachment(from: data, fileName: fileName, typeIdentifier: typeIdentifier)
        let fileNameOnly = try MediaDraftProcessor.attachment(from: data, fileName: fileName, typeIdentifier: nil)

        #expect(picked.mediaType == fileNameOnly.mediaType)
    }

    @Test(arguments: textAndArchiveDocuments.map(\.fileName))
    func fileImporterOffersMarkdownYAMLXMLZIPAndHTML(fileName: String) throws {
        let type = try #require(UTType(filenameExtension: (fileName as NSString).pathExtension))
        #expect(MediaAttachmentPolicy.fileImporterAllowedTypes.contains { type.conforms(to: $0) })
    }

    static let documentAliases: [(alias: String, canonical: String)] = [
        ("text/x-markdown", "text/markdown"),
        ("text/yaml", "application/yaml"),
        ("text/x-yaml", "application/yaml"),
        ("application/x-yaml", "application/yaml"),
        ("text/xml", "application/xml"),
        ("application/x-zip-compressed", "application/zip"),
    ]

    @Test(arguments: documentAliases)
    func receivedAliasMediaTypesClassifyAsDocuments(alias: String, canonical: String) {
        #expect(MediaAttachmentKind.classify(mediaType: alias) == .document)
        #expect(MediaAttachmentPolicy.fileExtension(for: alias) == MediaAttachmentPolicy.fileExtension(for: canonical))
    }

    @Test(arguments: ["notes.md", "archive.ZIP"])
    func receivedOctetStreamClassifiesAsDocumentByFileName(fileName: String) {
        #expect(MediaAttachmentKind.classify(mediaType: "application/octet-stream", fileName: fileName) == .document)
    }

    @Test(arguments: ["zip", "html"])
    func extensionlessNamesStayUnsupported(fileName: String) {
        #expect(MediaAttachmentKind.classify(mediaType: "", fileName: fileName) == .unsupported)
    }

    @Test func zipSubtypeDraftIsRejected() {
        let error = #expect(throws: MediaDraftProcessor.Failure.self) {
            try MediaDraftProcessor.attachment(
                from: Data("PK".utf8),
                fileName: "app.jar",
                typeIdentifier: "com.sun.java-archive"
            )
        }
        guard case .unsupportedAttachment = error else {
            Issue.record("Expected unsupportedAttachment, got \(String(describing: error))")
            return
        }
    }

    @Test func imageDraftGeneratesDimAndThumbhashForUpload() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 120), format: format)
        let data = renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 60))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 60, width: 240, height: 60))
        }

        let attachment = try MediaDraftProcessor.attachment(
            from: data,
            fileName: "photo.jpg",
            typeIdentifier: "public.jpeg"
        )

        #expect(attachment.mediaType == "image/jpeg")
        #expect(attachment.dim == "240x120")

        let thumbhash = try #require(attachment.thumbhash)
        #expect(!thumbhash.isEmpty)
        // A ThumbHash is ~25 bytes -> ~34 base64 chars; comfortably under the
        // 128-char encrypted-media bound and standard-base64 alphabet.
        #expect(thumbhash.count <= 128)
        #expect(Data(base64Encoded: thumbhash) != nil)

        // The upload request must carry the generated render hints through to
        // the binding layer.
        let request = attachment.uploadRequest
        #expect(request.dim == "240x120")
        #expect(request.thumbhash == thumbhash)
    }

    @Test func imageThumbhashSurvivesImetaRoundTrip() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let data = renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }

        let attachment = try MediaDraftProcessor.attachment(
            from: data,
            fileName: "photo.jpg",
            typeIdentifier: "public.jpeg"
        )
        let thumbhash = try #require(attachment.thumbhash)

        let reference = MediaAttachmentReferenceFfi(
            locators: [MediaLocatorFfi(
                kind: "blossom-v1",
                value: "https://example.com/\(String(repeating: "a", count: 64)).bin"
            )],
            ciphertextSha256: String(repeating: "a", count: 64),
            plaintextSha256: String(repeating: "b", count: 64),
            nonceHex: String(repeating: "c", count: 24),
            fileName: attachment.fileName,
            mediaType: attachment.mediaType,
            version: .v1,
            sourceEpoch: 7,
            dim: attachment.dim,
            thumbhash: thumbhash
        )

        let tag = MessageSemantics.imetaTag(for: reference)
        #expect(tag.values.contains("thumbhash \(thumbhash)"))

        let decoded = try #require(MessageSemantics.mediaAttachments(
            from: [tag],
            sourceEpoch: 7
        ))
        #expect(decoded.count == 1)
        #expect(decoded[0].thumbhash == thumbhash)
        #expect(decoded[0].dim == attachment.dim)
    }

    @Test func voiceGestureOnlyLocksAfterSlideUpThreshold() {
        #expect(!VoiceRecordingGesturePolicy.shouldLock(translation: CGSize(width: 0, height: -40)))
        #expect(VoiceRecordingGesturePolicy.shouldLock(translation: CGSize(width: 0, height: -90)))
    }

    @Test func terminalAttachmentStatesDoNotWaitOrRetryAutomatically() {
        for state in [AttachmentTransferStateFfi.previouslyAcquiredUnavailable, .completedUnretained,
                      .retryExhausted, .removed, .cancelled, .failed, .policyBlocked, .paused, .unavailable,
                      .storageBlocked] {
            #expect(!AttachmentAcquisitionPresentation.canAwait(state))
        }
        for state in [AttachmentTransferStateFfi.queued, .downloading, .ready, .retryScheduled] {
            #expect(AttachmentAcquisitionPresentation.canAwait(state))
        }
    }

    @Test func storageBlockedDownloadsAskForSpaceInsteadOfShowingARetryTimer() {
        let label = AttachmentTransferPresentation.label(.storageBlocked)
        #expect(label == "Not enough storage. Free up space to download.")
        #expect(label != AttachmentTransferPresentation.label(.retryScheduled))
    }
}
