import XCTest

/// Runs only against the isolated organization fixture; never reads or writes the pasteboard.
final class KexunLibraryRefreshTests: XCTestCase {
    private let firstID = "record.00000000-0000-4000-8000-000000000126"
    private let secondID = "record.00000000-0000-4000-8000-000000000127"
    private let folderName = "分享收集验收"
    private let shareText = "手机电脑传文件，不一定要微信 手机里的视频想放到电... https://xhslink.cn/o/560xb7O8hFJ 打开【小红书】，这篇笔记超精彩！"
    private let previewTitle = "手机电脑传文件，不一定要微信 手机里的视频想放到电..."

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testDefaultListAndFolderMenuPreserveScopeThroughFiltersAndSearchCancel() throws {
        let app = launchFixture()
        // Requires a dedicated simulator with no prior layout preference.
        XCTAssertTrue(app.descendants(matching: .any)["library.list"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["tab.library"].exists)
        XCTAssertTrue(app.buttons["library.more"].exists)
        capture("library-list", app: app)
        assignFirstRecordToFolder(in: app)
        chooseFolder(in: app)
        assertFolderScope(in: app)

        app.buttons["library.filters"].tap()
        let kind = app.buttons["filter.kind"].firstMatch
        XCTAssertTrue(kind.waitForExistence(timeout: 5), app.debugDescription)
        kind.tap()
        app.buttons["文字"].firstMatch.tap()
        capture("library-filters", app: app)
        app.navigationBars["筛选"].buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["library.filterSummary"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["library.filterSummary"].label, "文字")
        assertFolderScope(in: app)

        let search = app.textFields["library.search"]
        search.tap()
        search.typeText("NO_MATCH_REFRESH_TEST")
        XCTAssertTrue(app.staticTexts["没有找到内容"].waitForExistence(timeout: 5))
        app.buttons["library.cancelSearch"].tap()
        assertFolderScope(in: app)
        XCTAssertEqual(app.staticTexts["library.filterSummary"].label, "文字")
        XCTAssertFalse(app.buttons["library.cancelSearch"].exists)

        app.buttons["library.filters"].tap()
        let reset = app.buttons["重置筛选"]
        reveal(reset, in: app)
        reset.tap()
        app.navigationBars["筛选"].buttons["完成"].tap()
        assertFolderScope(in: app)
        XCTAssertFalse(app.staticTexts["library.filterSummary"].exists)
    }

    @MainActor
    func testSettingsAndRecycleBinReturnToSelectedFolder() throws {
        let app = launchFixture()
        assignFirstRecordToFolder(in: app)
        chooseFolder(in: app)
        app.buttons["library.settings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.buttons["settings.trash"].tap()
        XCTAssertTrue(app.staticTexts["回收站为空"].waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.navigationBars["设置"].buttons["完成"].tap()
        assertFolderScope(in: app)
    }

    @MainActor
    func testPublicShareTextPreviewFolderAndUnsavedCancellation() throws {
        let app = launchFixture()
        assignFirstRecordToFolder(in: app)
        chooseFolder(in: app)
        app.buttons["library.add"].tap()
        app.buttons["capture.link"].tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForExistence(timeout: 5))
        let editor = app.textViews["收藏内容"]
        reveal(editor, in: app)
        editor.tap()
        editor.typeText(shareText)
        app.buttons["keyboard.dismiss"].firstMatch.tap()

        let preview = app.staticTexts["capture.previewTitle"]
        reveal(preview, in: app)
        XCTAssertEqual(preview.label, previewTitle)
        capture("share-preview", app: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "来源、小红书")).firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["https://xhslink.cn/o/560xb7O8hFJ"].exists)
        let folder = app.textFields["capture.folder"]
        reveal(folder, in: app)
        XCTAssertEqual(folder.value as? String, folderName)
        XCTAssertTrue(app.navigationBars["新收藏"].buttons["保存"].isEnabled)

        app.navigationBars["新收藏"].buttons["取消"].tap()
        XCTAssertTrue(app.buttons["draft.continue"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["draft.continue"].firstMatch.tap()
        reveal(editor, in: app)
        XCTAssertEqual(editor.value as? String, shareText)
        reveal(folder, in: app)
        XCTAssertEqual(folder.value as? String, folderName)
        app.navigationBars["新收藏"].buttons["取消"].tap()
        app.buttons["draft.discard"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForNonExistence(timeout: 5))
        assertFolderScope(in: app)
    }

    /// The runner must first seed only its dedicated simulator pasteboard with shareText.
    /// Keep this separate from the clipboard-independent suite above.
    @MainActor
    func testSystemPastePublicShareRequiresPreviewAndExplicitSave() throws {
        let app = launchFixture()
        let paste = app.buttons["clipboardCapturePaste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 10), "Seed the dedicated simulator with the public share sample before this test.\n\(app.debugDescription)")
        capture("clipboard-hint", app: app)
        paste.tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForExistence(timeout: 5), app.debugDescription)
        let preview = app.staticTexts["capture.previewTitle"]
        reveal(preview, in: app)
        XCTAssertEqual(preview.label, previewTitle)
        capture("share-preview", app: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "来源、小红书")).firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.navigationBars["新收藏"].buttons["保存"].isEnabled)
        app.navigationBars["新收藏"].buttons["取消"].tap()
        XCTAssertTrue(app.buttons["draft.continue"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["draft.continue"].firstMatch.tap()
        let editor = app.textViews["收藏内容"]
        reveal(editor, in: app)
        XCTAssertEqual(editor.value as? String, shareText)
        app.navigationBars["新收藏"].buttons["取消"].tap()
        app.buttons["draft.discard"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons[firstID].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["library.count"].label, "3 条收藏", "Pasting and cancelling must not create a collection")
    }

    @MainActor
    func testMainControlsAndLastRowRemainReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--organization-feature-fixture", "--organization-feature-reset", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let guide = app.buttons["关闭收集提示"]
        if guide.waitForExistence(timeout: 2) { guide.tap() }
        for name in ["library.more", "library.settings", "library.add", "quick.all"] {
            let button = app.buttons[name].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertGreaterThanOrEqual(button.frame.minX, 0)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
        }
        capture("library-accessibility", app: app)
        let last = app.buttons[firstID]
        reveal(last, in: app)
        for _ in 0..<3 where last.frame.maxY > app.buttons["library.add"].frame.minY { app.swipeUp() }
        XCTAssertTrue(last.isHittable)
        XCTAssertLessThanOrEqual(last.frame.maxY, app.buttons["library.add"].frame.minY, "The add action must not cover the last row")
        last.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSharedLinkSavePreservesBodyFolderAcrossRelaunchAndWarnsDuplicate() throws {
        let app = launchFixture()
        assignFirstRecordToFolder(in: app)
        chooseFolder(in: app)
        app.buttons["library.add"].tap()
        app.buttons["capture.link"].tap()
        let editor = app.textViews["收藏内容"]
        reveal(editor, in: app)
        editor.tap()
        editor.typeText(shareText)
        app.buttons["keyboard.dismiss"].firstMatch.tap()
        app.navigationBars["新收藏"].buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2 条收藏"].waitForExistence(timeout: 10))
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@", "record.", firstID)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        let savedID = saved.identifier
        saved.tap()
        let body = app.staticTexts["detail.body"]
        reveal(body, in: app)
        XCTAssertEqual(body.label, shareText)
        app.navigationBars["收藏详情"].buttons["关闭"].tap()
        app.terminate()
        app.launchArguments = ["--organization-feature-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        chooseFolder(in: app)
        XCTAssertTrue(app.buttons[savedID].waitForExistence(timeout: 10), "The same saved record must survive relaunch")
        app.buttons[savedID].tap()
        reveal(body, in: app)
        XCTAssertEqual(body.label, shareText)
        let folder = app.textFields["detail.folder"]
        reveal(folder, in: app)
        XCTAssertEqual(folder.value as? String, folderName)
        app.navigationBars["收藏详情"].buttons["关闭"].tap()
        app.buttons["library.add"].tap()
        app.buttons["capture.link"].tap()
        reveal(editor, in: app)
        editor.tap()
        editor.typeText(shareText)
        app.buttons["keyboard.dismiss"].firstMatch.tap()
        app.navigationBars["新收藏"].buttons["保存"].tap()
        XCTAssertTrue(app.buttons["查看已有收藏"].firstMatch.waitForExistence(timeout: 5), "The same copied URL must warn before creating a duplicate")
        app.buttons["查看已有收藏"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForExistence(timeout: 5))
        reveal(body, in: app)
        XCTAssertEqual(body.label, shareText)
    }

    @MainActor
    func testLayoutPreferenceSurvivesRelaunchAndSelectionCanArchive() throws {
        let app = launchFixture()
        app.buttons["library.more"].tap()
        app.buttons["卡片"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["library.grid"].firstMatch.waitForExistence(timeout: 5))
        capture("library-grid", app: app)
        app.terminate()
        app.launchArguments = ["--organization-feature-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["library.grid"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["library.more"].tap()
        app.buttons["列表"].firstMatch.tap()
        app.buttons["library.more"].tap()
        app.buttons["多选"].firstMatch.tap()
        app.buttons[firstID].tap()
        XCTAssertTrue(app.staticTexts["已选 1 条"].exists)
        app.buttons["操作"].firstMatch.tap()
        app.buttons["归档"].firstMatch.tap()
        app.buttons["取消多选"].firstMatch.tap()
        app.buttons["quick.unarchived"].tap()
        XCTAssertTrue(app.staticTexts["library.count"].waitForExistence(timeout: 5))
        XCTAssertTrue(NSPredicate(format: "label == %@", "2 条收藏").evaluate(with: app.staticTexts["library.count"]) ||
                      app.staticTexts["2 条收藏"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[firstID].exists)
        app.buttons["quick.all"].tap()
        XCTAssertTrue(app.buttons[firstID].waitForExistence(timeout: 5))
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--organization-feature-fixture", "--organization-feature-reset", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let guide = app.buttons["关闭收集提示"]
        if guide.waitForExistence(timeout: 2) { guide.tap() }
        XCTAssertTrue(app.buttons["library.add"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons[firstID].waitForExistence(timeout: 5), app.debugDescription)
        return app
    }

    @MainActor
    private func assignFirstRecordToFolder(in app: XCUIApplication) {
        app.buttons[firstID].tap()
        let folder = app.textFields["detail.folder"]
        reveal(folder, in: app)
        folder.tap()
        folder.typeText(folderName)
        app.buttons["keyboard.dismiss"].firstMatch.tap()
        app.navigationBars["收藏详情"].buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func chooseFolder(in app: XCUIApplication) {
        let menu = app.buttons["library.folders"]
        reveal(menu, in: app)
        menu.tap()
        let choice = app.buttons[folderName].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
    }

    @MainActor
    private func assertFolderScope(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons[firstID].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons[secondID].exists, "The selected folder must survive navigation and filter changes")
        XCTAssertTrue(app.buttons["library.folders"].label.contains(folderName))
        XCTAssertEqual(app.staticTexts["library.count"].label, "1 条收藏")
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeDown()
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
    }
}
