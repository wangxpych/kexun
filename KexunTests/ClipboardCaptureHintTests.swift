import Testing
@testable import Kexun

@MainActor
struct ClipboardCaptureHintTests {
    @Test func dismissalSuppressesOnlyThatClipboardChange() async {
        var count = 1
        var detections = 0
        let hint = ClipboardCaptureHint(changeCount: { count }, detectProbableWebURL: {
            detections += 1
            return true
        })
        await hint.refresh()
        #expect(hint.isAvailable)
        hint.dismiss()
        await hint.refresh()
        #expect(!hint.isAvailable)
        #expect(detections == 1)
        count = 2
        await hint.refresh()
        #expect(hint.isAvailable)
        #expect(detections == 2)
    }

    @Test func changedClipboardDuringDetectionDoesNotShowOldHint() async {
        var count = 1
        let hint = ClipboardCaptureHint(changeCount: { count }, detectProbableWebURL: {
            count = 2
            return true
        })
        await hint.refresh()
        #expect(!hint.isAvailable)
    }

    @Test func olderDetectionCannotOverrideNewerResult() async {
        let gate = DetectionGate()
        let hint = ClipboardCaptureHint(changeCount: { 1 }, detectProbableWebURL: { try await gate.detect() })
        let first = Task { await hint.refresh() }
        await gate.waitUntilStarted(1)
        let second = Task { await hint.refresh() }
        await gate.waitUntilStarted(2)
        gate.finish(1, with: .success(true))
        await second.value
        #expect(hint.isAvailable)
        gate.finish(0, with: .success(false))
        await first.value
        #expect(hint.isAvailable)
    }

    @Test func invalidationDiscardsInFlightDetection() async {
        let gate = DetectionGate()
        let hint = ClipboardCaptureHint(changeCount: { 1 }, detectProbableWebURL: { try await gate.detect() })
        let refresh = Task { await hint.refresh() }
        await gate.waitUntilStarted(1)
        hint.invalidate()
        gate.finish(0, with: .success(true))
        await refresh.value
        #expect(!hint.isAvailable)
    }

    @Test func dismissedInFlightDetectionStaysDismissed() async {
        let gate = DetectionGate()
        let hint = ClipboardCaptureHint(changeCount: { 1 }, detectProbableWebURL: { try await gate.detect() })
        let refresh = Task { await hint.refresh() }
        await gate.waitUntilStarted(1)
        hint.dismiss()
        gate.finish(0, with: .success(true))
        await refresh.value
        await hint.refresh()
        #expect(!hint.isAvailable)
        #expect(gate.started == 1)
    }

    @Test func failureAndNegativeDetectionNeverOfferHint() async {
        let failed = ClipboardCaptureHint(changeCount: { 1 }, detectProbableWebURL: { throw DetectionFailure.unavailable })
        await failed.refresh()
        #expect(!failed.isAvailable)
        let negative = ClipboardCaptureHint(changeCount: { 1 }, detectProbableWebURL: { false })
        await negative.refresh()
        #expect(!negative.isAvailable)
    }

    @Test func dismissingVisibleOldHintDoesNotSuppressNewClipboard() async {
        var count = 1
        let hint = ClipboardCaptureHint(changeCount: { count }, detectProbableWebURL: { true })
        await hint.refresh()
        count = 2
        hint.dismiss()
        await hint.refresh()
        #expect(hint.isAvailable)
    }
}

private enum DetectionFailure: Error { case unavailable }

@MainActor
private final class DetectionGate {
    private var continuations: [CheckedContinuation<Bool, any Error>] = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var started: Int { continuations.count }

    func detect() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            let ready = startWaiters.filter { $0.0 <= started }
            startWaiters.removeAll { $0.0 <= started }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitUntilStarted(_ count: Int) async {
        guard started < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func finish(_ index: Int, with result: Result<Bool, any Error>) {
        continuations[index].resume(with: result)
    }
}
