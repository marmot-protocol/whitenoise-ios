import SwiftUI
import XCTest
import UIKit
@testable import whitenoise_ios

// Keyboard focus belongs to the shared test host. Run with the sequential
// XCTest window tests, outside Swift Testing's concurrently executing suites.
@MainActor
final class PrivateKeyAutoFillTests: XCTestCase {
    private static let key = "nsec1" + String(repeating: "q", count: 58)

    func testProviderFillWhileThePickerHoldsFocusSettlesOnce() async throws {
        let harness = try Harness()
        defer { harness.close() }
        try await harness.focusFromSwiftUI()
        let changeCount = UIPasteboard.general.changeCount

        harness.presentPicker()
        XCTAssertFalse(harness.model.isFocused)
        harness.provide(Self.key)

        XCTAssertTrue(harness.field.rightView is UIPasteControl, "Accessory waits for the insertion to unwind")
        try await harness.settle()
        XCTAssertEqual(harness.field.text, Self.key)
        XCTAssertEqual(harness.model.text, Self.key)
        XCTAssertEqual(harness.model.textWrites, 1)
        XCTAssertTrue(harness.field.isFirstResponder)
        XCTAssertTrue(harness.model.isFocused)
        XCTAssertTrue(harness.field.isSecureTextEntry)
        XCTAssertEqual(harness.field.textContentType, .password)
        XCTAssertTrue(harness.field.rightView is UIButton)
        XCTAssertEqual(harness.field.rightViewMode, .always)
        let selection = try XCTUnwrap(harness.field.selectedTextRange)
        XCTAssertEqual(harness.field.compare(selection.end, to: harness.field.endOfDocument), .orderedSame)
        XCTAssertEqual(harness.model.pastes, 0)
        XCTAssertEqual(UIPasteboard.general.changeCount, changeCount)

        harness.field.delegate?.textFieldShouldReturn?(harness.field)
        XCTAssertEqual(harness.model.submits, 1)
    }

    func testTextFillWhileUnfocusedReachesTheBinding() async throws {
        try await checkFillWithoutEditingChanged(.textWhileUnfocused)
    }

    func testAttributedTextFillWhileUnfocusedReachesTheBinding() async throws {
        try await checkFillWithoutEditingChanged(.attributedTextWhileUnfocused)
    }

    func testTextFillWhileFocusedReachesTheBinding() async throws {
        try await checkFillWithoutEditingChanged(.textWhileFocused)
    }

    private func checkFillWithoutEditingChanged(_ delivery: SilentFill) async throws {
        let harness = try Harness()
        defer { harness.close() }
        try await harness.focusFromSwiftUI()

        harness.presentPicker()
        harness.fillSilently(Self.key, delivery)
        harness.model.showsAccessory = false
        harness.controller.view.layoutIfNeeded()
        harness.model.showsAccessory = true
        try await harness.settle()

        XCTAssertEqual(harness.field.text, Self.key)
        XCTAssertEqual(harness.model.text, Self.key)
        XCTAssertEqual(harness.model.textWrites, 1)
        XCTAssertTrue(harness.field.rightView is UIButton)
        XCTAssertTrue(harness.field.isFirstResponder)
        XCTAssertTrue(harness.model.isFocused)
        XCTAssertEqual(harness.model.pastes, 0)
    }

    func testCancellingThePickerLeavesTheFieldUntouched() async throws {
        let harness = try Harness()
        defer { harness.close() }
        try await harness.focusFromSwiftUI()

        harness.presentPicker()
        harness.field.becomeFirstResponder()
        try await harness.settle()

        XCTAssertTrue(harness.field.text?.isEmpty ?? true)
        XCTAssertEqual(harness.model.textWrites, 0)
        XCTAssertTrue(harness.model.isFocused)
        XCTAssertTrue(harness.field.isFirstResponder)
        XCTAssertTrue(harness.field.rightView is UIPasteControl)
    }

    func testRepeatedAndEmptyProviderFillsKeepTheLatestValue() async throws {
        let harness = try Harness()
        defer { harness.close() }
        try await harness.focusFromSwiftUI()

        for credential in ["nsec1first", Self.key, Self.key] {
            harness.presentPicker()
            harness.provide(credential)
        }
        try await harness.settle()
        XCTAssertEqual(harness.model.text, Self.key)
        XCTAssertEqual(harness.model.textWrites, 2)
        XCTAssertTrue(harness.field.rightView is UIButton)

        harness.presentPicker()
        harness.provide("")
        try await harness.settle()
        XCTAssertTrue(harness.model.text.isEmpty)
        XCTAssertTrue(harness.field.rightView is UIPasteControl)
        XCTAssertTrue(harness.field.isFirstResponder)
        XCTAssertTrue(harness.model.isFocused)
    }

    func testSwiftUIFocusAndAccessoryChangesApplyAfterTheUpdate() async throws {
        let harness = try Harness()
        defer { harness.close() }
        try await harness.focusFromSwiftUI()
        harness.presentPicker()
        harness.provide(Self.key)
        try await harness.settle()

        harness.model.showsAccessory = false
        harness.model.isFocused = false
        try await harness.settle()
        XCTAssertEqual(harness.field.rightViewMode, .never)
        XCTAssertFalse(harness.field.isFirstResponder)

        harness.model.showsAccessory = true
        harness.model.text = ""
        try await harness.settle()
        XCTAssertTrue(harness.field.text?.isEmpty ?? true)
        XCTAssertTrue(harness.field.rightView is UIPasteControl)
        XCTAssertEqual(harness.field.rightViewMode, .always)
        XCTAssertFalse(harness.model.isFocused)
    }

    func testRemovingTheFieldWithPendingWorkLeavesNoResponder() async throws {
        let harness = try Harness()
        defer { harness.close() }
        try await harness.focusFromSwiftUI()

        harness.presentPicker()
        harness.provide(Self.key)
        harness.model.isFocused = false
        harness.model.showsField = false
        try await harness.settle()

        XCTAssertNil(harness.field.window)
        XCTAssertFalse(harness.field.isFirstResponder)
        XCTAssertEqual(harness.model.text, Self.key)
    }
}

private enum SilentFill {
    case textWhileUnfocused
    case attributedTextWhileUnfocused
    case textWhileFocused
}

@MainActor
@Observable
private final class HarnessModel {
    var text = "" { didSet { textWrites += 1 } }
    var textWrites = 0
    var isFocused = false
    var showsAccessory = true
    var showsField = true
    var pastes = 0
    var submits = 0
}

private struct HarnessView: View {
    @Bindable var model: HarnessModel

    var body: some View {
        VStack {
            if model.showsField {
                PasteAwareSecureField(
                    text: $model.text,
                    isFocused: $model.isFocused,
                    showsAccessory: model.showsAccessory,
                    onPaste: { _, _ in model.pastes += 1 },
                    onSubmit: { model.submits += 1 }
                )
                .frame(width: 320, height: 50)
            }
            Text(model.text.isEmpty ? "empty" : "filled")
        }
    }
}

@MainActor
private struct Harness {
    let model = HarnessModel()
    let window: UIWindow
    let previousKeyWindow: UIWindow?
    let controller: UIHostingController<HarnessView>
    let field: PasteInterceptingSecureTextField

    init() throws {
        controller = UIHostingController(rootView: HarnessView(model: model))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.keyWindow
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        field = try XCTUnwrap(Self.secureField(in: controller.view))
    }

    func focusFromSwiftUI() async throws {
        model.isFocused = true
        try await settle()
        XCTAssertTrue(field.isFirstResponder)
    }

    func presentPicker() {
        field.resignFirstResponder()
        controller.view.layoutIfNeeded()
    }

    func provide(_ credential: String) {
        field.becomeFirstResponder()
        let whole = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        if let whole { field.replace(whole, withText: credential) } else { field.text = credential }
        field.sendActions(for: .editingChanged)
        controller.view.layoutIfNeeded()
    }

    func fillSilently(_ credential: String, _ delivery: SilentFill) {
        switch delivery {
        case .textWhileUnfocused:
            field.text = credential
            field.becomeFirstResponder()
        case .attributedTextWhileUnfocused:
            field.attributedText = NSAttributedString(string: credential)
            field.becomeFirstResponder()
        case .textWhileFocused:
            field.becomeFirstResponder()
            field.text = credential
        }
        controller.view.layoutIfNeeded()
    }

    func settle() async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(10))
            controller.view.layoutIfNeeded()
        }
    }

    func close() {
        field.resignFirstResponder()
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }

    private static func secureField(in view: UIView) -> PasteInterceptingSecureTextField? {
        if let field = view as? PasteInterceptingSecureTextField { return field }
        return view.subviews.lazy.compactMap { secureField(in: $0) }.first
    }
}
