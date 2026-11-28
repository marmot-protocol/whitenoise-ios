import Foundation
import Observation

@Observable
final class ToastState {
    private(set) var activeToast: Toast?

    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?
    @ObservationIgnored private var expandedToastID: UUID?
    @ObservationIgnored private var queued: [QueuedToast] = []
    @ObservationIgnored private var activeOnSeen: (@MainActor () -> Void)?

    private struct QueuedToast {
        let toast: Toast
        let onSeen: @MainActor () -> Void
    }

    @MainActor
    func present(_ toast: Toast) {
        if let active = activeToast, let onSeen = activeOnSeen {
            queued.insert(QueuedToast(toast: active, onSeen: onSeen), at: 0)
        }
        show(toast, onSeen: nil)
    }

    /// Shows `toast` once nothing else is on screen and calls `onSeen` only
    /// after it stayed up until it timed out or the user dismissed it; a toast
    /// that replaces it first sends it back to the front of the queue.
    @MainActor
    func enqueue(_ toast: Toast, onSeen: @escaping @MainActor () -> Void) {
        queued.append(QueuedToast(toast: toast, onSeen: onSeen))
        if activeToast == nil { showNext() }
    }

    @MainActor
    private func show(_ toast: Toast, onSeen: (@MainActor () -> Void)?) {
        toastDismissTask?.cancel()
        activeToast = toast
        activeOnSeen = onSeen
        expandedToastID = nil
        scheduleDismissal(for: toast)
    }

    @MainActor
    private func showNext() {
        guard !queued.isEmpty else { return }
        let next = queued.removeFirst()
        show(next.toast, onSeen: next.onSeen)
    }

    @MainActor
    private func finishActive() {
        let onSeen = activeOnSeen
        activeOnSeen = nil
        expandedToastID = nil
        activeToast = nil
        onSeen?()
        if activeToast == nil { showNext() }
    }

    @MainActor
    func setExpanded(_ isExpanded: Bool, for toastID: UUID) {
        guard activeToast?.id == toastID else { return }
        expandedToastID = isExpanded ? toastID : nil
        toastDismissTask?.cancel()
        if !isExpanded, let activeToast {
            scheduleDismissal(for: activeToast)
        }
    }

    @MainActor
    private func scheduleDismissal(for toast: Toast) {
        let id = toast.id
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.sleepNanoseconds(forDuration: toast.duration))
            await MainActor.run {
                guard !Task.isCancelled,
                      let self,
                      self.activeToast?.id == id else { return }
                self.finishActive()
            }
        }
    }

    @MainActor
    func dismiss() {
        toastDismissTask?.cancel()
        finishActive()
    }

    deinit {
        toastDismissTask?.cancel()
    }

    static func sleepNanoseconds(forDuration duration: TimeInterval) -> UInt64 {
        guard !duration.isNaN, duration > 0 else { return 0 }
        guard duration.isFinite else { return UInt64.max }
        let nanoseconds = duration * 1_000_000_000
        guard nanoseconds.isFinite,
              nanoseconds < TimeInterval(UInt64.max)
        else { return UInt64.max }
        return UInt64(nanoseconds)
    }
}
