import SwiftUI

/// A real compact row; links without a fetched cover never reserve an empty image area.
struct LibraryRecordTile: View {
    let record: CollectionRecord
    @ObservedObject var store: CollectionStore
    let compact: Bool
    let snippet: String?
    let selected: Bool?

    private var thumbnailURL: URL? {
        guard record.kind == .image || record.kind == .link,
              let reference = record.attachments.first else { return nil }
        return try? store.attachments?.url(for: reference)
    }
    private var summary: String {
        if let snippet, !snippet.isEmpty { return snippet }
        if !record.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return record.note }
        // A link's copied promotional text is retained in details, not repeated under its title.
        return record.kind == .link ? "" : record.body
    }
    private var textContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(record.title).font(.headline).lineLimit(2)
                if record.starred { Image(systemName: "star.fill").font(.caption).foregroundStyle(Color(uiColor: KexunPalette.accent)).accessibilityLabel("星标") }
            }
            if !summary.isEmpty { Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    sourceLabel
                    Text("·").accessibilityHidden(true)
                    Text(record.createdAt, format: .dateTime.month().day())
                }
                sourceLabel
            }.font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var sourceLabel: some View {
        Label(LinkSource.displayName(for: record.source), systemImage: record.kind.symbol)
            .lineLimit(1).accessibilityLabel("\(record.kind.title)，\(LinkSource.displayName(for: record.source))")
    }
    var body: some View {
        Group {
            if compact {
                HStack(alignment: .center, spacing: 12) {
                    if let selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Color(uiColor: KexunPalette.accent))
                            .accessibilityLabel(selected ? String(localized: "已选择") : String(localized: "未选择"))
                    }
                    textContent
                    if let url = thumbnailURL {
                        AttachmentThumbnail(url: url, maximumPixelSize: 180)
                            .frame(width: 56, height: 56).clipped()
                            .background(Color(uiColor: KexunPalette.page), in: RoundedRectangle(cornerRadius: 8))
                            .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if let url = thumbnailURL {
                        AttachmentThumbnail(url: url).frame(maxWidth: .infinity).frame(height: 110).clipped()
                            .accessibilityHidden(true)
                    }
                    if let selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .accessibilityLabel(selected ? String(localized: "已选择") : String(localized: "未选择"))
                    }
                    textContent
                }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.035), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}
