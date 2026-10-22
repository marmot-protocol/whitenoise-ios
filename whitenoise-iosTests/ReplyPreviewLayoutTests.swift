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
struct ReplyPreviewLayoutTests {

    @Test func closeControlIsCenteredWithMatchingTrailingInset() {
        #expect(ReplyPreviewLayout.contentTopInset == ReplyPreviewLayout.contentBottomInset)
        #expect(ReplyPreviewLayout.closeHitSize >= 44)
        #expect(ReplyPreviewLayout.closeAlignment == .trailing)
        #expect(ReplyPreviewLayout.closeTrailingInset == ReplyPreviewLayout.leadingContentInset)
    }
}
