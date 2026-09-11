import Combine
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import MarmotKit
@testable import whitenoise_ios

@MainActor
private final class LongChatStressModel: ObservableObject {
    @Published var revealsDeferredContent = false
}

private struct LongChatStressRow: Identifiable {
    let id: String
    let initialRecord: AppMessageRecordFfi
    let revealedRecord: AppMessageRecordFfi
    let initialMedia: [MessageMediaAttachment]
    let revealedMedia: [MessageMediaAttachment]
    let reactions: [ConversationViewModel.ReactionTally]
    let replyPreview: ConversationReplyPreview?
    let status: MessageStatus
    let isDeleted: Bool
    let isEdited: Bool

    func record(revealsDeferredContent: Bool) -> AppMessageRecordFfi {
        revealsDeferredContent ? revealedRecord : initialRecord
    }

    func media(revealsDeferredContent: Bool) -> [MessageMediaAttachment] {
        revealsDeferredContent ? revealedMedia : initialMedia
    }
}

private struct LongChatStressFixture {
    static let messageCount = 100

    let rows: [LongChatStressRow]

    init() {
        let imageVariants = Self.makeImageVariants()
        rows = (0..<Self.messageCount).map { index in
            let direction = index.isMultiple(of: 2) ? "sent" : "received"
            let initialLong = index.isMultiple(of: 19) || index == Self.messageCount - 1
            let deferredLong = index < 60 && index.isMultiple(of: 7) && !initialLong
            let initialImage = index.isMultiple(of: 23)
            let deferredImage = index < 60 && index.isMultiple(of: 11) && !initialImage
            let initialBody = Self.body(for: index, isLong: initialLong)
            let revealedBody = Self.body(for: index, isLong: initialLong || deferredLong)
            let initialMedia = initialImage
                ? [Self.imageAttachment(for: index, variants: imageVariants)]
                : []
            let revealedMedia = (initialImage || deferredImage)
                ? [Self.imageAttachment(for: index, variants: imageVariants)]
                : []
            let reactions = index.isMultiple(of: 4)
                ? [
                    ConversationViewModel.ReactionTally(emoji: "👍", count: (index % 3) + 1, mine: index.isMultiple(of: 8)),
                    ConversationViewModel.ReactionTally(emoji: "❤️", count: 2, mine: false),
                ]
                : []
            let reply = index.isMultiple(of: 10)
                ? ConversationReplyPreview(
                    name: index.isMultiple(of: 2) ? "Alex" : "Sam",
                    text: "Earlier message with enough text to wrap onto another line.",
                    media: nil
                )
                : nil
            let status: MessageStatus = if index.isMultiple(of: 31) {
                .failed
            } else if index.isMultiple(of: 29) {
                .sending
            } else if direction == "sent" {
                .sent
            } else {
                .received
            }

            return LongChatStressRow(
                id: "stress-row-\(index)",
                initialRecord: Self.record(index: index, direction: direction, plaintext: initialBody),
                revealedRecord: Self.record(index: index, direction: direction, plaintext: revealedBody),
                initialMedia: initialMedia,
                revealedMedia: revealedMedia,
                reactions: reactions,
                replyPreview: reply,
                status: status,
                isDeleted: index > 0 && index.isMultiple(of: 37),
                isEdited: index > 0 && index.isMultiple(of: 14)
            )
        }
    }

    var initialImageCount: Int {
        rows.filter { !$0.initialMedia.isEmpty }.count
    }

    var revealedImageCount: Int {
        rows.filter { !$0.revealedMedia.isEmpty }.count
    }

    var revealedImagePayloadCount: Int {
        rows.filter { $0.revealedMedia.first?.localData?.isEmpty == false }.count
    }

    var reactionCount: Int {
        rows.filter { !$0.reactions.isEmpty }.count
    }

    var replyCount: Int {
        rows.filter { $0.replyPreview != nil }.count
    }

    var revealedReadMoreCount: Int {
        rows.filter {
            MessageBodyCollapsePresentation.shouldCollapse($0.revealedRecord.plaintext)
        }.count
    }

    private static func body(for index: Int, isLong: Bool) -> String {
        if isLong {
            return (0..<18).map { line in
                "Message \(index), line \(line): this deliberately long paragraph exercises the real collapsed message body and its Read more control."
            }.joined(separator: "\n")
        }
        if index.isMultiple(of: 13) {
            return "🎉"
        }
        if index.isMultiple(of: 6) {
            return "Message \(index) has several lines.\nSecond line for wrapping.\nThird line for varied row geometry."
        }
        return "A normal short message at position \(index)."
    }

    private static func record(
        index: Int,
        direction: String,
        plaintext: String
    ) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: String(format: "%064x", index + 1),
            direction: direction,
            groupIdHex: String(repeating: "aa", count: 32),
            sender: direction == "sent"
                ? String(repeating: "11", count: 32)
                : String(repeating: "22", count: 32),
            plaintext: plaintext,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: UInt64(1_750_000_000 + index),
            receivedAt: UInt64(1_750_000_000 + index)
        )
    }

    private static func makeImageVariants() -> [(image: UIImage, data: Data, dim: String)] {
        [
            makeImage(size: CGSize(width: 320, height: 180), color: .systemIndigo, dim: "640x360"),
            makeImage(size: CGSize(width: 180, height: 320), color: .systemOrange, dim: "360x640"),
            makeImage(size: CGSize(width: 240, height: 240), color: .systemTeal, dim: "480x480"),
        ]
    }

    private static func makeImage(
        size: CGSize,
        color: UIColor,
        dim: String
    ) -> (image: UIImage, data: Data, dim: String) {
        let image = UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.75).setFill()
            context.cgContext.fillEllipse(in: CGRect(
                x: size.width * 0.25,
                y: size.height * 0.25,
                width: size.width * 0.5,
                height: size.height * 0.5
            ))
        }
        return (image, image.pngData() ?? Data(), dim)
    }

    private static func imageAttachment(
        for index: Int,
        variants: [(image: UIImage, data: Data, dim: String)]
    ) -> MessageMediaAttachment {
        let variant = variants[index % variants.count]
        let attachment = MessageMediaAttachment(
            id: "stress-image-\(index)",
            reference: nil,
            fileName: "stress-image-\(index).png",
            mediaType: "image/png",
            dim: variant.dim,
            localData: variant.data,
            thumbnail: variant.image
        )
        let displaySize = MessageImageBubblePresentation.displaySize(
            maxWidth: MessageBubbleReplyLayout.richContentWidth,
            dim: variant.dim
        )
        MessageMediaThumbnailDecoder.store(
            variant.image,
            sourceData: variant.data,
            for: MessageMediaThumbnailPresentation.cacheKey(for: attachment),
            maxPixelSize: Int(ceil(max(displaySize.width, displaySize.height)))
        )
        return attachment
    }
}

private struct LongChatScrollHarness: View {
    static let bottomID = "long-chat-bottom"

    @ObservedObject var model: LongChatStressModel
    let fixture: LongChatStressFixture
    let appState: AppState
    let onViewportChanged: (TimelineBottomViewport) -> Void
    let onVisibleTargetsChanged: (Set<String>) -> Void

    @State private var didFinishInitialPositioning = false
    @State private var scrollRequestGeneration = 0

    private let mediaLoader = ConversationMediaLoader { item in
        item.localData ?? Data()
    }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { outer in
                ScrollView {
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(fixture.rows) { row in
                                MessageBubble(
                                    record: row.record(revealsDeferredContent: model.revealsDeferredContent),
                                    status: row.status,
                                    isDeleted: row.isDeleted,
                                    isEdited: row.isEdited,
                                    replyPreview: row.replyPreview,
                                    mediaItems: row.media(revealsDeferredContent: model.revealsDeferredContent),
                                    reactions: row.reactions,
                                    onLoadMedia: mediaLoader
                                )
                                .id(row.id)
                            }
                            ForEach([Self.bottomID], id: \.self) { _ in
                                Color.clear
                                    .frame(height: 2)
                                    .id(Self.bottomID)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .padding(.top, 8)
                    .padding(.bottom, BottomInputChromeLayout.timelineComposerSpacing)
                    .frame(minHeight: max(0, outer.size.height), alignment: .bottom)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .task(id: scrollRequestGeneration) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
                .onAppear {
                    scrollRequestGeneration &+= 1
                }
                .onScrollTargetVisibilityChange(
                    idType: String.self,
                    threshold: TimelineViewportVisibility.minimumVisibleFraction
                ) { visibleIDs in
                    let targets = Set(visibleIDs)
                    onVisibleTargetsChanged(targets)
                    if targets.contains(Self.bottomID) {
                        didFinishInitialPositioning = true
                    }
                }
                .onScrollGeometryChange(for: TimelineBottomViewport.self) { geometry in
                    TimelineBottomViewport(
                        contentHeight: geometry.contentSize.height,
                        visibleBottomY: geometry.visibleRect.maxY,
                        bottomContentInset: geometry.contentInsets.bottom
                    )
                } action: { _, viewport in
                    onViewportChanged(viewport)
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentSize.height
                } action: { _, _ in
                    if !didFinishInitialPositioning {
                        scrollRequestGeneration &+= 1
                        return
                    }
                    guard TimelineBottomScrollCoordinator.shouldFollowLayoutChange(
                        didFinishInitialPositioning: didFinishInitialPositioning,
                        userMovedAwayFromBottom: false,
                        isUserScrolling: false
                    ) else { return }
                    scrollRequestGeneration &+= 1
                }
            }
        }
        .environment(\.displayScale, 1)
        .environment(appState)
    }
}

@MainActor
@Suite(.serialized)
struct ConversationLongChatScrollTests {
    private static let settleTimeout = Duration.seconds(20)

    private func settle(_ window: UIWindow, until isSettled: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: Self.settleTimeout)
        while true {
            window.layoutIfNeeded()
            if isSettled() { return }
            guard ContinuousClock.now < deadline else { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func heterogeneousHundredMessageChatStaysAtBottomAsRowsExpand() async throws {
        let fixture = LongChatStressFixture()
        #expect(fixture.rows.count == LongChatStressFixture.messageCount)
        #expect(fixture.initialImageCount >= 4)
        #expect(fixture.revealedImageCount >= 9)
        #expect(fixture.revealedImagePayloadCount == fixture.revealedImageCount)
        #expect(fixture.reactionCount >= 20)
        #expect(fixture.replyCount >= 8)
        #expect(fixture.revealedReadMoreCount >= 12)
        #expect(MessageBodyCollapsePresentation.shouldCollapse(fixture.rows.last?.initialRecord.plaintext ?? ""))

        let model = LongChatStressModel()
        let appState = AppState(client: try MarmotClient.testClient())
        var lastViewport: TimelineBottomViewport?
        var visibleTargets = Set<String>()
        let controller = UIHostingController(
            rootView: LongChatScrollHarness(
                model: model,
                fixture: fixture,
                appState: appState,
                onViewportChanged: { lastViewport = $0 },
                onVisibleTargetsChanged: { visibleTargets = $0 }
            )
        )
        let windowScene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        try await settle(window) {
            lastViewport?.isPinned == true
                && visibleTargets.contains(LongChatScrollHarness.bottomID)
        }
        let initialContentHeight = try #require(lastViewport?.contentHeight)
        #expect(lastViewport?.isPinned == true, "Initial viewport: \(String(describing: lastViewport))")
        #expect(
            visibleTargets.contains(LongChatScrollHarness.bottomID),
            "Initial targets: \(visibleTargets.sorted()) viewport: \(String(describing: lastViewport))"
        )

        model.revealsDeferredContent = true
        try await settle(window) {
            (lastViewport?.contentHeight ?? 0) > initialContentHeight + 1_000
                && lastViewport?.isPinned == true
                && visibleTargets.contains(LongChatScrollHarness.bottomID)
        }

        #expect(
            (lastViewport?.contentHeight ?? 0) > initialContentHeight + 1_000,
            "Expected deferred long text and image rows above the viewport to grow the timeline"
        )
        #expect(lastViewport?.isPinned == true, "Final viewport: \(String(describing: lastViewport))")
        #expect(
            visibleTargets.contains(LongChatScrollHarness.bottomID),
            "Final targets: \(visibleTargets.sorted()) viewport: \(String(describing: lastViewport))"
        )
    }
}
