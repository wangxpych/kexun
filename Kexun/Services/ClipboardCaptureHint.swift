import Combine
import UIKit

/// A content-free hint. Only an explicit system paste action may provide text.
@MainActor
final class ClipboardCaptureHint: ObservableObject {
    @Published private(set) var isAvailable = false

    private let changeCount: @MainActor () -> Int
    private let detectProbableWebURL: @MainActor () async throws -> Bool
    private var dismissedChangeCount: Int?
    private var availableChangeCount: Int?
    private var revision: UInt = 0

    convenience init() {
        self.init(
            changeCount: { UIPasteboard.general.changeCount },
            detectProbableWebURL: {
                try await withCheckedThrowingContinuation { continuation in
                    UIPasteboard.general.detectPatterns(for: [\.probableWebURL]) { result in
                        continuation.resume(with: result.map { $0.contains(\.probableWebURL) })
                    }
                }
            }
        )
    }

    /// Dependencies expose only a change counter and a detection result, never content.
    init(
        changeCount: @escaping @MainActor () -> Int,
        detectProbableWebURL: @escaping @MainActor () async throws -> Bool
    ) {
        self.changeCount = changeCount
        self.detectProbableWebURL = detectProbableWebURL
    }

    func refresh() async {
        revision &+= 1
        let requestedRevision = revision
        let requestedChangeCount = changeCount()
        isAvailable = false
        availableChangeCount = nil
        guard !Task.isCancelled, requestedChangeCount != dismissedChangeCount else { return }

        do {
            let detected = try await detectProbableWebURL()
            guard requestedRevision == revision,
                  !Task.isCancelled,
                  requestedChangeCount == changeCount(),
                  requestedChangeCount != dismissedChangeCount else { return }
            availableChangeCount = detected ? requestedChangeCount : nil
            isAvailable = detected
        } catch {
            // An unavailable detector is not a reason to read clipboard contents.
            guard requestedRevision == revision else { return }
            isAvailable = false
            availableChangeCount = nil
        }
    }

    func dismiss() {
        // Dismiss the hint that was shown, even if another app has since copied text.
        dismissedChangeCount = availableChangeCount ?? changeCount()
        invalidate()
    }

    /// Call when the library becomes busy or the scene is no longer active.
    func invalidate() {
        revision &+= 1
        isAvailable = false
        availableChangeCount = nil
    }
}
