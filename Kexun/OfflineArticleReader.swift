import SwiftUI

/// An inert local text reader: opening it never reloads the source website.
struct OfflineArticleReader: View {
    let article: SavedWebArticle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("保存于 \(article.capturedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                Text(article.sourceURL).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(article.text).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled).accessibilityIdentifier("articleReader.text")
            }.padding()
        }.navigationTitle("已保存的网页正文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("复制正文") { UIPasteboard.general.string = article.text }
            }
    }
}
