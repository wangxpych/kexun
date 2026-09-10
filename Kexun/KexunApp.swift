//
//  KexunApp.swift
//  Kexun
//
//  Created by wxp on 2026/9/5.
//

import SwiftUI

@main
struct KexunApp: App {
    init() {
        // Snapshot before UI work can create new transfers; do disk removal off the main thread.
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let candidates = (try? TemporaryArtifactCleanup.candidates(in: FileManager.default.temporaryDirectory, olderThan: cutoff)) ?? []
        Task.detached(priority: .utility) {
            TemporaryArtifactCleanup.remove(candidates, olderThan: cutoff)
        }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--share-multi-link-preview") {
                ShareInputFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--library-scale-fixture") {
                LibraryScaleFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--network-failure-fixture") {
                NetworkFailureFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--import-stop-fixture") {
                ImportStopFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--extraction-search-fixture") {
                ExtractionSearchFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--organization-feature-fixture") {
                FeatureWorkflowFixtureView()
            } else {
                appContent
            }
            #else
            appContent
            #endif
        }
    }

    @ViewBuilder private var appContent: some View {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasSuffix("-preview") }) {
                ContentView()
            } else {
                LibraryView()
            }
            #else
            LibraryView()
            #endif
    }
}
