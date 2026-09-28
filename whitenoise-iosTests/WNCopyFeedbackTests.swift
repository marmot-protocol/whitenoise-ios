import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

struct WNCopyFeedbackTests {
    @MainActor
    @Test func confirmationKeepsTheCopyRowSizeAtStandardAndAccessibleTextSizes() {
        for size in [DynamicTypeSize.large, .accessibility1] {
            let dimensions = [false, true].map { copied in
                let host = UIHostingController(rootView:
                    HStack(spacing: 6) {
                        Text("Group ID").font(.caption.monospaced())
                        WNCopyIcon(copied: copied).font(.caption)
                    }.fixedSize().environment(\.dynamicTypeSize, size)
                )
                return host.sizeThatFits(in: CGSize(width: 390, height: 100))
            }
            #expect(abs(dimensions[0].width - dimensions[1].width) < 0.5)
            #expect(abs(dimensions[0].height - dimensions[1].height) < 0.5)
        }
    }

    @Test func offersACopyGlyphBeforeCopying() {
        #expect(WNCopyFeedback.symbolName(isCopied: false) == "doc.on.doc")
    }

    @Test func confirmsWithACheckmarkAfterCopying() {
        #expect(WNCopyFeedback.symbolName(isCopied: true) == "checkmark")
    }

    @Test func accessibilityLabelNamesTheValueBeforeCopying() {
        let label = WNCopyFeedback.accessibilityLabel(isCopied: false, copyTitle: L10n.formatted("Copy %@", "npub"))

        #expect(label.contains("npub"))
        #expect(label != L10n.string("Copied"))
    }

    @Test func accessibilityLabelConfirmsTheCopyAfterwards() {
        let label = WNCopyFeedback.accessibilityLabel(isCopied: true, copyTitle: L10n.formatted("Copy %@", "npub"))

        #expect(label == L10n.string("Copied"))
    }

    @Test func copyFeedbackResetsAfterABoundedDelay() {
        #expect(WNCopyFeedback.resetDelay > .zero)
        #expect(WNCopyFeedback.resetDelay <= .seconds(5))
    }
}
