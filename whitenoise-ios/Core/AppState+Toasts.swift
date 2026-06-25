extension AppState {
    @MainActor
    func present(_ toast: Toast) {
        toastState.present(toast)
    }

    @MainActor
    func dismissToast() {
        toastState.dismiss()
    }
}
