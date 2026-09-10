import XCTest

/// Opt-in capture on a dedicated simulator, with normal Release app behavior.
/// Sources are original, non-private files in delivery/screenshot-sources.
final class KexunStoreScreenshotTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCaptureChineseStoreScreenshots() throws {
        try XCTSkipUnless(["Kexun Store Screenshots 20260907", "Kexun iPad Store Screenshots 20260907"].contains(ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""),
                          "Only run on the dedicated store screenshot simulator")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 3) { app.buttons["关闭收集提示"].tap() }
        let count = app.staticTexts["library.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func record(_ title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "record.", title)).firstMatch
        }
        func save(_ title: String, body: String, text: Bool) {
            app.buttons["添加内容"].tap()
            app.buttons[text ? "capture.text" : "capture.link"].tap()
            app.textFields["标题（选填）"].tap()
            app.textFields["标题（选填）"].typeText(title)
            app.buttons["keyboard.dismiss"].tap()
            app.textViews["收藏内容"].tap()
            app.textViews["收藏内容"].typeText(body)
            app.navigationBars["新收藏"].buttons["保存"].tap()
            XCTAssertTrue(app.navigationBars["新收藏"].waitForNonExistence(timeout: 10))
        }
        if count.label.hasPrefix("0 ") {
            save("给周末留一点空白", body: "不赶路，去看看树影和沿途的小店。\n把想保留的片刻记下来，等需要的时候再找回。", text: true)
            save("Apple · 留意日常的设计", body: "https://www.apple.com/cn/", text: false)
        }
        if count.label.hasPrefix("2 ") {
            XCTAssertTrue(record("给周末留一点空白").exists)
            XCTAssertTrue(record("Apple · 留意日常的设计").exists)
            app.buttons["添加内容"].tap()
            app.buttons["导入文件 / PDF"].tap()
            let folder = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "可寻截图素材")).firstMatch
            if !folder.waitForExistence(timeout: 3) {
                let browse = app.buttons.matching(NSPredicate(format: "label == '浏览' OR label == 'Browse'")).firstMatch
                if browse.exists { browse.tap() }
                if !folder.waitForExistence(timeout: 3) {
                    let local = app.cells.matching(NSPredicate(format: "label CONTAINS '我的iPhone' OR label CONTAINS 'On My iPhone' OR label CONTAINS '我的iPad' OR label CONTAINS 'On My iPad'")).firstMatch
                    XCTAssertTrue(local.waitForExistence(timeout: 5), app.debugDescription)
                    local.tap()
                }
            }
            XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
            folder.tap()
            for name in ["周末散步卡片", "散步装备清单"] {
                let file = app.cells.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
                XCTAssertTrue(file.waitForExistence(timeout: 5), app.debugDescription)
                file.tap()
            }
            let open = app.buttons.matching(NSPredicate(format: "label == '打开' OR label == 'Open'")).firstMatch
            XCTAssertTrue(open.isEnabled)
            if app.frame.width > 600 {
                // The iPad remote picker can expose an ineffective AX hit point.
                // Use the center of the observed Open button frame.
                open.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else { open.tap() }
            XCTAssertTrue(app.staticTexts["本次已导入 2 项，已保存到资料库。"].waitForExistence(timeout: 15), app.debugDescription)
            app.buttons["import.done"].tap()
        }
        XCTAssertTrue(app.staticTexts["4 条收藏"].waitForExistence(timeout: 10))
        // Re-running only changes our two named sample records through normal UI.
        XCTAssertTrue(app.buttons["library.folders"].exists)
        app.buttons["quick.all"].tap()
        for name in ["周末散步卡片", "给周末留一点空白"] {
            let row = record(name)
            XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
            row.tap()
            for _ in 0..<5 where !app.buttons["移入回收站"].isHittable { app.swipeUp() }
            if app.buttons["取消归档"].exists { app.buttons["取消归档"].tap() }
            else { app.navigationBars["收藏详情"].buttons["关闭"].tap() }
        }
        app.buttons["quick.unarchived"].tap()
        capture("01-inbox")
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText("河岸\n")
        // This word exists only in the PNG pixels, not its title or note.
        XCTAssertTrue(record("周末散步卡片").waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["1 条收藏"].exists)
        capture("02-search")
        record("周末散步卡片").tap()
        XCTAssertTrue(app.buttons["预览附件"].waitForExistence(timeout: 15))
        let actualOCR = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "沿着河岸")).firstMatch
        XCTAssertTrue(actualOCR.waitForExistence(timeout: 10))
        for _ in 0..<5 where !app.buttons["预览附件"].isHittable { app.swipeUp() }
        app.buttons["预览附件"].tap()
        let previewCanvas = app.otherElements["com.apple.paper.canvasElementResizeView"]
        XCTAssertTrue(previewCanvas.waitForExistence(timeout: 10), app.debugDescription)
        capture("04-detail")
        // Quick Look hides its toolbar for images. Resume in the app without
        // relying on the PDF-specific Done accessibility identifier.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["library.folders"].waitForExistence(timeout: 10))
        app.buttons["quick.all"].tap()
        record("周末散步卡片").tap()
        for _ in 0..<5 where !app.buttons["移入回收站"].isHittable { app.swipeUp() }
        let starAction = app.buttons.matching(NSPredicate(format: "label == '星标' AND identifier != 'quick.starred'")).firstMatch
        if starAction.exists { starAction.tap() }
        else { app.navigationBars["收藏详情"].buttons["关闭"].tap() }
        record("周末散步卡片").tap()
        for _ in 0..<5 where !app.buttons["归档"].isHittable { app.swipeUp() }
        app.buttons["归档"].tap()
        if app.buttons["library.cancelSearch"].exists { app.buttons["library.cancelSearch"].tap() }
        app.buttons["library.filters"].tap()
        let archived = app.buttons["归档状态"].firstMatch
        for _ in 0..<5 where !archived.isHittable { app.swipeUp() }
        archived.tap()
        app.buttons["已归档"].firstMatch.tap()
        app.navigationBars["筛选"].buttons["完成"].tap()
        XCTAssertTrue(record("周末散步卡片").waitForExistence(timeout: 5))
        capture("03-library")
        app.buttons["library.settings"].tap()
        app.buttons["数据与备份"].tap()
        for _ in 0..<5 where !app.buttons["导出备份"].isHittable { app.swipeUp() }
        app.buttons["导出备份"].tap()
        let filename = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(filename.waitForExistence(timeout: 15), app.debugDescription)
        filename.tap()
        filename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        let backupName = "可寻备份-" + UUID().uuidString.prefix(8)
        filename.typeText(backupName)
        let exporter = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        exporter.buttons.matching(NSPredicate(format: "label == '保存' OR label == 'Save'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["备份已导出。"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["从备份恢复"].tap()
        let backup = app.cells.matching(NSPredicate(format: "label CONTAINS %@", backupName)).firstMatch
        XCTAssertTrue(backup.waitForExistence(timeout: 10), app.debugDescription)
        backup.tap()
        let restored = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "恢复完成：新增 0 条（其中冲突保留 0 条）")).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 15), app.debugDescription)
        if app.frame.width > 600 { app.swipeUp() }
        capture("05-backup")
    }
}
