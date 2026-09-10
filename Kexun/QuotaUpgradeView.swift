import SwiftUI

struct QuotaUpgradeView: View {
    @ObservedObject var store: CollectionStore
    @State private var showingPurchase = false
    var body: some View {
        if store.quotaExceeded {
            VStack(alignment: .leading, spacing: 12) {
                Text("当前有 \(store.records.filter { $0.deletedAt == nil }.count) 条收藏，免费版最多 100 条。可减少本次选择、删除不需要的内容，或升级 Pro。")
                Button("升级可寻 Pro") { showingPurchase = true }
                Button("暂时不用") { store.error = nil; store.quotaExceeded = false }
                Text("已有资料仍可查看、搜索、编辑和导出。升级后请重新提交，本次内容不会自动保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .sheet(isPresented: $showingPurchase) { ProPurchaseView() }
        }
    }
}

private struct ProPurchaseView: View {
    @StateObject private var purchase = PurchaseService()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Text(purchase.isPro ? String(localized: "已永久解锁收藏数量限制") : String(localized: "一次购买，永久解锁收藏数量限制。所有核心功能免费版均可使用。"))
                if !purchase.isPro {
                    Button(purchase.displayPrice.map { String(localized: "升级 Pro · \($0)") } ?? String(localized: "加载商品")) {
                        Task { if purchase.product == nil { await purchase.load() } else { await purchase.purchase() } }
                    }.disabled(purchase.busy)
                }
                Button("恢复购买") { Task { await purchase.restore() } }.disabled(purchase.busy)
                if let message = purchase.message { Text(message) }
                Text("恢复购买不恢复收藏资料。永久版不包含未来另行收费的云服务或 AI 服务。本地容量仍受设备空间与导入上限约束。")
                    .font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("可寻 Pro · 永久版")
                .toolbar { Button("完成") { dismiss() } }
        }.task { await purchase.load() }
    }
}
