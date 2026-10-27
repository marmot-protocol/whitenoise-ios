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
struct IdentityFormatterTests {

    @Test func shortTruncatesLongStrings() {
        let long = "npub1abcdefghijklmnopqrstuvwxyz0123456789"
        let s = IdentityFormatter.short(long)
        #expect(s.contains("…"))
        #expect(s.count < long.count)
    }

    @Test func shortPassesShortStringsUnchanged() {
        let short = "abc"
        #expect(IdentityFormatter.short(short) == short)
    }

}
