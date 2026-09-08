import Foundation
import marmot_uniffiFFI

/// UniFFI 0.29's generated Swift async bridge does not forward Task cancellation.
/// Use the release's native future cancellation so a replaced list handle can drop.
public extension PresentedChatListSubscription {
    func nextCancellable() async throws -> PresentedChatListUpdateFfi? {
        try Task.checkCancellation()
        let future = PresentedListNativeFuture(
            uniffi_marmot_uniffi_fn_method_presentedchatlistsubscription_next(uniffiClonePointer())
        )
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
                let value: PresentedChatListUpdateFfi?
                switch reader.data[0] {
                case 0: value = nil
                case 1: value = try FfiConverterTypePresentedChatListUpdateFfi.read(from: &reader)
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
}

private enum PresentedListBridgeError: Error { case invalidResponse }

private final class PresentedListPoll {
    let continuation: CheckedContinuation<Int8, Never>
    init(_ continuation: CheckedContinuation<Int8, Never>) { self.continuation = continuation }
}

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
