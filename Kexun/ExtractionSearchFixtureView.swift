#if DEBUG
import SwiftUI
import UIKit
import Combine

/// Real PNG import and Vision extraction in an isolated store. Only scheduling
/// between the persisted processing state and Vision is controlled.
struct ExtractionSearchFixtureView: View {
    @State private var store: CollectionStore?
    @State private var failure: String?
    @StateObject private var gate = ExtractionSearchGate()

    var body: some View {
        Group {
            if let store { LibraryView(store: store) }
            else if let failure { Text(failure) }
            else { ProgressView("Extraction search fixture preparing") }
        }
        .safeAreaInset(edge: .bottom) {
            Button(gate.buttonTitle) { gate.requestRelease() }
                .disabled(!gate.waiting || gate.released || gate.releaseDeadline != nil)
                .accessibilityIdentifier("fixture.releaseExtraction")
        }
        .task {
            guard store == nil, failure == nil else { return }
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunExtractionSearchFixture-\(UUID())")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                let source = root.appendingPathComponent("ProcessingTitle118.png")
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let data = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 600), format: format).pngData { context in
                    UIColor.white.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
                    ("可寻收藏测试\nKEXUN SEARCH 2026" as NSString).draw(
                        in: CGRect(x: 70, y: 100, width: 1060, height: 400),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 68), .foregroundColor: UIColor.black])
                }
                try data.write(to: source, options: .atomic)
                defer { try? FileManager.default.removeItem(at: source) }
                let value = CollectionStore(openRoot: { root })
                value.beforeTextExtraction = { [gate] in try await gate.wait() }
                let report = await value.importFiles([source])
                guard report.saved == 1, report.failures.isEmpty else { throw CollectionError.invalid(report.message) }
                store = value
            } catch { failure = error.localizedDescription }
        }
    }
}

@MainActor private final class ExtractionSearchGate: ObservableObject {
    @Published var waiting = false
    @Published var released = false
    @Published var releaseDeadline: ContinuousClock.Instant?
    private let delayedRelease = ProcessInfo.processInfo.arguments.contains("--extraction-delayed-release")

    var buttonTitle: String {
        if released { return "OCR released" }
        if releaseDeadline != nil { return "OCR scheduled in 45 seconds" }
        return delayedRelease ? "Schedule actual OCR in 45 seconds" : "Release actual OCR"
    }

    func requestRelease() {
        if delayedRelease {
            guard releaseDeadline == nil else { return }
            releaseDeadline = ContinuousClock.now.advanced(by: .seconds(45))
        } else { released = true }
    }

    func wait() async throws {
        waiting = true
        defer { waiting = false }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !released {
            if let releaseDeadline, ContinuousClock.now >= releaseDeadline {
                released = true
                break
            }
            guard ContinuousClock.now < deadline else { throw CollectionError.invalid("Extraction fixture checkpoint timed out") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif
