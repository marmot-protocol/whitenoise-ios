import MarmotKit

/// MDK operations used by the device-link presentation store. Keeping the calls
/// together lets the store own scope, ordering and presentation independently of
/// the runtime's transport and storage.
nonisolated struct DeviceLinkCalls {
    var linkedDevices: @MainActor (Marmot, String) async throws -> [LinkedDeviceFfi] = {
        try await $0.linkedDevices(accountRef: $1)
    }
    var chatsClosed: @MainActor (Marmot, String) async throws -> UInt32 = {
        try await $0.chatsClosedToLinkedDevices(accountRef: $1)
    }
    var leftoverChats: @MainActor (Marmot, String) async throws -> UInt32 = {
        try await $0.removedDeviceLeftoverChats(accountRef: $1)
    }
    var startedFresh: @MainActor (Marmot, String) async throws -> Bool = {
        try await $0.startedFresh(accountRef: $1)
    }
    var signIns: @MainActor (Marmot, String) async throws -> [UnrecognizedSignInFfi] = {
        try await $0.unrecognizedSignIns(accountRef: $1)
    }
    var compromiseWarning: @MainActor (Marmot, String) async throws -> [CompromiseWarningItemFfi] = {
        try await $0.compromiseWarning(accountRef: $1)
    }
    var keyPackageOverdue: @MainActor (Marmot, String) async throws -> Bool = {
        try await $0.keyPackageRefreshOverdue(accountRef: $1)
    }
    var historyImports: @MainActor (Marmot, String) async throws -> [ChatHistoryImportFfi] = {
        try await $0.chatHistoryImports(accountRef: $1)
    }
    var startLink: @MainActor (Marmot, String) async throws -> DeviceLinkSnapshotFfi = {
        try await $0.startDeviceLink(accountRef: $1)
    }
    var rotateKeyPackage: @MainActor (Marmot, String) async throws -> Void = {
        _ = try await $0.rotateKeyPackage(accountRef: $1)
    }
    var link: @MainActor (Marmot, String, String, String, Bool, Bool) async throws -> DeviceLinkSnapshotFfi = {
        try await $0.linkDevice(accountRef: $1, promptId: $2, label: $3, addToAllChats: $4, bringHistory: $5)
    }
    var rename: @MainActor (Marmot, String, String, String) async throws -> Void = {
        try await $0.renameLinkedDevice(accountRef: $1, slotIdHex: $2, label: $3)
    }
    var activateAccount: @MainActor (AppState, String) async -> Void = {
        await $0.activateAccount($1)
    }
}
