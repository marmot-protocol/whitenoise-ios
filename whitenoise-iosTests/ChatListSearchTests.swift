import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct ChatListSearchTests {
    @Test func matchingIgnoresCaseAndDiacritics() {
        #expect(ChatListSearch.matches(query: "elodie", in: "Élodie and Alice"))
        #expect(ChatListSearch.matches(query: "ALICE", in: "Élodie and Alice"))
        #expect(!ChatListSearch.matches(query: "bob", in: "Élodie and Alice"))
    }

    @Test func blankSearchMatchesEveryRow() {
        #expect(ChatListSearch.matches(query: "  \n", in: "Anything"))
    }
}
