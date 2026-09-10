import XCTest

/// Run only on the dedicated test simulator (9202), never against personal data.
/// PrepareSystemFileBatch.swift must first populate the local Files provider's
/// KexunImport112 folder with Import112-good.txt and Import117-second.txt.
/// These tests use the normal dedicated library without clearing existing rows.
final class KexunInteractionReviewTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testFileImportUsesDoneAndNewSessionDoesNotRetainReports() throws {
        let app = launchApp()
        importFiles(["Import112-good", "Import117-second"], in: app)
        assertCompletedImport(count: 2, in: app)
        XCTAssertFalse(app.navigationBars["新收藏"].exists)
        XCTAssertFalse(app.buttons["保存"].exists)
        XCTAssertFalse(app.textViews["收藏内容"].exists)
        app.buttons["import.done"].tap()
        XCTAssertTrue(app.navigationBars["导入资料"].waitForNonExistence(timeout: 5))

        app.buttons["添加内容"].tap()
        XCTAssertTrue(app.navigationBars["添加内容"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["import.savedCount"].exists)
        XCTAssertFalse(app.staticTexts["import.remaining"].exists)
        XCTAssertFalse(app.staticTexts["本次未保存的原因"].exists)
        XCTAssertFalse(app.buttons["import.retry"].exists)
        app.navigationBars["添加内容"].buttons["关闭"].tap()

        // A second real import must count only this session, not the first batch.
        importFiles(["Import117-second"], in: app)
        assertCompletedImport(count: 1, in: app)
        XCTAssertFalse(app.staticTexts["本次未保存的原因"].exists)
        app.buttons["import.done"].tap()
    }

    @MainActor
    func testViewImportedBatchFromTrashKeepsNewSelection() throws {
        let app = launchApp()
        app.buttons["library.settings"].tap()
        app.buttons["settings.trash"].tap()
        XCTAssertTrue(app.staticTexts["回收站"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["library.add"].isHittable, "Capture belongs to the library, not the recycle bin")
        app.navigationBars.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.navigationBars["设置"].buttons["完成"].tap()
        XCTAssertTrue(app.buttons["library.add"].waitForExistence(timeout: 5))
        importFiles(["Import112-good", "Import117-second"], in: app)
        assertCompletedImport(count: 2, in: app)
        app.buttons["import.viewSaved"].tap()
        XCTAssertTrue(app.navigationBars["导入资料"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已选 2 条"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.images.matching(identifier: "已选择").count, 2, app.debugDescription)
    }

    @MainActor
    func testLargeAttachmentOwnerRefreshesAfterTitleEditAndTrash() throws {
        let app = launchApp()
        let originalTitle = "StorageReview-\(UUID().uuidString)"
        let updatedTitle = originalTitle + "-UPDATED"

        // View Saved opens this single newly imported record; existing records
        // with the same source filename are never edited by this test.
        importFiles(["Import112-good"], in: app)
        assertCompletedImport(count: 1, in: app)
        app.buttons["import.viewSaved"].tap()
        saveTitle(originalTitle, in: app)

        app.buttons["library.settings"].firstMatch.tap()
        app.buttons["数据与备份"].firstMatch.tap()
        let large = app.buttons["backup.largeAttachments"]
        reveal(large, in: app)
        large.tap()
        XCTAssertTrue(app.navigationBars["大附件"].waitForExistence(timeout: 5))
        let originalOwner = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "storage.record.", originalTitle)).firstMatch
        reveal(originalOwner, in: app)
        let owner = app.buttons[originalOwner.identifier]
        XCTAssertTrue(owner.label.contains(originalTitle), owner.label)
        owner.tap()
        saveTitle(updatedTitle, in: app)

        reveal(owner, in: app)
        let updated = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", updatedTitle, "当前收藏")
        expectation(for: updated, evaluatedWith: owner)
        waitForExpectations(timeout: 10)
        owner.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForExistence(timeout: 5))
        let trash = app.buttons["移入回收站"].firstMatch
        reveal(trash, in: app)
        trash.tap()
        let confirm = app.buttons["移入回收站"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForNonExistence(timeout: 5), app.debugDescription)
        reveal(owner, in: app)
        expectation(for: NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", updatedTitle, "回收站"), evaluatedWith: owner)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(owner.label.contains("当前收藏"), owner.label)
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) {
            app.buttons["关闭收集提示"].tap()
        }
        XCTAssertTrue(app.buttons["添加内容"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func importFiles(_ names: [String], in app: XCUIApplication) {
        app.buttons["添加内容"].tap()
        XCTAssertTrue(app.navigationBars["添加内容"].waitForExistence(timeout: 5))
        app.buttons["导入文件 / PDF"].tap()
        let first = app.cells.matching(NSPredicate(format: "label CONTAINS %@", names[0])).firstMatch
        let folder = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "KexunImport112")).firstMatch
        if !first.waitForExistence(timeout: 2) {
            if !folder.waitForExistence(timeout: 2) {
                if app.buttons["浏览"].exists { app.buttons["浏览"].tap() }
                let local = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "我的iPhone")).firstMatch
                if local.waitForExistence(timeout: 3) { local.tap() }
            }
            XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
            folder.tap()
        }
        for name in names {
            let file = app.cells.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            XCTAssertTrue(file.waitForExistence(timeout: 5), app.debugDescription)
            file.tap()
        }
        app.buttons["打开"].tap()
    }

    @MainActor
    private func assertCompletedImport(count: Int, in app: XCUIApplication) {
        let done = app.buttons["import.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), app.debugDescription)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: done)
        waitForExpectations(timeout: 30)
        XCTAssertEqual(app.staticTexts["import.savedCount"].label, "本次已导入 \(count) 项，已保存到资料库。")
        XCTAssertFalse(app.buttons["import.retry"].exists)
    }

    @MainActor
    private func saveTitle(_ title: String, in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForExistence(timeout: 5))
        let field = app.textFields["标题"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let previous = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(previous.count + 8, 32)))
        field.typeText(title)
        if app.buttons["keyboard.dismiss"].exists { app.buttons["keyboard.dismiss"].tap() }
        app.navigationBars["收藏详情"].buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForNonExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        func reachable() -> Bool {
            let bottomInset: CGFloat = app.navigationBars["收藏详情"].exists ? 40 : 110
            return element.exists && element.isHittable && element.frame.midY > 160
                && element.frame.midY < app.frame.maxY - bottomInset
        }
        if element.waitForExistence(timeout: 5) && reachable() { return }
        for _ in 0..<18 {
            app.swipeUp()
            if reachable() { return }
        }
        for _ in 0..<24 {
            app.swipeDown()
            if reachable() { return }
        }
        XCTFail("Element was not reachable: \(element)\n\(app.debugDescription)")
    }
}
