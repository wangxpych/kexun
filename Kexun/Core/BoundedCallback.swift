import Foundation

/// Bridges an untrusted callback without waiting forever or resuming twice.
/// The lock protects all mutable state, including cancellation before installation.
nonisolated final class BoundedCallback<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    private func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    @discardableResult
    private func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return false }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }

    static func wait(
        seconds: TimeInterval = 30,
        discard: @escaping @Sendable (Value) -> Void = { _ in },
        isolation: isolated (any Actor)? = #isolation,
        start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        let gate = BoundedCallback<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                let timeout = Task { [weak gate] in
                    do { try await Task.sleep(for: .seconds(seconds)) }
                    catch { return }
                    gate?.finish(.failure(CallbackTimeout()))
                }
                start { result in
                    timeout.cancel()
                    if !gate.finish(result), case .success(let value) = result { discard(value) }
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }
}

nonisolated struct CallbackTimeout: LocalizedError {
    var errorDescription: String? { String(localized: "来源未及时提供内容，已停止等待。请重试，或返回来源 App 下载完成后再分享。") }
}
