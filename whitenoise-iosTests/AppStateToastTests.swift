import Testing
import Foundation
@testable import whitenoise_ios
@testable import MarmotKit

/// Toast presentation on `AppState` and its focused `ToastState`.
@MainActor
struct AppStateToastTests {
    @Test func presentingAToastUpdatesActiveToast() async throws {
        let appState = AppState.test()
        await MainActor.run {
            appState.present(.success("Hello"))
        }
        #expect(appState.activeToast?.title == "Hello")
        #expect(appState.activeToast?.style == .success)

        await MainActor.run { appState.dismissToast() }
        #expect(appState.activeToast == nil)
    }

    @Test func toastPresentationIsBackedByFocusedToastState() async throws {
        let appState = AppState.test()
        await MainActor.run {
            appState.present(.success("Hello"))
        }

        #expect(appState.toastState.activeToast?.title == "Hello")
        #expect(appState.activeToast == appState.toastState.activeToast)

        await MainActor.run { appState.dismissToast() }
        #expect(appState.toastState.activeToast == nil)
    }
}
