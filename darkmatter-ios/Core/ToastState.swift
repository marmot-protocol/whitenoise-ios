import Foundation
import Observation

@Observable
final class ToastState {
    private(set) var activeToast: Toast?

    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?

    @MainActor
    func present(_ toast: Toast) {
        toastDismissTask?.cancel()
        activeToast = toast
        let id = toast.id
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(toast.duration * 1_000_000_000))
            await MainActor.run {
                guard !Task.isCancelled,
                      let self,
                      self.activeToast?.id == id else { return }
                self.activeToast = nil
            }
        }
    }

    @MainActor
    func dismiss() {
        toastDismissTask?.cancel()
        activeToast = nil
    }

    deinit {
        toastDismissTask?.cancel()
    }
}
