import Foundation

struct ProfileEditDraftSnapshot {
    private let accountID: String?
    private let loadTicket: Int
    let displayName: String
    let about: String
    let picture: String
    let nip05: String

    init(model: ProfileEditViewModel) {
        accountID = model.loadedAccountIdHex
        loadTicket = model.loadTicket
        displayName = model.displayName
        about = model.about
        picture = model.picture
        nip05 = model.nip05
    }

    func restore(_ model: ProfileEditViewModel, activeAccountID: String?) {
        guard let accountID, accountID == activeAccountID,
              model.loadedAccountIdHex == accountID, model.loadTicket == loadTicket else { return }
        model.displayName = displayName
        model.about = about
        model.picture = picture
        model.nip05 = nip05
    }
}
