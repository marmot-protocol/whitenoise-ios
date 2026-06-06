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
            try? await Task.sleep(nanoseconds: Self.sleepNanoseconds(forDuration: toast.duration))
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

    static func sleepNanoseconds(forDuration duration: TimeInterval) -> UInt64 {
        guard !duration.isNaN, duration > 0 else { return 0 }
        guard duration.isFinite else { return UInt64.max }
        let maximumSeconds = TimeInterval(UInt64.max) / 1_000_000_000
        return UInt64(min(duration, maximumSeconds) * 1_000_000_000)
    }
}
