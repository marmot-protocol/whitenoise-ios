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

    /// Two changes MDK gives up in one burst: neither replaces the other, a
    /// toast in between doesn't cost one its turn, and each is reported seen
    /// only after it was on screen until dismissed.
    @Test func backToBackQueuedToastsAreEachShownBeforeTheyCountAsSeen() {
        let state = ToastState()
        let invite = Toast.warning("Invitation not sent", duration: .infinity)
        let rename = Toast.warning("Group details not updated", duration: .infinity)
        let unrelated = Toast.success("Copied", duration: .infinity)
        var seen: [UUID] = []

        state.enqueue(invite) { seen.append(invite.id) }
        state.enqueue(rename) { seen.append(rename.id) }
        #expect(state.activeToast?.id == invite.id)
        #expect(seen.isEmpty)

        state.present(unrelated)
        #expect(seen.isEmpty)

        state.dismiss()
        #expect(state.activeToast?.id == invite.id)
        #expect(seen.isEmpty)

        state.dismiss()
        #expect(seen == [invite.id])
        #expect(state.activeToast?.id == rename.id)

        state.dismiss()
        #expect(seen == [invite.id, rename.id])
        #expect(state.activeToast == nil)
    }
}
