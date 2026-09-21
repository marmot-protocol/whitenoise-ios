import Foundation
import MarmotKit

extension MarmotClient {
    func sendTextWithClientToken(accountRef: String, groupIdHex: String, text: String,
                                 clientToken: String) async throws -> LocalSendAcceptanceFfi {
        try await marmot.sendTextWithClientToken(accountRef: accountRef, groupIdHex: groupIdHex,
                                                text: text, clientToken: clientToken)
    }

    func replyWithClientToken(accountRef: String, groupIdHex: String, targetMessageId: String,
                              text: String, clientToken: String) async throws -> LocalSendAcceptanceFfi {
        try await marmot.replyToMessageWithClientToken(accountRef: accountRef, groupIdHex: groupIdHex,
            targetMessageId: targetMessageId, text: text, clientToken: clientToken)
    }

    func sendDraftWithClientToken(accountRef: String, revision: MessageDraftRevisionFfi,
                                  attachments: [MediaAttachmentReferenceFfi],
                                  clientToken: String) async throws -> LocalSendAcceptanceFfi {
        try await marmot.sendMessageDraftWithClientToken(accountRef: accountRef, revision: revision,
            attachments: attachments, clientToken: clientToken)
    }

    func uploadWithClientToken(accountRef: String, groupIdHex: String, request: MediaUploadRequestFfi,
                               clientToken: String) async throws -> MediaUploadSubmissionFfi {
        try await marmot.uploadMediaWithClientToken(accountRef: accountRef, groupIdHex: groupIdHex,
            request: request, clientToken: clientToken)
    }

    func localSendStatus(accountRef: String, groupIdHex: String,
                         clientToken: String) async throws -> LocalSendStatusFfi? {
        try await Task.detached { [marmot] in
            try marmot.localSendStatus(accountRef: accountRef, groupIdHex: groupIdHex, clientToken: clientToken)
        }.value
    }
}
