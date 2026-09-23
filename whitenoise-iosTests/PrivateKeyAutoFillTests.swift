import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct PrivateKeyAutoFillTests {
    private static let key = "nsec1" + String(repeating: "q", count: 58)

    @Test
    func providerFillWhileThePickerHoldsFocusSettlesOnce() async throws {
        let harness = try Harness()
        defer { harness.close() }
        try await harness.focusFromSwiftUI()
        let changeCount = UIPasteboard.general.changeCount

        harness.presentPicker()
        #expect(harness.model.isFocused == false)
        harness.provide(Self.key)

        #expect(harness.field.rightView is UIPasteControl, "Accessory waits for the insertion to unwind")
        try await harness.settle()
        #expect(harness.field.text == Self.key)
        #expect(harness.model.text == Self.key)
        #expect(harness.model.textWrites == 1)
        #expect(harness.field.isFirstResponder)
        #expect(harness.model.isFocused)
        #expect(harness.field.isSecureTextEntry)
        #expect(harness.field.textContentType == .password)
        #expect(harness.field.rightView is UIButton)
        #expect(harness.field.rightViewMode == .always)
        let selection = try #require(harness.field.selectedTextRange)
        #expect(harness.field.compare(selection.end, to: harness.field.endOfDocument) == .orderedSame)
        #expect(harness.model.pastes == 0)
        #expect(UIPasteboard.general.changeCount == changeCount)

        harness.field.delegate?.textFieldShouldReturn?(harness.field)
        #expect(harness.model.submits == 1)
    }

    @Test(arguments: SilentFill.allCases)
    func fillWithoutEditingChangedStillReachesTheBinding(_ delivery: SilentFill) async throws {
        let harness = try Harness()
        defer { harness.close() }
        try await harness.focusFromSwiftUI()

        harness.presentPicker()
        harness.fillSilently(Self.key, delivery)
        harness.model.showsAccessory = false
        harness.controller.view.layoutIfNeeded()
        harness.model.showsAccessory = true
        try await harness.settle()

        #expect(harness.field.text == Self.key)
        #expect(harness.model.text == Self.key)
        #expect(harness.model.textWrites == 1)
        #expect(harness.field.rightView is UIButton)
        #expect(harness.field.isFirstResponder)
        #expect(harness.model.isFocused)
        #expect(harness.model.pastes == 0)
    }

    @Test
    func cancellingThePickerLeavesTheFieldUntouched() async throws {
        let harness = try Harness()
        defer { harness.close() }
        try await harness.focusFromSwiftUI()

        harness.presentPicker()
        harness.field.becomeFirstResponder()
        try await harness.settle()

        #expect(harness.field.text?.isEmpty ?? true)
        #expect(harness.model.textWrites == 0)
        #expect(harness.model.isFocused)
        #expect(harness.field.isFirstResponder)
        #expect(harness.field.rightView is UIPasteControl)
    }

    @Test
    func repeatedAndEmptyProviderFillsKeepTheLatestValue() async throws {
        let harness = try Harness()
        defer { harness.close() }
        try await harness.focusFromSwiftUI()

        for credential in ["nsec1first", Self.key, Self.key] {
            harness.presentPicker()
            harness.provide(credential)
        }
        try await harness.settle()
        #expect(harness.model.text == Self.key)
        #expect(harness.model.textWrites == 2)
        #expect(harness.field.rightView is UIButton)

        harness.presentPicker()
        harness.provide("")
        try await harness.settle()
        #expect(harness.model.text.isEmpty)
        #expect(harness.field.rightView is UIPasteControl)
        #expect(harness.field.isFirstResponder)
        #expect(harness.model.isFocused)
    }

    @Test
    func swiftUIFocusAndAccessoryChangesApplyAfterTheUpdate() async throws {
        let harness = try Harness()
        defer { harness.close() }
        try await harness.focusFromSwiftUI()
        harness.presentPicker()
        harness.provide(Self.key)
        try await harness.settle()

        harness.model.showsAccessory = false
        harness.model.isFocused = false
        try await harness.settle()
        #expect(harness.field.rightViewMode == .never)
        #expect(harness.field.isFirstResponder == false)

        harness.model.showsAccessory = true
        harness.model.text = ""
        try await harness.settle()
        #expect(harness.field.text?.isEmpty ?? true)
        #expect(harness.field.rightView is UIPasteControl)
        #expect(harness.field.rightViewMode == .always)
        #expect(harness.model.isFocused == false)
    }

    @Test
    func removingTheFieldWithPendingWorkLeavesNoResponder() async throws {
        let harness = try Harness()
        defer { harness.close() }
        try await harness.focusFromSwiftUI()

        harness.presentPicker()
        harness.provide(Self.key)
        harness.model.isFocused = false
        harness.model.showsField = false
        try await harness.settle()

        #expect(harness.field.window == nil)
        #expect(harness.field.isFirstResponder == false)
        #expect(harness.model.text == Self.key)
    }
}

enum SilentFill: CaseIterable, Sendable {
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
                    onClear: {},
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
    let controller: UIHostingController<HarnessView>
    let field: PasteInterceptingSecureTextField

    init() throws {
        controller = UIHostingController(rootView: HarnessView(model: model))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        field = try #require(Self.secureField(in: controller.view))
    }

    func focusFromSwiftUI() async throws {
        model.isFocused = true
        try await settle()
        #expect(field.isFirstResponder)
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
    }

    private static func secureField(in view: UIView) -> PasteInterceptingSecureTextField? {
        if let field = view as? PasteInterceptingSecureTextField { return field }
        return view.subviews.lazy.compactMap { secureField(in: $0) }.first
    }
}
