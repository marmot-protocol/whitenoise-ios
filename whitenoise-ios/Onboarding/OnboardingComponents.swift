import SwiftUI
import UIKit

enum OnboardingSheetContent: Equatable {
    case welcome
    case signIn
    case signUp

    var prefersCompactHeight: Bool {
        self == .signIn
    }
}
