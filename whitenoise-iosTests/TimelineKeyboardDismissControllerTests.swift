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
struct TimelineKeyboardDismissControllerTests {

    @Test func installsNonCancellingTapDirectlyOnScrollView() {
        var tapCount = 0
        let controller = TimelineKeyboardDismissController { tapCount += 1 }
        let scrollView = UIScrollView()

        controller.install(on: scrollView)

        #expect(controller.installedScrollView === scrollView)
        #expect(controller.recognizer.view === scrollView)
        #expect(!controller.recognizer.cancelsTouchesInView)
        #expect(!controller.recognizer.delaysTouchesBegan)
        #expect(!controller.recognizer.delaysTouchesEnded)
        #expect(!controller.gestureRecognizer(
            controller.recognizer,
            shouldRecognizeSimultaneouslyWith: scrollView.panGestureRecognizer
        ))
        #expect(controller.gestureRecognizer(
            controller.recognizer,
            shouldRequireFailureOf: scrollView.panGestureRecognizer
        ))
        let otherTap = UITapGestureRecognizer()
        #expect(controller.gestureRecognizer(
            controller.recognizer,
            shouldRecognizeSimultaneouslyWith: otherTap
        ))
        #expect(!controller.gestureRecognizer(
            controller.recognizer,
            shouldRequireFailureOf: otherTap
        ))

        controller.handleRecognizedTap()
        #expect(tapCount == 1)

        controller.uninstall()
        #expect(controller.installedScrollView == nil)
        #expect(controller.recognizer.view == nil)
    }

    @Test func attachmentResolvesTheEnclosingTimelineScrollView() {
        let controller = TimelineKeyboardDismissController {}
        let scrollView = UIScrollView()
        let contentView = UIView()
        let attachmentView = TimelineKeyboardDismissAttachmentView()
        attachmentView.controller = controller

        scrollView.addSubview(contentView)
        contentView.addSubview(attachmentView)
        attachmentView.resolveScrollView()

        #expect(controller.installedScrollView === scrollView)
        #expect(controller.recognizer.view === scrollView)

        controller.uninstall()
    }
}
