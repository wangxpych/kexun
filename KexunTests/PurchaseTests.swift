import Foundation
import Testing
import StoreKit
import StoreKitTest
@testable import Kexun

@MainActor
struct PurchaseTests {
    @Test func verifiedLifetimePurchaseAndRefund() async throws {
        let configuration = """
        {
          "identifier": "KEXUN-LOCAL-PRO",
          "nonRenewingSubscriptions": [],
          "products": [{
            "displayPrice": "22", "familyShareable": false, "internalID": "1000001",
            "localizations": [{"description": "永久解锁收藏数量限制", "displayName": "可寻 Pro · 永久版", "locale": "zh_CN"}],
            "productID": "com.wangxp.Kexun.pro.lifetime", "referenceName": "Kexun Pro Lifetime", "type": "NonConsumable"
          }],
          "settings": {"_failTransactionsEnabled": false, "_locale": "zh_CN", "_storefront": "CHN"},
          "subscriptionGroups": [], "version": {"major": 3, "minor": 0}
        }
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KexunPro-\(UUID()).storekit")
        try Data(configuration.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        let defaults = UserDefaults(suiteName: PurchaseService.appGroupID)!
        let original = defaults.object(forKey: PurchaseService.entitlementKey)
        defaults.removeObject(forKey: PurchaseService.entitlementKey)
        defer {
            session.clearTransactions()
            session.resetToDefaultState()
            defaults.set(original, forKey: PurchaseService.entitlementKey)
        }
        let service = PurchaseService()
        await service.load()
        #expect(service.product?.id == PurchaseService.productID)
        #expect(service.isPro == false)
        try await session.setSimulatedError(.generic(.unknown), forAPI: .purchase)
        await service.purchase()
        #expect(!service.isPro && !service.busy)
        #expect(service.message?.contains("购买未完成") == true)
        try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        await service.purchase()
        #expect(!service.isPro && !service.busy)
        #expect(service.message?.contains("取消") == true)
        try await session.setSimulatedError(nil, forAPI: .purchase)
        session.askToBuyEnabled = true
        await service.purchase()
        #expect(!service.isPro && !service.busy)
        #expect(service.message?.contains("等待确认") == true)
        let pending = try #require(session.allTransactions().first { $0.productIdentifier == PurchaseService.productID && $0.pendingAskToBuyConfirmation })
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        for _ in 0..<50 {
            await service.refresh()
            if service.isPro { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(service.isPro, "\(service.message ?? "no purchase message")")
        #expect(PurchaseService.cachedIsPro)
        let recreated = PurchaseService()
        #expect(recreated.isPro)
        defaults.removeObject(forKey: PurchaseService.entitlementKey)
        let restored = PurchaseService()
        #expect(!restored.isPro)
        await restored.restore()
        #expect(restored.isPro, "\(restored.message ?? "no restore message")")
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .appStoreSync)
        await restored.restore()
        #expect(restored.isPro && PurchaseService.cachedIsPro && !restored.busy)
        #expect(restored.message?.contains("恢复购买失败") == true)
        try await session.setSimulatedError(nil, forAPI: .appStoreSync)
        let dataRoot = FileManager.default.temporaryDirectory.appendingPathComponent("KexunPurchaseQuota-\(UUID())")
        let repository = try CollectionRepository(url: dataRoot.appendingPathComponent("source/collections.sqlite"))
        let assets = try AttachmentStore(root: dataRoot.appendingPathComponent("source"))
        let retained = (0..<101).map { CollectionRecord(kind: .text, title: "退款保留\($0)", body: "仍可搜索") }
        try repository.insert(retained, isPro: PurchaseService.cachedIsPro)
        let trashed = CollectionRecord(kind: .text, title: "待恢复")
        try repository.insert([trashed], isPro: PurchaseService.cachedIsPro)
        try repository.batch(ids: [trashed.id], action: .trash)
        let result = try #require(await Transaction.latest(for: PurchaseService.productID))
        guard case .verified(let transaction) = result else {
            Issue.record("StoreKit returned an unverified test transaction")
            return
        }
        try session.refundTransaction(identifier: UInt(transaction.id))
        // StoreKitTest submits the refund before Transaction.latest/updates necessarily
        // exposes the revocation. Wait for the verified state, never mutate the cache.
        for _ in 0..<50 {
            await service.refresh()
            if !service.isPro { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(service.isPro == false)
        #expect(PurchaseService.cachedIsPro == false)
        #expect(try repository.all().filter { $0.deletedAt == nil }.count == 101)
        do {
            try repository.insert([CollectionRecord(kind: .text, title: "不应新增")], isPro: PurchaseService.cachedIsPro)
            Issue.record("Refunded entitlement permitted an over-quota addition")
        } catch CollectionError.limit { }
        do {
            try repository.restore(ids: [trashed.id], isPro: PurchaseService.cachedIsPro)
            Issue.record("Refunded entitlement permitted an over-quota trash restore")
        } catch CollectionError.limit { }
        try repository.update(id: retained[0].id) { $0.note = "退款后仍可编辑" }
        #expect(try repository.search(CollectionQuery(text: "退款后仍可编辑")).count == 1)
        let backup = try BackupArchive.exportFile(repository: repository, assets: assets)
        defer { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }
        let recovered = try CollectionRepository(url: dataRoot.appendingPathComponent("recovered/collections.sqlite"))
        let recoveredAssets = try AttachmentStore(root: dataRoot.appendingPathComponent("recovered"))
        #expect(try BackupArchive.restoreFile(backup, repository: recovered, assets: recoveredAssets) == 102)
        #expect(!PurchaseService.cachedIsPro)

        // Use the actual pre-refund transaction with an explicit unverified wrapper.
        // This checks the service boundary, not Apple's signature verifier itself.
        #expect(await service.receive(.unverified(transaction, .invalidSignature)) == false)
        #expect(!service.isPro && !PurchaseService.cachedIsPro)
        #expect(service.message?.contains("无法验证购买") == true)
    }
}
