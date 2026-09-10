#if DEBUG
import SwiftUI
import Foundation

/// Controlled URLSession transport responses, not a live internet outage test.
/// The normal validator, HTTP checks, HTML parser, store and UI still execute.
struct NetworkFailureFixtureView: View {
    @State private var store: CollectionStore?
    @State private var failure: String?
    @State private var released = 0

    var body: some View {
        Group {
            if let store { LibraryView(store: store) }
            else if let failure { Text(failure) }
            else { ProgressView("Network fixture preparing") }
        }
        .environment(\.openURL, OpenURLAction { url in
            ProcessInfo.processInfo.arguments.contains("--reject-open-url") ? .discarded : .systemAction(url)
        })
        .safeAreaInset(edge: .bottom) {
            Button("Release controlled response (\(released))") {
                if NetworkFixtureProtocol.pending.release() { released += 1 }
            }.accessibilityIdentifier("fixture.releaseNetwork")
        }
        .task {
            guard store == nil, failure == nil else { return }
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunNetworkFixture-\(UUID())")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                store = CollectionStore(openRoot: { root }, fetchMetadata: { url in
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.protocolClasses = [NetworkFixtureProtocol.self]
                    return try await LinkMetadata.fetch(url, configuration: configuration)
                })
            } catch { failure = error.localizedDescription }
        }
    }
}

nonisolated private final class NetworkFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let pending = Pending()
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "example.com" && request.url?.path.hasPrefix("/KexunNetworkFixture") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.pending.set(self) }
    override func stopLoading() { Self.pending.remove(self) }

    final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var request: NetworkFixtureProtocol?
        private var count = 0
        func set(_ value: NetworkFixtureProtocol) {
            lock.lock(); defer { lock.unlock() }
            count += 1
            request = value
        }
        func remove(_ value: NetworkFixtureProtocol) {
            lock.lock(); defer { lock.unlock() }
            if request === value { request = nil }
        }
        func release() -> Bool {
            lock.lock()
            guard let current = request, let url = current.request.url else { lock.unlock(); return false }
            // The second request deliberately receives no response. Let the
            // production URLSession request timeout fire; do not inject an error.
            guard count != 2 else { lock.unlock(); return false }
            request = nil
            let attempt = count
            lock.unlock()
            let body = Data("<html><title>NETWORK SERVER TITLE</title></html>".utf8)
            let response = HTTPURLResponse(url: url, statusCode: attempt == 1 ? 503 : 200,
                                           httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            current.client?.urlProtocol(current, didReceive: response, cacheStoragePolicy: .notAllowed)
            current.client?.urlProtocol(current, didLoad: body)
            current.client?.urlProtocolDidFinishLoading(current)
            return true
        }
    }
}
#endif
