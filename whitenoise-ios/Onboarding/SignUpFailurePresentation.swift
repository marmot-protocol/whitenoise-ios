@MainActor
struct SignUpFailurePresentation {
    private var observedFailure: CreateIdentityViewModel.Failure?
    init(retaining failure: CreateIdentityViewModel.Failure? = nil) {
        observedFailure = failure
    }

    mutating func takeNewFailure(_ failure: CreateIdentityViewModel.Failure?) -> CreateIdentityViewModel.Failure? {
        defer { observedFailure = failure }
        return failure != observedFailure ? failure : nil
    }
}
