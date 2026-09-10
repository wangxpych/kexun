import XCTest

final class KexunBackgroundEditTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testRealOCRFinishesWhileNoteDraftIsOpenAndSaveMergesBoth() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--extraction-search-fixture", "--extraction-delayed-release",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) {
            app.buttons["关闭收集提示"].tap()
        }
        let release = app.buttons["fixture.releaseExtraction"]
        XCTAssertTrue(release.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(release.isEnabled, "Processing must already be persisted before starting the real-time gate")
        release.tap()

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                   "record.", "ProcessingTitle118")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        let recordIdentifier = row.identifier
        row.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForExistence(timeout: 5))
        let update = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "后台内容已有更新")).firstMatch
        XCTAssertFalse(update.exists, "The draft must open before the background version changes")
        let note = app.textViews["备注"]
        reveal(note, in: app)
        let expectedNote = "OCR合并备注-\(UUID().uuidString.prefix(8))"
        note.tap()
        note.typeText(expectedNote)
        app.buttons["keyboard.dismiss"].tap()
        XCTAssertEqual(note.value as? String, expectedNote)
        XCTAssertFalse(update.exists, "The note must be entered before actual Vision is released")
        screenshot("Unsaved note before real Vision release", app: app)

        // Scroll to the banner's section without dismissing or saving the draft.
        for _ in 0..<4 { app.swipeDown() }
        expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: update)
        waitForExpectations(timeout: 60)
        XCTAssertTrue(app.navigationBars["收藏详情"].exists, "Background completion must not dismiss the draft")
        reveal(note, in: app)
        XCTAssertEqual(note.value as? String, expectedNote, "The background revision must retain the unsaved note")
        screenshot("Background revision arrived with draft retained", app: app)
        app.navigationBars["收藏详情"].buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForNonExistence(timeout: 10), app.debugDescription)

        let saved = app.buttons[recordIdentifier]
        XCTAssertTrue(saved.waitForExistence(timeout: 5), app.debugDescription)
        saved.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForExistence(timeout: 5))
        reveal(note, in: app)
        XCTAssertEqual(note.value as? String, expectedNote)
        let actualOCR = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                                                             "可寻收藏测试", "KEXUN SEARCH 2026")).firstMatch
        reveal(actualOCR, in: app)
        XCTAssertTrue(actualOCR.exists, "Reopening must contain actual Vision output as well as the saved note")
        XCTAssertFalse(app.staticTexts["正在提取文本…"].exists)
        screenshot("Reopened record contains note and real OCR", app: app)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        if element.exists && element.isHittable { return }
        for _ in 0..<8 {
            app.swipeUp()
            if element.exists && element.isHittable { return }
        }
        for _ in 0..<12 {
            app.swipeDown()
            if element.exists && element.isHittable { return }
        }
        XCTFail("Element was not reachable: \(element)\n\(app.debugDescription)")
    }

    @MainActor
    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
