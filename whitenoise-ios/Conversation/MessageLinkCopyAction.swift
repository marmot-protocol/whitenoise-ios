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
        let targets = MessageLinkTarget.targets(in: blocks)
        let titles = MessageLinkTarget.accessibilityActionTitles(for: targets)
        return accessibilityActions {
            ForEach(targets.indices, id: \.self) { index in
                Button(titles[index]) {
                    MessageLinkCopyAction.copy(targets[index], presenting: appState)
                }
            }
        }
    }
}
