import SwiftUI

nonisolated struct MessageLinkCopyAction: Sendable {
    let perform: @MainActor @Sendable (MessageLinkTarget) -> Void

    @MainActor
    func callAsFunction(_ target: MessageLinkTarget) {
        perform(target)
    }

    @MainActor
    static func copy(_ target: MessageLinkTarget, presenting appState: AppState) {
        SensitiveClipboard.copyLocalOnly(target.copyText)
        Haptics.tap()
        appState.present(.success(L10n.string("Copied")))
    }
}

extension EnvironmentValues {
    @Entry var copyMessageLink: MessageLinkCopyAction? = nil
}

extension View {
    func messageLinkCopyAccessibilityActions(for blocks: [MarkdownDisplayBlock]?, appState: AppState) -> some View {
        messageLinkCopyAccessibilityActions(
            MessageLinkCopyAccessibilityAction.actions(in: blocks),
            appState: appState
        )
    }

    func messageLinkCopyAccessibilityActions(
        _ actions: [MessageLinkCopyAccessibilityAction],
        appState: AppState
    ) -> some View {
        accessibilityActions {
            ForEach(actions.indices, id: \.self) { index in
                Button(actions[index].title) {
                    MessageLinkCopyAction.copy(actions[index].target, presenting: appState)
                }
            }
        }
    }
}
