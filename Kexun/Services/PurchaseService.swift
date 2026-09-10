import Combine
import Foundation
import StoreKit

/// The cache is written only after StoreKit verification and is never part of backups.
/// It lets the share extension enforce the same limit without presenting a purchase UI.
@MainActor
final class PurchaseService: ObservableObject {
    nonisolated static let productID = "com.wangxp.Kexun.pro.lifetime"
    nonisolated static let appGroupID = "group.com.wangxp.Kexun"
    nonisolated static let entitlementKey = "kexun.pro.verified"

    nonisolated static var cachedIsPro: Bool {
        UserDefaults(suiteName: appGroupID)?.bool(forKey: entitlementKey) ?? false
    }

    @Published private(set) var isPro: Bool
    @Published private(set) var product: Product?
    @Published private(set) var busy = false
    @Published var message: String?

    var displayPrice: String? { product?.displayPrice }
    private var transactionListener: Task<Void, Never>?

    init() {
        isPro = Self.cachedIsPro
        transactionListener = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                await self?.receive(result)
            }
        }
    }

    deinit { transactionListener?.cancel() }

    /// Call at app startup; use refresh() again when the scene becomes active.
    func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        message = nil
        await refresh()
        do {
            let products = try await Product.products(for: [Self.productID])
            product = products.first { $0.id == Self.productID && $0.type == .nonConsumable }
            if product == nil {
                message = String(localized: "暂时无法获取 Pro 商品，请稍后重试。已有权益不受影响。")
            }
        } catch {
            message = String(localized: "商品加载失败：\(error.localizedDescription)")
        }
    }

    func purchase() async {
        guard !busy else { return }
        guard let product else {
            message = String(localized: "商品尚未加载，请联网后重试。")
            return
        }
        busy = true
        message = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                let verified = await receive(result)
                if verified && isPro { message = String(localized: "已解锁 Pro，收藏数量不再受限。") }
            case .pending:
                message = String(localized: "购买正在等待确认。确认后会自动解锁，请勿重复购买。")
            case .userCancelled:
                message = String(localized: "已取消购买。")
            @unknown default:
                message = String(localized: "购买状态尚未确认，请稍后恢复购买。")
            }
        } catch StoreKitError.userCancelled {
            message = String(localized: "已取消购买。")
        } catch {
            message = String(localized: "购买未完成：\(error.localizedDescription)")
        }
    }

    /// Explicit user action only: AppStore.sync may ask for an Apple Account sign-in.
    func restore() async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            let verified = await refresh()
            if verified && isPro {
                message = String(localized: "Pro 权益已恢复。")
            } else if verified {
                message = String(localized: "此购买已撤销，已有收藏仍可查看、搜索和导出。")
            } else if message == nil && isPro {
                message = String(localized: "暂未取得新的购买验证结果，已有 Pro 权益保持不变。")
            } else if message == nil {
                message = String(localized: "未找到可恢复的 Pro 购买，请确认使用购买时的 Apple 账户。")
            }
        } catch {
            // A failed network request is not evidence of a refund.
            message = String(localized: "恢复购买失败，已有权益保持不变：\(error.localizedDescription)")
        }
    }

    /// Read the latest transaction, including revoked non-consumables. An empty
    /// currentEntitlements sequence alone cannot distinguish a refund from missing data.
    @discardableResult
    func refresh() async -> Bool {
        guard let result = await Transaction.latest(for: Self.productID) else { return false }
        return await receive(result)
    }

    @discardableResult
    // Module-internal so tests can deliver an unverified result without forging
    // a transaction or relying on Simulator-specific verification fault injection.
    func receive(_ result: VerificationResult<Transaction>) async -> Bool {
        switch result {
        case .verified(let transaction):
            guard transaction.productID == Self.productID,
                  transaction.productType == .nonConsumable else { return false }
            let active = transaction.revocationDate == nil && !transaction.isUpgraded
            isPro = active
            UserDefaults(suiteName: Self.appGroupID)?.set(active, forKey: Self.entitlementKey)
            if !active {
                message = String(localized: "Pro 购买已撤销，已有数据保留；超额时仅暂停新增和回收站恢复。")
            }
            await transaction.finish()
            return true
        case .unverified:
            // Never finish or grant an unverified purchase; StoreKit may deliver it again.
            message = String(localized: "暂时无法验证购买，已有权益保持不变，请稍后重试。")
            return false
        }
    }
}
