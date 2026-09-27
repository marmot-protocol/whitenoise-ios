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
        let failed = await model.publish(accountIdHex: "account") { _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(!failed)
        #expect(model.saveError != nil)
        #expect(model.error == nil)
        #expect(model.displayName == "Edited name")
        #expect(model.about == "Unsaved about text")
        #expect(!model.isPublishing)

        let saved = await model.publish(accountIdHex: "account") { metadata in
            #expect(metadata.displayName == "Edited name")
            #expect(metadata.about == "Unsaved about text")
        }
        #expect(saved)
        #expect(model.saveError == nil)
    }

    @Test func invalidOrUnloadedDraftCannotReportSaveSuccess() async {
        let model = loadedModel()
        model.nip05 = "invalid address"
        let invalid = await model.publish(accountIdHex: "account") { _ in
            Issue.record("Invalid draft was published")
        }
        #expect(!invalid)
        model.nip05 = ""
        let wrongAccount = await model.publish(accountIdHex: "other") { _ in
            Issue.record("Draft was published to another account")
        }
        #expect(!wrongAccount)
    }

    @Test func duplicateSaveAndStaleCompletionCannotExitEditing() async {
        let model = loadedModel()
        let saved = await model.publish(accountIdHex: "account") { _ in
            let duplicate = await model.publish(accountIdHex: "account") { _ in
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
