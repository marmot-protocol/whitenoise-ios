import SwiftUI

enum PollActionError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        L10n.string("Polls aren’t available in this conversation.")
    }
}

/// Sheet for composing a group poll. It dismisses only after MDK accepts the poll.
struct PollComposerView: View {
    let onSend: (PollDraft.Submission) async throws -> Void
    let onCancel: () -> Void

    @State private var draft = PollDraft()
    @State private var issue: PollDraft.Issue?
    @State private var sendError: String?
    @State private var isSending = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case question
        case option(Int)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.string("Ask a question"), text: $draft.question, axis: .vertical)
                        .focused($focusedField, equals: .question)
                        .lineLimit(1...4)
                } header: {
                    Text("Question")
                } footer: {
                    if let message = questionIssueMessage {
                        Text(message).foregroundStyle(.red)
                    }
                }

                Section {
                    ForEach(draft.options.indices, id: \.self) { index in
                        TextField(
                            L10n.formatted("Option %lld", Int64(index + 1)),
                            text: $draft.options[index]
                        )
                        .focused($focusedField, equals: .option(index))
                        .submitLabel(index == draft.options.count - 1 ? .done : .next)
                        .onSubmit {
                            if index + 1 < draft.options.count { focusedField = .option(index + 1) }
                        }
                    }
                    .onDelete { offsets in
                        draft.removeOptions(at: offsets)
                    }
                    .deleteDisabled(!draft.canRemoveOption)
                    if draft.canAddOption {
                        Button {
                            draft.addOption()
                            focusedField = .option(draft.options.count - 1)
                        } label: {
                            Label("Add Option", systemImage: "plus.circle")
                        }
                    }
                } header: {
                    Text("Options")
                } footer: {
                    if let message = optionsIssueMessage {
                        Text(message).foregroundStyle(.red)
                    }
                }

                Section {
                    Toggle("Allow Multiple Answers", isOn: $draft.allowsMultipleAnswers)
                    Picker("Ends", selection: $draft.duration) {
                        ForEach(PollDraft.Duration.allCases) { duration in
                            Text(title(for: duration)).tag(duration)
                        }
                    }
                } footer: {
                    if let sendError {
                        Text(sendError).foregroundStyle(.red)
                    }
                }
            }
            .disabled(isSending)
            .navigationTitle("New Poll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send", action: send)
                    }
                }
            }
            .onChange(of: draft) { issue = nil; sendError = nil }
            .onAppear { focusedField = .question }
        }
        .interactiveDismissDisabled(isSending)
    }

    private func send() {
        guard !isSending else { return }
        switch draft.validated(now: .now) {
        case .failure(let failure):
            issue = failure
        case .success(let submission):
            isSending = true
            sendError = nil
            Task { @MainActor in
                defer { isSending = false }
                do {
                    try await onSend(submission)
                } catch {
                    Haptics.error()
                    sendError = L10n.string("Couldn’t send the poll. Try again.")
                }
            }
        }
    }

    private var questionIssueMessage: String? {
        switch issue {
        case .missingQuestion: L10n.string("Enter a question.")
        case .questionTooLong: L10n.string("This question is too long.")
        default: nil
        }
    }

    private var optionsIssueMessage: String? {
        switch issue {
        case .tooFewOptions: L10n.string("Add at least two options.")
        case .optionTooLong: L10n.string("One of the options is too long.")
        case .duplicateOption: L10n.string("Each option must be different.")
        default: nil
        }
    }

    private func title(for duration: PollDraft.Duration) -> String {
        switch duration {
        case .none: L10n.string("Never")
        case .oneHour: L10n.string("1 Hour")
        case .oneDay: L10n.string("1 Day")
        case .oneWeek: L10n.string("1 Week")
        }
    }
}
