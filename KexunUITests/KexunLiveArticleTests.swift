import XCTest

/// Opt-in public-network acceptance. The source website can change; do not use as an offline CI gate.
final class KexunLiveArticleTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPublicArticleThroughActualCaptureFetchStorageAndSearch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let guide = app.buttons["关闭收集提示"]
        if guide.waitForExistence(timeout: 2) { guide.tap() }
        let marker = "LiveArticle-" + String(UUID().uuidString.prefix(8))
        let url = "https://www.swift.org/blog/announcing-swift-6/?kexun-check=" + marker
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        let title = app.textFields["标题（选填）"]
        reveal(title, in: app)
        title.tap(); title.typeText(marker)
        dismissKeyboard(in: app)
        let body = app.textViews["收藏内容"]
        reveal(body, in: app)
        body.tap(); body.typeText(url)
        app.navigationBars["新收藏"].buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForNonExistence(timeout: 8))

        let search = app.textFields["library.search"]
        reveal(search, in: app)
        search.tap(); search.typeText(marker + "\n")
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "record.", marker)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription)
        card.tap()
        let saveArticle = app.buttons["detail.saveArticle"]
        reveal(saveArticle, in: app); saveArticle.tap()
        let preview = app.staticTexts["detail.article"]
        XCTAssertTrue(preview.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(preview.label.contains("Swift"), preview.label)
        let read = app.buttons["detail.readArticle"]
        reveal(read, in: app); read.tap()
        let text = app.staticTexts["articleReader.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(text.label.contains("Data-race safety"))
        let captured = XCTAttachment(screenshot: app.screenshot())
        captured.name = "Live public Swift article saved and opened in local text reader"
        captured.lifetime = .keepAlways
        add(captured)
        app.navigationBars["已保存的网页正文"].buttons.firstMatch.tap()
        app.navigationBars["收藏详情"].buttons["关闭"].tap()

        search.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: marker.count + 8))
        search.typeText(marker + " Data-race safety\n")
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(card.exists)
        card.tap()
        let originalURL = app.staticTexts[url].firstMatch
        reveal(originalURL, in: app)
        XCTAssertTrue(originalURL.exists, "The original submitted URL must remain separate from the captured source URL")
    }

    @MainActor
    private func dismissKeyboard(in app: XCUIApplication) {
        let dismiss = app.buttons["keyboard.dismiss"].firstMatch
        if dismiss.exists && dismiss.isHittable { dismiss.tap() }
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        dismissKeyboard(in: app)
        for up in [true, false] {
            for _ in 0..<12 {
                if element.exists && element.isHittable { return }
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: up ? 0.80 : 0.28))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: up ? 0.28 : 0.80))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
        XCTFail("Required control is not visible: \(element)\n\(app.debugDescription)")
    }
}
