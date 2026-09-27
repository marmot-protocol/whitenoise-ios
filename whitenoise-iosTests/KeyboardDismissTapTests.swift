import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct KeyboardDismissTapTests {
    @Test func dismissesWhenNothingWasTouched() {
        #expect(KeyboardDismissTap.resignsKeyboard(touching: nil))
    }

    @Test func dismissesOnPlainContent() {
        #expect(KeyboardDismissTap.resignsKeyboard(touching: UIView()))
    }

    @Test func leavesControlFocusDecisionsToTheControl() {
        #expect(!KeyboardDismissTap.resignsKeyboard(touching: UIButton()))
    }

    @Test func keepsKeyboardWhenTappingATextField() {
        #expect(!KeyboardDismissTap.resignsKeyboard(touching: UITextField()))
        #expect(!KeyboardDismissTap.resignsKeyboard(touching: UITextView()))
    }

    @Test func keepsKeyboardWhenTappingInsideATextFieldSubview() {
        let field = UITextField()
        let inner = UIView()
        field.addSubview(inner)
        #expect(!KeyboardDismissTap.resignsKeyboard(touching: inner))
    }

    @Test func dismissesForSiblingsOfATextField() {
        let row = UIView()
        let field = UITextField()
        let label = UILabel()
        row.addSubview(field)
        row.addSubview(label)
        #expect(KeyboardDismissTap.resignsKeyboard(touching: label))
    }

    @Test func inputChromeProtectsOnlyItsVisibleAreaInItsOwnWindow() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.isHidden = false
        defer { window.isHidden = true }
        let region = KeyboardInputRegion(frame: CGRect(x: 20, y: 100, width: 280, height: 50))
        window.addSubview(region)
        #expect(KeyboardInputRegion.contains(CGPoint(x: 25, y: 105), in: window))
        #expect(!KeyboardInputRegion.contains(CGPoint(x: 10, y: 105), in: window))
        #expect(!KeyboardInputRegion.contains(CGPoint(x: 25, y: 105), in: UIWindow()))
        region.isHidden = true
        #expect(!KeyboardInputRegion.contains(CGPoint(x: 25, y: 105), in: window))
        region.removeFromSuperview()
        #expect(!KeyboardInputRegion.contains(CGPoint(x: 25, y: 105), in: window))
    }
}
