import XCTest

final class KexunOrganizationFeatureTests: XCTestCase {
    private let firstTextID = "record.00000000-0000-4000-8000-000000000126"
    private let secondTextID = "record.00000000-0000-4000-8000-000000000127"
    private let linkID = "record.00000000-0000-4000-8000-000000000128"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFolderDetailFilterRenameRemoveAndRelaunchPersistence() throws {
        let app = launchResetFixture()
        openRecord(firstTextID, in: app)
        let folder = app.textFields["detail.folder"]
        reveal(folder, in: app)
        folder.tap()
        folder.typeText("组织收藏夹126")
        app.buttons["keyboard.dismiss"].tap()
        app.navigationBars["收藏详情"].buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForNonExistence(timeout: 5))

        chooseFolder("组织收藏夹126", in: app)
        assertRecordVisible(firstTextID, in: app)
        XCTAssertFalse(app.buttons[secondTextID].exists)

        app.buttons["library.folders"].tap()
        app.buttons["重命名当前收藏夹"].tap()
        let name = app.alerts.textFields["收藏夹名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(in: name, with: "已重命名收藏夹126")
        app.alerts.buttons["确定"].tap()
        assertRecordVisible(firstTextID, in: app)

        relaunchFixture(app)
        chooseFolder("已重命名收藏夹126", in: app)
        assertRecordVisible(firstTextID, in: app, message: "Renamed membership must survive relaunch")
        app.buttons["library.folders"].tap()
        app.buttons["移除当前收藏夹"].tap()
        XCTAssertTrue(app.alerts["移除收藏夹？"].waitForExistence(timeout: 5), app.debugDescription)
        app.alerts.buttons["仅移除分组"].tap()
        XCTAssertTrue(app.staticTexts["当前 3 条"].waitForExistence(timeout: 10),
                      "Folder removal should finish its asynchronous all-library search before checking lazy cards.\n\(app.debugDescription)")
        assertRecordVisible(firstTextID, in: app)

        relaunchFixture(app)
        app.buttons["library.folders"].tap()
        XCTAssertFalse(app.buttons["已重命名收藏夹126"].exists, "An empty removed folder must not reappear")
        app.buttons["未分组"].tap()
        XCTAssertTrue(app.staticTexts["当前 3 条"].waitForExistence(timeout: 10), app.debugDescription)
        assertRecordVisible(firstTextID, in: app, message: "Removing a folder must retain its records")
        assertRecordVisible(secondTextID, in: app)
    }

    @MainActor
    func testSavedArticleSearchOfflineReaderAndFailedRefreshRetainsCopy() throws {
        let app = launchResetFixture()
        openRecord(linkID, in: app)
        let saveArticle = app.buttons["detail.saveArticle"]
        reveal(saveArticle, in: app)
        saveArticle.tap()
        let article = app.staticTexts["detail.article"]
        XCTAssertTrue(article.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(article.label.contains("ORGANIZATIONARTICLE126"), article.label)
        app.navigationBars["收藏详情"].buttons["关闭"].tap()

        search("ORGANIZATIONARTICLE126", in: app)
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 5), app.debugDescription)
        openRecord(linkID, in: app)
        let read = app.buttons["detail.readArticle"]
        reveal(read, in: app)
        read.tap()
        XCTAssertTrue(app.navigationBars["已保存的网页正文"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["articleReader.text"].label.contains("ORGANIZATIONARTICLE126"))
        app.navigationBars["已保存的网页正文"].buttons.firstMatch.tap()

        let refresh = app.buttons["detail.saveArticle"]
        reveal(refresh, in: app)
        XCTAssertEqual(refresh.label, "更新网页正文")
        refresh.tap()
        let retained = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "更新未完成，之前保存的正文仍保留："
        )).firstMatch
        XCTAssertTrue(retained.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["detail.article"].label.contains("ORGANIZATIONARTICLE126"))
        reveal(app.buttons["detail.readArticle"], in: app)
        app.buttons["detail.readArticle"].tap()
        XCTAssertTrue(app.staticTexts["articleReader.text"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["articleReader.text"].label.contains("ORGANIZATIONARTICLE126"))
    }

    @MainActor
    func testReadableExportAndBackupCancellationPreservesLastSuccess() throws {
        let app = launchResetFixture()
        app.buttons["library.settings"].tap()
        app.buttons["数据与备份"].tap()

        reveal(app.buttons["导出备份"], in: app)
        app.buttons["导出备份"].tap()
        saveDocument(named: "OrganizationBackup126-\(UUID().uuidString.prefix(8))", in: app)
        let success = app.staticTexts["完整备份已导出。请确认外部位置并妥善保管。"]
        XCTAssertTrue(success.waitForExistence(timeout: 15), app.debugDescription)
        let initialReceipt = backupReceiptRowLabels(in: app)
        XCTAssertTrue(initialReceipt.contains("年") && initialReceipt.contains("月") && initialReceipt.contains(":"),
                                    "The successful-backup row must expose both its title and timestamp.\n\(app.debugDescription)")

        app.navigationBars["数据与备份"].buttons.firstMatch.tap()
        app.navigationBars["设置"].buttons["完成"].tap()
        openRecord(firstTextID, in: app)
        let folder = app.textFields["detail.folder"]
        reveal(folder, in: app)
        folder.tap()
        folder.typeText("备份后变更126")
        app.buttons["keyboard.dismiss"].tap()
        app.navigationBars["收藏详情"].buttons["保存"].tap()
        app.buttons["library.settings"].tap()
        app.buttons["数据与备份"].tap()
        let changes = app.staticTexts["backup.changes"].firstMatch
        reveal(changes, in: app)
        XCTAssertTrue(changes.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(changes.label.contains("有资料变化尚未包含在上次备份中"), changes.label)

        reveal(app.buttons["导出备份"], in: app)
        app.buttons["导出备份"].tap()
        cancelDocumentPicker(in: app)
        reveal(app.staticTexts["已取消导出，未更新完整备份时间。"], in: app)
        XCTAssertTrue(app.staticTexts["已取消导出，未更新完整备份时间。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["数据与备份"].buttons.firstMatch.isEnabled)
        XCTAssertFalse(app.buttons["library.add"].isHittable, "Settings must stay presented after cancelling export")
        XCTAssertTrue(app.buttons["导出备份"].isEnabled)
        revealTowardTop(app.buttons["backup.largeAttachments"], in: app)
        XCTAssertTrue(app.buttons["backup.largeAttachments"].isEnabled)
        let receiptAfterCancellation = backupReceiptRowLabels(in: app)
        XCTAssertEqual(receiptAfterCancellation, initialReceipt,
                       "Cancellation must preserve the exact successful-backup timestamp row")
        reveal(changes, in: app)
        XCTAssertTrue(changes.label.contains("有资料变化尚未包含在上次备份中"),
                      "Cancellation must not replace the prior backup snapshot")

        let readable = app.buttons["backup.exportReadable"]
        reveal(readable, in: app)
        readable.tap()
        saveDocument(named: "OrganizationReadable126-\(UUID().uuidString.prefix(8))", in: app)
        reveal(app.staticTexts["通用资料包已导出，可解压后打开 README.md 阅读。"], in: app)
        XCTAssertTrue(app.staticTexts["通用资料包已导出，可解压后打开 README.md 阅读。"].waitForExistence(timeout: 15), app.debugDescription)
        let receiptAfterReadableExport = backupReceiptRowLabels(in: app)
        XCTAssertEqual(receiptAfterReadableExport, initialReceipt,
                       "Readable Markdown export must preserve the exact full-backup timestamp row")
        reveal(changes, in: app)
        XCTAssertTrue(changes.label.contains("有资料变化尚未包含在上次备份中"),
                      "Readable export must not replace the full-backup snapshot")
        let finalBackupState = XCTAttachment(screenshot: app.screenshot())
        finalBackupState.name = "Successful backup date and unchanged snapshot after readable export"
        finalBackupState.lifetime = .keepAlways
        add(finalBackupState)
        app.navigationBars["数据与备份"].buttons.firstMatch.tap()
        let settingsDone = app.navigationBars["设置"].buttons["完成"]
        XCTAssertTrue(settingsDone.isEnabled, "Completing export must release settings dismissal")
        settingsDone.tap()
        XCTAssertTrue(app.buttons["library.add"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library.add"].isEnabled)
        XCTAssertTrue(app.buttons["library.settings"].isEnabled)
    }

    @MainActor
    func testSelectedRecordReadableExportUsesOnlyCurrentSelectionAndReturns() throws {
        let app = launchResetFixture()
        app.buttons["library.more"].tap()
        let multiSelect = app.buttons["多选"].firstMatch
        multiSelect.tap()
        XCTAssertTrue(app.staticTexts["已选 0 条"].waitForExistence(timeout: 5), app.debugDescription)

        let selectedCard = app.buttons[linkID].firstMatch
        reveal(selectedCard, in: app)
        selectedCard.tap()
        XCTAssertTrue(app.staticTexts["已选 1 条"].waitForExistence(timeout: 5), app.debugDescription)

        let unselectedCard = app.buttons[secondTextID].firstMatch
        reveal(unselectedCard, in: app)
        XCTAssertTrue(unselectedCard.images["未选择"].firstMatch.exists,
                      "The second fixture record must remain outside the one-item export selection.\n\(app.debugDescription)")

        let actions = app.buttons["操作"].firstMatch
        reveal(actions, in: app)
        actions.tap()
        let exportSelected = app.buttons["导出所选资料"].firstMatch
        XCTAssertTrue(exportSelected.waitForExistence(timeout: 5), app.debugDescription)
        exportSelected.tap()

        XCTAssertTrue(app.navigationBars["导出资料"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["导出选中的 1 条收藏及其原始附件。"].waitForExistence(timeout: 5),
                      "The export sheet must receive only the selected record ID.\n\(app.debugDescription)")
        let chooseLocation = app.buttons["readableExport.save"].firstMatch
        reveal(chooseLocation, in: app)
        chooseLocation.tap()
        saveDocument(named: "OrganizationSelectedReadable126-\(UUID().uuidString.prefix(8))", in: app)

        XCTAssertTrue(app.staticTexts["资料包已导出，可解压后打开 README.md 阅读。"].waitForExistence(timeout: 15), app.debugDescription)
        let exported = XCTAttachment(screenshot: app.screenshot())
        exported.name = "One selected record exported through Files"
        exported.lifetime = .keepAlways
        add(exported)
        app.navigationBars["导出资料"].buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["导出资料"].waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["已选 1 条"].exists, "Returning from export must preserve the current explicit selection")
    }

    @MainActor
    func testLargeAttachmentEmptyStateReturnsAndBackupPageOpensTrash() throws {
        let app = launchResetFixture()
        app.buttons["library.settings"].firstMatch.tap()
        app.buttons["数据与备份"].firstMatch.tap()

        let largeAttachments = app.buttons["backup.largeAttachments"].firstMatch
        reveal(largeAttachments, in: app)
        largeAttachments.tap()
        XCTAssertTrue(app.navigationBars["大附件"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["暂无可读取的附件。"].waitForExistence(timeout: 10), app.debugDescription)

        app.navigationBars["大附件"].buttons["数据与备份"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["数据与备份"].waitForExistence(timeout: 5), app.debugDescription)
        let openTrash = app.buttons["打开回收站"].firstMatch
        reveal(openTrash, in: app)
        openTrash.tap()

        XCTAssertTrue(app.staticTexts["回收站"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.navigationBars.buttons["完成"].firstMatch.exists)
        XCTAssertFalse(app.buttons["library.add"].isHittable, "Recycle bin must not offer capture")
        XCTAssertTrue(app.staticTexts["回收站为空"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["数据与备份"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchResetFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--organization-feature-fixture", "--organization-feature-reset", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        dismissGuideIfNeeded(in: app)
        XCTAssertTrue(app.buttons["添加内容"].waitForExistence(timeout: 10), app.debugDescription)
        return app
    }

    @MainActor
    private func relaunchFixture(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments = ["--organization-feature-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        dismissGuideIfNeeded(in: app)
        XCTAssertTrue(app.buttons["添加内容"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func dismissGuideIfNeeded(in app: XCUIApplication) {
        let guide = app.buttons["关闭收集提示"]
        if guide.waitForExistence(timeout: 2) { guide.tap() }
    }

    @MainActor
    private func openRecord(_ identifier: String, in app: XCUIApplication) {
        let card = app.buttons[identifier].firstMatch
        reveal(card, in: app)
        XCTAssertTrue(card.isHittable, app.debugDescription)
        card.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func chooseFolder(_ name: String, in app: XCUIApplication) {
        let menu = app.buttons["library.folders"].firstMatch
        reveal(menu, in: app)
        menu.tap()
        let choice = app.buttons[name]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
    }

    @MainActor
    private func saveDocument(named name: String, in app: XCUIApplication) {
        guard let picker = waitForDocumentPicker(in: app) else { return }
        let filename = picker.filename
        replaceText(in: filename, with: name)
        picker.save.tap()
    }

    @MainActor
    private func cancelDocumentPicker(in app: XCUIApplication) {
        guard let picker = waitForDocumentPicker(in: app) else { return }
        // iOS 26 may expose the exporter's explicit Cancel as an Other element.
        let cancel = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "取消")).allElementsBoundByIndex.first { $0.isHittable }
        if let cancel { cancel.tap() }
        else {
            // Start in the title strip, not the search field inside the taller navigation bar.
            picker.bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        }
        XCTAssertTrue(picker.filename.waitForNonExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func waitForDocumentPicker(in app: XCUIApplication) ->
        (filename: XCUIElement, save: XCUIElement, bar: XCUIElement)? {
        // Match picker-owned controls, rather than an OS-private navigation-bar identifier.
        let filename = app.textFields["DOCPicker.filenameTextField"].firstMatch
        let save = app.buttons["保存"].firstMatch
        let bar = app.navigationBars.containing(.button, identifier: "保存").firstMatch
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if filename.exists, save.exists, bar.exists { return (filename, save, bar) }
            if app.state == .notRunning {
                attachDiagnostics("App exited before the system document picker appeared", app: app)
                XCTFail("Kexun exited while presenting the system document picker. This is an app crash before picker interaction, not a document-picker selector miss.")
                return nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        attachDiagnostics("System document picker controls were not exposed", app: app)
        XCTFail("System document picker did not expose its filename field, Save button, and containing navigation bar within 15 seconds; app state: \(String(describing: app.state))")
        return nil
    }

    @MainActor
    private func replaceText(in element: XCUIElement, with text: String) {
        element.tap()
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 100))
        element.typeText(text)
    }

    @MainActor
    private func search(_ query: String, in app: XCUIApplication) {
        let field = app.textFields["library.search"]
        reveal(field, in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(in: field, with: query + "\n")
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        // A hittable element can still be covered by the detail keyboard toolbar.
        let dismissKeyboard = app.buttons["keyboard.dismiss"].firstMatch
        if dismissKeyboard.exists, dismissKeyboard.isHittable {
            dismissKeyboard.tap()
        }
        if element.isHittable { return }
        for _ in 0..<10 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.78))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.28))
            start.press(forDuration: 0.05, thenDragTo: end)
            if element.isHittable { return }
        }
        for _ in 0..<20 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.28))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.78))
            start.press(forDuration: 0.05, thenDragTo: end)
            if element.isHittable { return }
        }
    }

    @MainActor
    private func assertRecordVisible(_ identifier: String, in app: XCUIApplication, message: String? = nil) {
        let card = app.buttons[identifier].firstMatch
        reveal(card, in: app)
        guard card.isHittable else {
            attachDiagnostics("Record card not visible: \(identifier)", app: app)
            XCTFail(message ?? "Expected record card to be visible after the result count settled: \(identifier)")
            return
        }
    }

    @MainActor
    private func backupReceiptRowLabels(in app: XCUIApplication) -> String {
        // LabeledContent exposes a combined accessibility label, not two child Texts.
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "上次成功导出、")).firstMatch
        revealTowardTop(title, in: app)
        guard title.waitForExistence(timeout: 5) else {
            attachDiagnostics("Successful backup receipt row not visible", app: app)
            XCTFail("The successful-backup receipt row did not become visible after scrolling to the top")
            return ""
        }
        return title.label
    }

    @MainActor
    private func revealTowardTop(_ element: XCUIElement, in app: XCUIApplication) {
        if element.exists && element.isHittable { return }
        for _ in 0..<12 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.28))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.78))
            start.press(forDuration: 0.05, thenDragTo: end)
            if element.exists && element.isHittable { return }
        }
    }

    @MainActor
    private func attachDiagnostics(_ name: String, app: XCUIApplication) {
        let hierarchy = XCTAttachment(string: "App state: \(String(describing: app.state))\n\n\(app.debugDescription)")
        hierarchy.name = name
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        if app.state != .notRunning {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = name + " screenshot"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }
}
