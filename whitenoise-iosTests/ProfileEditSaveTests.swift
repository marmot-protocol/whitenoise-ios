import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct ProfileEditSaveTests {
    private func loadedModel() -> ProfileEditViewModel {
        let model = ProfileEditViewModel()
        let ticket = model.beginLoadAttempt(accountIdHex: "account")
        model.applyLoadOutcome(.enableFirstPublish, accountIdHex: "account", profile: nil, ticket: ticket)
        model.displayName = "Edited name"
        model.about = "Unsaved about text"
        return model
    }

    @Test func failedSavePreservesDraftAndOnlySuccessfulRetryEndsEditing() async {
        let model = loadedModel()
        let failed = await model.publish(accountIdHex: "account", isCurrentAccount: { true }) { _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(!failed)
        #expect(model.saveError != nil)
        #expect(model.error == nil)
        #expect(model.displayName == "Edited name")
        #expect(model.about == "Unsaved about text")
        #expect(!model.isPublishing)

        let saved = await model.publish(accountIdHex: "account", isCurrentAccount: { true }) { metadata in
            #expect(metadata.displayName == "Edited name")
            #expect(metadata.about == "Unsaved about text")
        }
        #expect(saved)
        #expect(model.saveError == nil)
    }

    @Test func invalidOrUnloadedDraftCannotReportSaveSuccess() async {
        let model = loadedModel()
        model.nip05 = "invalid address"
        let invalid = await model.publish(accountIdHex: "account", isCurrentAccount: { true }) { _ in
            Issue.record("Invalid draft was published")
        }
        #expect(!invalid)
        model.nip05 = ""
        let wrongAccount = await model.publish(accountIdHex: "other", isCurrentAccount: { true }) { _ in
            Issue.record("Draft was published to another account")
        }
        #expect(!wrongAccount)
    }

    @Test(arguments: [false, true])
    func accountSwitchBeforeEditorReloadIgnoresSaveCompletion(fails: Bool) async {
        let model = loadedModel()
        let originalTicket = model.loadTicket
        var activeAccountID = "account"
        let saved = await model.publish(
            accountIdHex: "account",
            isCurrentAccount: { activeAccountID == "account" }
        ) { _ in
            // AppState can change before SwiftUI starts the replacement load task.
            activeAccountID = "other"
            if fails { throw URLError(.notConnectedToInternet) }
        }
        #expect(model.loadTicket == originalTicket)
        #expect(model.loadedAccountIdHex == "account")
        #expect(!saved)
        #expect(model.saveError == nil)
        #expect(model.displayName == "Edited name")
        #expect(!model.isPublishing)
    }

    @Test(arguments: [false, true])
    func stalePhotoUploadCannotReplaceAnotherAccountsPicture(reloadsEditor: Bool) async throws {
        let model = loadedModel()
        var activeAccount = "account"
        let draft = GroupImageUploadDraft(data: Data([1]), mediaType: "image/jpeg", sourceURL: nil,
                                          dim: nil, thumbhash: nil, thumbnail: nil)
        await #expect(throws: CancellationError.self) {
            try await model.updatePicture(with: draft, accountIdHex: "account",
                                          isCurrentAccount: { activeAccount == "account" }) { _ in
                activeAccount = "other"
                if reloadsEditor { model.beginLoadAttempt(accountIdHex: "other") }
                model.picture = "https://example.com/other.jpg"
                return "https://example.com/stale.jpg"
            }
        }
        #expect(model.picture == "https://example.com/other.jpg")
        #expect(!model.isUploadingPicture)
    }

    @Test func successfulPhotoUploadUpdatesOnlyTheLoadedAccount() async throws {
        let model = loadedModel()
        let draft = GroupImageUploadDraft(data: Data([1]), mediaType: "image/jpeg", sourceURL: nil,
                                          dim: nil, thumbhash: nil, thumbnail: nil)
        try await model.updatePicture(with: draft, accountIdHex: "account", isCurrentAccount: { true }) { _ in
            "https://example.com/selected.jpg"
        }
        #expect(model.picture == "https://example.com/selected.jpg")
        #expect(!model.isUploadingPicture)
    }

    @Test func cancelEditingRestoresOnlyItsOriginalAccountAndLoad() {
        let model = loadedModel()
        let snapshot = ProfileEditDraftSnapshot(model: model)
        model.displayName = "New edit"
        snapshot.restore(model, activeAccountID: "other")
        #expect(model.displayName == "New edit")
        snapshot.restore(model, activeAccountID: "account")
        #expect(model.displayName == "Edited name")
        let ticket = model.beginLoadAttempt(accountIdHex: "account")
        model.applyLoadOutcome(.enableFirstPublish, accountIdHex: "account", profile: nil, ticket: ticket)
        model.displayName = "Fresh draft"
        snapshot.restore(model, activeAccountID: "account")
        #expect(model.displayName == "Fresh draft")
    }

    @Test func duplicateSaveAndStaleCompletionCannotExitEditing() async {
        let model = loadedModel()
        let saved = await model.publish(accountIdHex: "account", isCurrentAccount: { true }) { _ in
            let duplicate = await model.publish(accountIdHex: "account", isCurrentAccount: { true }) { _ in
                Issue.record("Duplicate publication")
            }
            #expect(!duplicate)
            model.beginLoadAttempt(accountIdHex: "other")
            model.displayName = "Other account draft"
        }
        #expect(!saved)
        #expect(model.displayName == "Other account draft")
        #expect(model.saveError == nil)
    }
}
