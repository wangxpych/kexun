import Foundation

/// Keep each provider attached to its own extension item's context.
nonisolated struct ShareInput {
    let provider: NSItemProvider
    let context: String

    static func load<Value: Sendable>(_ provider: NSItemProvider, type: String) async throws -> Value {
        try await BoundedCallback<Value>.wait { completion in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                if let error { completion(.failure(error)) }
                else if let value = value as? Value { completion(.success(value)) }
                else if Value.self == String.self, let text = ShareText.decodeProviderValue(value) as? Value { completion(.success(text)) }
                else if Value.self == URL.self, let data = value as? Data,
                        let url = try? NSURL.object(withItemProviderData: data, typeIdentifier: type),
                        let result = (url as URL) as? Value {
                    completion(.success(result))
                }
                else if Value.self == URL.self, let text = ShareText.decodeProviderValue(value),
                        let url = URL(string: text), url.scheme != nil, let result = url as? Value {
                    completion(.success(result))
                }
                else { completion(.failure(CollectionError.invalid(String(localized: "来源未提供有效内容。")))) }
            }
        }
    }

    static func collect(from items: [NSExtensionItem]) -> [ShareInput] {
        items.flatMap { item in
            let text = item.attributedContentText?.string ?? ""
            let attachments = item.attachments ?? []
            if !attachments.isEmpty {
                return attachments.map { ShareInput(provider: $0, context: text) }
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return [ShareInput(provider: NSItemProvider(object: text as NSString), context: text)]
        }
    }
}
