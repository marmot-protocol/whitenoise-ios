/// One presentation per target, including the time UIKit spends dismissing it.
nonisolated struct ChatMutePickerState {
    private enum Phase {
        case waiting, presented, dismissing, finished
    }

    private var phase = Phase.waiting

    var canUpdateAnchor: Bool { phase == .presented }

    mutating func beginPresentation() -> Bool {
        guard phase == .waiting else { return false }
        phase = .presented
        return true
    }

    mutating func beginDismissal() -> Bool {
        guard phase == .presented else { return false }
        phase = .dismissing
        return true
    }

    mutating func cancelInteractiveDismissal() {
        guard phase == .dismissing else { return }
        phase = .presented
    }

    mutating func finish() -> Bool {
        guard phase != .finished else { return false }
        phase = .finished
        return true
    }
}
