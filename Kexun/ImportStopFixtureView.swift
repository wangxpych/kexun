#if DEBUG
import SwiftUI

/// Uses real system file selection, copying, storage and cancellation handling.
/// Only the pause before the second item is controlled; not a slow-provider test.
struct ImportStopFixtureView: View {
    @State private var store: CollectionStore?
    @State private var error: String?
    var body: some View {
        Group {
            if let store { LibraryView(store: store) }
            else if let error { Text(error) }
            else { ProgressView("Import stop fixture preparing") }
        }.task {
            guard store == nil, error == nil else { return }
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunImportStopFixture-\(UUID())")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                let value = CollectionStore(openRoot: { root })
                value.beforeImportItem = { index in
                    if index == 1 { try await Task.sleep(for: .seconds(30)) }
                }
                store = value
            } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
