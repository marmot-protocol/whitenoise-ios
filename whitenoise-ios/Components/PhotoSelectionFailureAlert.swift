import SwiftUI

extension View {
    func photoSelectionFailureAlert(
        _ failure: Binding<PhotoSelectionFailure?>,
        retry: (() -> Void)?,
        dismissTitle: LocalizedStringKey = "Close",
        chooseAnother: (() -> Void)?
    ) -> some View {
        alert(
            "Couldn’t add photo",
            isPresented: Binding(
                get: { failure.wrappedValue != nil },
                set: { if !$0 { failure.wrappedValue = nil } }
            ),
            presenting: failure.wrappedValue
        ) { presented in
            if presented.canRetry, let retry {
                Button("Retry", action: retry)
                Button(dismissTitle, role: .cancel) {}
            } else if let chooseAnother {
                Button("Choose Another Photo", action: chooseAnother)
            } else {
                Button("Choose Another Photo", role: .cancel) {}
            }
        } message: { presented in
            Text(presented.message)
        }
    }
}
