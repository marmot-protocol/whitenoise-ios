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

    func uploadFilesWithClientToken(accountRef: String, groupIdHex: String, request: MediaFileUploadRequestFfi,
                                    control: MediaFileTransferControlFfi,
                                    clientToken: String) async throws -> MediaUploadSubmissionFfi {
        try await marmot.uploadMediaFilesWithClientToken(accountRef: accountRef, groupIdHex: groupIdHex,
            request: request, control: control, clientToken: clientToken)
    }

    func localSendStatus(accountRef: String, groupIdHex: String,
                         clientToken: String) async throws -> LocalSendStatusFfi? {
        try await Task.detached { [marmot] in
            try marmot.localSendStatus(accountRef: accountRef, groupIdHex: groupIdHex, clientToken: clientToken)
        }.value
    }

    func sendCustomEventWithClientToken(
        accountRef: String,
        groupIdHex: String,
        kind: UInt64,
        tags: [[String]],
        content: String,
        clientToken: String
    ) async throws -> LocalSendAcceptanceFfi {
        try await marmot.sendCustomEventWithClientToken(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            kind: kind,
            tags: tags,
            content: content,
            clientToken: clientToken
        )
    }

    func groupMessages(
        accountRef: String,
        groupIdHex: String,
        limit: UInt32? = nil,
        kinds: [UInt64]? = nil
    ) async throws -> [AppMessageRecordFfi] {
        try await Task.detached(priority: .utility) { [marmot, accountRef, groupIdHex, limit, kinds] in
            try marmot.messages(accountRef: accountRef, groupIdHex: groupIdHex, limit: limit, kinds: kinds)
        }.value
    }
}
