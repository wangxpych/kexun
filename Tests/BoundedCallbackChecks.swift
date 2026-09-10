import Foundation

final class CallbackProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Result<Int, Error>) -> Void)?
    private var discarded: [Int] = []
    func install(_ callback: @escaping @Sendable (Result<Int, Error>) -> Void) {
        lock.lock(); self.callback = callback; lock.unlock()
    }
    func send(_ value: Int) {
        lock.lock(); let callback = callback; lock.unlock()
        callback?(.success(value))
    }
    func discard(_ value: Int) { lock.lock(); discarded.append(value); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return discarded }
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return callback != nil }
}

@main struct BoundedCallbackChecks {
    static func main() async throws {
        let direct: Int = try await BoundedCallback.wait(seconds: 0.05) { $0(.success(7)) }
        precondition(direct == 7)
        let timeout = CallbackProbe()
        do {
            let _: Int = try await BoundedCallback.wait(seconds: 0.03, discard: { timeout.discard($0) }, start: timeout.install)
            fatalError("A silent source must time out")
        } catch is CallbackTimeout { }
        timeout.send(8)
        precondition(timeout.values == [8], "Late resources must be discarded")

        let cancelled = CallbackProbe()
        let task = Task {
            try await BoundedCallback<Int>.wait(seconds: 10, discard: { cancelled.discard($0) }, start: cancelled.install)
        }
        while !cancelled.ready { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; fatalError("Cancellation must release the waiter") }
        catch is CancellationError { }
        cancelled.send(9)
        precondition(cancelled.values == [9])

        let duplicate = CallbackProbe()
        let once: Int = try await BoundedCallback.wait(seconds: 0.05, discard: { duplicate.discard($0) }) { completion in
            completion(.success(1)); completion(.success(2))
        }
        precondition(once == 1 && duplicate.values == [2])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kexun-late-callback-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("late-copy")
        do {
            let _: URL = try await BoundedCallback.wait(seconds: 0.01, discard: { try? FileManager.default.removeItem(at: $0) }) { completion in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) {
                    do {
                        try Data("late attachment".utf8).write(to: file)
                        completion(.success(file))
                    } catch { completion(.failure(error)) }
                }
            }
            fatalError("Late file must not be accepted")
        } catch is CallbackTimeout { }
        try await Task.sleep(for: .milliseconds(100))
        precondition(!FileManager.default.fileExists(atPath: file.path), "Late file must be removed")

        for _ in 0..<100 {
            let race = Task {
                try await BoundedCallback<Int>.wait(seconds: 0.001) { completion in
                    DispatchQueue.global().async { completion(.success(1)) }
                }
            }
            race.cancel()
            do { _ = try await race.value } catch is CancellationError { } catch is CallbackTimeout { }
        }
        print("PASS: success, timeout, late cleanup, cancellation, duplicate callback, cancellation races")
    }
}
