import Foundation
import marmot_uniffiFFI

// UniFFI 0.29 does not forward Swift Task cancellation to native futures.
public extension PresentedChatListSubscription {
    func nextCancellable() async throws -> PresentedChatListUpdateFfi? {
        try Task.checkCancellation()
        return try await cancellableProjectionNext(
            uniffi_marmot_uniffi_fn_method_presentedchatlistsubscription_next(uniffiClonePointer()),
            read: FfiConverterTypePresentedChatListUpdateFfi.read
        )
    }
}

public extension ChatListWindowSubscription {
    func nextCancellable() async throws -> ChatListWindowSnapshotFfi? {
        try Task.checkCancellation()
        return try await cancellableProjectionNext(
            uniffi_marmot_uniffi_fn_method_chatlistwindowsubscription_next(uniffiClonePointer()),
            read: FfiConverterTypeChatListWindowSnapshotFfi.read
        )
    }
}

public extension AccountAttentionSubscription {
    func nextCancellable() async throws -> AccountAttentionSnapshotFfi? {
        try Task.checkCancellation()
        return try await cancellableProjectionNext(
            uniffi_marmot_uniffi_fn_method_accountattentionsubscription_next(uniffiClonePointer()),
            read: FfiConverterTypeAccountAttentionSnapshotFfi.read
        )
    }
}

public extension ConversationWindowSubscription {
    func nextCancellable() async throws -> ConversationWindowSnapshotFfi? {
        try Task.checkCancellation()
        return try await cancellableProjectionNext(
            uniffi_marmot_uniffi_fn_method_conversationwindowsubscription_next(uniffiClonePointer()),
            read: FfiConverterTypeConversationWindowSnapshotFfi.read
        )
    }
}

public extension BlockListSubscription {
    func nextCancellable() async throws -> BlockListSnapshotFfi? {
        try Task.checkCancellation()
        return try await cancellableProjectionNext(
            uniffi_marmot_uniffi_fn_method_blocklistsubscription_next(uniffiClonePointer()),
            read: FfiConverterTypeBlockListSnapshotFfi.read
        )
    }
}

private func cancellableProjectionNext<Value>(
    _ handle: UInt64,
    read: (inout (data: Data, offset: Data.Index)) throws -> Value
) async throws -> Value? {
    let future = PresentedListNativeFuture(handle)
    defer { future.free() }
    return try await withTaskCancellationHandler {
        var ready: Int8 = 1
        repeat {
            ready = await withCheckedContinuation { continuation in
                let box = Unmanaged.passRetained(PresentedListPoll(continuation))
                ffi_marmot_uniffi_rust_future_poll_rust_buffer(
                    future.handle,
                    { raw, result in
                        let box = Unmanaged<PresentedListPoll>.fromOpaque(UnsafeRawPointer(bitPattern: UInt(raw))!)
                        box.takeRetainedValue().continuation.resume(returning: result)
                    },
                    UInt64(UInt(bitPattern: box.toOpaque()))
                )
            }
        } while ready != 0
        var status = RustCallStatus(code: 0, errorBuf: .init(capacity: 0, len: 0, data: nil))
        let buffer = ffi_marmot_uniffi_rust_future_complete_rust_buffer(future.handle, &status)
        defer { freePresentedListBuffer(buffer) }
        switch status.code {
        case 0:
            guard let bytes = buffer.data, buffer.len > 0 else { throw PresentedListBridgeError.invalidResponse }
            var reader = (data: Data(bytes: bytes, count: Int(buffer.len)), offset: 1)
            let value: Value?
            switch reader.data[0] {
            case 0: value = nil
            case 1: value = try read(&reader)
            default: throw PresentedListBridgeError.invalidResponse
            }
            guard reader.offset == reader.data.count else { throw PresentedListBridgeError.invalidResponse }
            try Task.checkCancellation()
            return value
        case 1:
            throw try FfiConverterTypeMarmotKitError_lift(status.errorBuf)
        case 3:
            freePresentedListBuffer(status.errorBuf)
            throw CancellationError()
        default:
            freePresentedListBuffer(status.errorBuf)
            throw PresentedListBridgeError.invalidResponse
        }
    } onCancel: {
        future.cancel()
    }
}

private enum PresentedListBridgeError: Error { case invalidResponse }

private final class PresentedListPoll {
    let continuation: CheckedContinuation<Int8, Never>
    init(_ continuation: CheckedContinuation<Int8, Never>) { self.continuation = continuation }
}

// The immutable handle is shared; the lock serializes every cancel/free access.
// swiftlint:disable:next no_unchecked_sendable
private final class PresentedListNativeFuture: @unchecked Sendable {
    let handle: UInt64
    private let lock = NSLock()
    private var freed = false
    init(_ handle: UInt64) { self.handle = handle }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if !freed { ffi_marmot_uniffi_rust_future_cancel_rust_buffer(handle) }
    }

    func free() {
        lock.lock()
        defer { lock.unlock() }
        guard !freed else { return }
        freed = true
        ffi_marmot_uniffi_rust_future_free_rust_buffer(handle)
    }
}

private func freePresentedListBuffer(_ buffer: RustBuffer) {
    guard buffer.capacity > 0 || buffer.data != nil else { return }
    var status = RustCallStatus(code: 0, errorBuf: .init(capacity: 0, len: 0, data: nil))
    ffi_marmot_uniffi_rustbuffer_free(buffer, &status)
    precondition(status.code == 0, "Unable to free UniFFI buffer")
}
