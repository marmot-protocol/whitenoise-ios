import SwiftUI

extension View {
    /// One native failure presentation; each flow supplies its existing retry action and copy.
    func wnProfileFailureAlert<Failure>(
        _ failure: Binding<Failure?>,
        title: String,
        retryEnabled: Bool = true,
        dismissTitle: @escaping (Failure) -> String = { _ in L10n.string("Close") },
        message: @escaping (Failure) -> String,
        retry: @escaping (Failure) -> Void
    ) -> some View {
        alert(title, isPresented: Binding(
            get: { failure.wrappedValue != nil },
            set: { if !$0 { failure.wrappedValue = nil } }
        ), presenting: failure.wrappedValue) { presented in
            Button("Retry") { retry(presented) }
                .disabled(!retryEnabled)
            Button(dismissTitle(presented), role: .cancel) {}
        } message: { presented in
            Text(message(presented))
        }
    }

    func profilePhotoUploadFailureAlert<Failure>(
        _ failure: Binding<Failure?>,
        retry: @escaping (Failure) -> Void
    ) -> some View {
        wnProfileFailureAlert(
            failure, title: L10n.string("Couldn’t upload photo"),
            dismissTitle: { _ in L10n.string("Cancel") },
            message: { _ in L10n.string("Couldn’t upload your photo. Please try again or choose another photo.") },
            retry: retry
        )
    }
}
