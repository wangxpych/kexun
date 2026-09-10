//
//  KexunUITests.swift
//  KexunUITests
//
//  Created by wxp on 2026/9/5.
//

import XCTest
import Vision

final class KexunUITests: XCTestCase {

    @MainActor
    private func visibleLibraryContentBottom(in app: XCUIApplication) -> CGFloat {
        let footerButtons = ["library.add", "取消多选", "全选当前结果", "操作"]
        let visibleTops = footerButtons.flatMap { identifier in
            app.buttons.matching(identifier: identifier).allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable }
                .map { $0.frame.minY }
        }
        return visibleTops.min() ?? app.frame.maxY
    }

    @MainActor
    private func chooseMore(_ app: XCUIApplication, _ action: String) {
        if app.keyboards.firstMatch.exists {
            let search = app.textFields.matching(identifier: "library.search").allElementsBoundByIndex.last
            XCTAssertNotNil(search, "The library search must own the keyboard before opening its menu")
            search?.typeText("\n")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        }
        let menus = app.buttons.matching(identifier: "library.more")
        XCTAssertTrue(menus.firstMatch.waitForExistence(timeout: 5))
        guard let menu = menus.allElementsBoundByIndex.last else { return }
        for _ in 0..<12 where !menu.isHittable { app.swipeDown() }
        XCTAssertTrue(menu.isHittable)
        menu.tap()
        XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5))
        app.buttons[action].tap()
    }

    @MainActor
    private func chooseFilter(_ app: XCUIApplication, _ picker: String, _ value: String) {
        let filter = app.buttons["library.filters"]
        for _ in 0..<12 where !filter.isHittable { app.swipeDown() }
        filter.tap()
        let identifier = ["来源": "filter.source", "保存时间": "filter.time", "归档状态": "filter.archive"][picker] ?? picker
        let control = app.buttons[identifier]
        for _ in 0..<8 where !control.isHittable { app.swipeUp() }
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        control.tap()
        app.buttons[value].tap()
        app.navigationBars["筛选"].buttons["完成"].tap()
    }

    @MainActor
    private func openTrash(_ app: XCUIApplication) {
        let settings = app.buttons["library.settings"]
        for _ in 0..<12 where !settings.isHittable { app.swipeDown() }
        settings.tap()
        app.buttons["settings.trash"].tap()
        XCTAssertTrue(app.navigationBars.buttons["完成"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func closeTrash(_ app: XCUIApplication) {
        let done = app.navigationBars.buttons.matching(identifier: "完成").allElementsBoundByIndex.last!
        done.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.navigationBars["设置"].buttons["完成"].tap()
        XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertEmptyTrashCannotBeCleared(_ app: XCUIApplication) {
        let menu = app.buttons.matching(identifier: "library.more").allElementsBoundByIndex.last!
        for _ in 0..<12 where !menu.isHittable { app.swipeDown() }
        menu.tap()
        XCTAssertTrue(app.buttons["清空回收站"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["清空回收站"].isEnabled)
        // Tap the presenting control again to dismiss its menu without selecting an action.
        menu.tap()
    }

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testTitleSearchWhileExtractionIsProcessingThenRealOCRCompletes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--extraction-search-fixture"]
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        let release = app.buttons["fixture.releaseExtraction"]
        XCTAssertTrue(release.waitForExistence(timeout: 10))
        XCTAssertTrue(release.isEnabled, "Checkpoint must be reached after processing is persisted")
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText("ProcessingTitle118\n")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "record.", "ProcessingTitle118")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        let id = row.identifier
        XCTAssertTrue(app.staticTexts["1 条收藏"].exists)
        row.tap()
        let processing = app.staticTexts["正在提取文本…"]
        for _ in 0..<4 {
            if processing.exists && processing.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(processing.exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "KEXUN SEARCH 2026")).firstMatch.exists)
        let pendingImage = XCTAttachment(screenshot: app.screenshot())
        pendingImage.name = "Title search opened real processing record before Vision"
        pendingImage.lifetime = .keepAlways
        add(pendingImage)
        app.navigationBars["收藏详情"].buttons["关闭"].tap()
        release.tap()
        XCTAssertTrue(app.buttons[id].exists)
        search.tap()
        search.typeText(" KEXUN SEARCH 2026\n")
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 30), app.debugDescription)
        app.buttons[id].tap()
        let extracted = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "可寻收藏测试", "KEXUN SEARCH 2026")).firstMatch
        for _ in 0..<4 {
            if extracted.exists && extracted.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(extracted.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(processing.exists)
        let completedImage = XCTAttachment(screenshot: app.screenshot())
        completedImage.name = "Same record after real Chinese English Vision extraction"
        completedImage.lifetime = .keepAlways
        add(completedImage)
    }

    @MainActor
    func testStopRemainingFileImportKeepsSuccessAndCanRetry() throws {
        // Two real local-provider files prepared by PrepareSystemFileBatch.swift.
        // Debug pauses only before item 2; it does not invent a provider failure.
        let app = XCUIApplication()
        app.launchArguments = ["--import-stop-fixture"]
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        func choose(_ names: [String]) {
            app.buttons["添加内容"].tap()
            app.buttons["导入文件 / PDF"].tap()
            let good = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "Import112-good")).firstMatch
            let folder = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "KexunImport112")).firstMatch
            if !good.waitForExistence(timeout: 2) {
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
        XCTAssertTrue(app.staticTexts["0 条收藏"].waitForExistence(timeout: 10))
        choose(["Import112-good", "Import117-second"])
        let stop = app.buttons["停止剩余导入"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["import.done"].isEnabled)
        stop.tap()
        let report = app.staticTexts["本次已导入 1 项，已保存到资料库。"]
        XCTAssertTrue(report.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["import.remaining"].waitForExistence(timeout: 5))
        XCTAssertFalse(stop.exists)
        XCTAssertTrue(app.buttons["import.done"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Stopped batch - one real file saved and one cancelled"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let retry = app.buttons["import.retry"]
        let pending = app.staticTexts["import.remaining"]
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        XCTAssertEqual(pending.label, "还有 1 项未保存，重试不会重复导入成功项。")
        XCTAssertTrue(retry.exists && retry.isEnabled)
        XCTAssertFalse(app.buttons["选择照片"].isEnabled)
        XCTAssertFalse(app.buttons["导入文件 / PDF"].isEnabled, "A new batch must not replace the retained queue")
        XCTAssertFalse(app.navigationBars.buttons["保存"].exists)
        app.buttons["import.done"].tap()
        let continueEditing = app.buttons["import.keepPending"].firstMatch
        XCTAssertTrue(continueEditing.waitForExistence(timeout: 5), "Leaving an unfinished retry queue must ask before discarding it")
        XCTAssertTrue(app.buttons["import.confirmDiscard"].firstMatch.exists)
        continueEditing.tap()
        XCTAssertTrue(continueEditing.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["导入资料"].exists)
        XCTAssertTrue(pending.exists && retry.exists && retry.isEnabled, "Continue editing must retain the unimported source queue")
        for _ in 0..<8 where !retry.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.78))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.28)))
        }
        XCTAssertTrue(retry.isHittable)
        retry.tap()
        // Retry the retained source directly. Do not open the system picker again.
        XCTAssertTrue(app.staticTexts["本次已导入 2 项，已保存到资料库。"].waitForExistence(timeout: 10))
        XCTAssertTrue(retry.waitForNonExistence(timeout: 10))
        XCTAssertFalse(pending.exists)
        XCTAssertFalse(app.buttons["打开"].exists, "A successful queue retry must not ask the user to pick files again")
        app.buttons["import.done"].tap()
        XCTAssertTrue(app.staticTexts["2 条收藏"].waitForExistence(timeout: 5))
        let firstMatches = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "record.", "Import112-good.txt"))
        let secondMatches = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "record.", "Import117-second.txt"))
        XCTAssertEqual(firstMatches.count, 1, "Retry must not duplicate the already saved first file")
        XCTAssertEqual(secondMatches.count, 1)
        XCTAssertNotEqual(firstMatches.firstMatch.identifier, secondMatches.firstMatch.identifier)
        for (record, expected) in [(firstMatches.firstMatch, "KEXUN_IMPORT_112 独立成功文件"),
                                   (secondMatches.firstMatch, "KEXUN_IMPORT_117 second valid file")] {
            for _ in 0..<8 where !record.isHittable {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.78))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.28)))
            }
            record.tap()
            let preview = app.buttons["预览附件"]
            for _ in 0..<12 where !preview.isHittable {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.78))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.28)))
            }
            XCTAssertTrue(app.buttons["导出附件"].waitForExistence(timeout: 10))
            XCTAssertTrue(preview.isHittable)
            preview.tap()
            let readable = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch
            let textView = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", expected)).firstMatch
            let contentVisible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in readable.exists || textView.exists }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [contentVisible], timeout: 10), .completed, "The local file copy must contain the original fixture text: \(expected)")
            let contentShot = XCTAttachment(screenshot: app.screenshot())
            contentShot.name = "Retried import original file content - \(expected)"
            contentShot.lifetime = .keepAlways
            add(contentShot)
            let done = app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
            app.navigationBars["收藏详情"].buttons["关闭"].tap()
            XCTAssertTrue(app.staticTexts["2 条收藏"].waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testRejectedOriginalOpenCanCopyExactURL() throws {
        // A controlled SwiftUI OpenURLAction refusal, not a real Safari outage.
        let app = XCUIApplication()
        app.launchArguments = ["--network-failure-fixture", "--reject-open-url"]
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        XCTAssertTrue(app.buttons["添加内容"].waitForExistence(timeout: 10))
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        let url = "https://example.com/KexunNetworkFixture?item=42&source=copy-test"
        let editor = app.textViews["收藏内容"]
        editor.tap()
        editor.typeText(url)
        app.navigationBars["新收藏"].buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForNonExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "record.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let id = row.identifier
        app.buttons["fixture.releaseNetwork"].tap()
        row.tap()
        let editMarker = "UNSAVED-OPEN-FAILURE-"
        let titleField = app.textFields["标题"]
        titleField.tap()
        titleField.typeText(editMarker)
        let unsavedTitle = try XCTUnwrap(titleField.value as? String)
        XCTAssertTrue(unsavedTitle.contains(editMarker))
        XCTAssertNotEqual(unsavedTitle, url)
        app.buttons["keyboard.dismiss"].tap()
        XCTAssertTrue(app.buttons["打开原文"].waitForExistence(timeout: 5))
        app.buttons["打开原文"].tap()
        let error = app.staticTexts["无法打开原文，请复制链接后重试。"]
        XCTAssertTrue(error.waitForExistence(timeout: 5), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Rejected original URL open - recoverable error"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if app.alerts.buttons["知道了"].exists { app.alerts.buttons["知道了"].tap() }
        XCTAssertTrue(app.navigationBars["收藏详情"].exists)
        XCTAssertEqual(titleField.value as? String, unsavedTitle)
        app.buttons["打开原文"].tap()
        XCTAssertTrue(app.alerts.buttons["复制链接"].waitForExistence(timeout: 5))
        app.alerts.buttons["复制链接"].tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].exists)
        XCTAssertEqual(titleField.value as? String, unsavedTitle)
        app.navigationBars["收藏详情"].buttons["关闭"].tap()
        XCTAssertTrue(app.staticTexts["有未保存的内容"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["draft.discard"].firstMatch.tap()
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        let draft = app.textViews["收藏内容"]
        draft.tap()
        draft.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).press(forDuration: 1)
        let paste = app.menuItems.matching(NSPredicate(format: "label IN %@", ["粘贴", "Paste"])).firstMatch
        if paste.waitForExistence(timeout: 2) { paste.tap() }
        else {
            XCTAssertTrue(app.buttons["粘贴"].waitForExistence(timeout: 3))
            app.buttons["粘贴"].tap()
        }
        XCTAssertEqual(draft.value as? String, url)
        app.navigationBars["新收藏"].buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["有未保存的内容"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["draft.discard"].firstMatch.tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "record.")).count, 1)
        XCTAssertTrue(app.buttons[id].exists)
        app.buttons[id].tap()
        XCTAssertEqual(app.textFields["标题"].value as? String, url, "Closing the unsaved draft must not persist its title")
    }

    @MainActor
    func testControlledNetworkFailureRetryKeepsSavedLinkAndTitle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--network-failure-fixture"]
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        XCTAssertTrue(app.buttons["添加内容"].waitForExistence(timeout: 10))
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        let title = "NETWORK USER TITLE"
        let url = "https://example.com/KexunNetworkFixture"
        app.textFields["标题（选填）"].tap()
        app.textFields["标题（选填）"].typeText(title + "\n")
        let editor = app.textViews["收藏内容"]
        editor.tap()
        editor.typeText(url)
        app.navigationBars["新收藏"].buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForNonExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "record.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Base save must finish before releasing any network response")
        let id = row.identifier
        XCTAssertTrue(row.label.contains(title))
        for attempt in 1...3 {
            if attempt != 2 {
                let release = app.buttons["fixture.releaseNetwork"]
                XCTAssertTrue(release.waitForExistence(timeout: 5))
                release.tap()
                XCTAssertTrue(release.label.contains("(\(attempt == 1 ? 1 : 2))"), release.label)
            }
            app.buttons[id].tap()
            let expected = attempt == 3 ? app.staticTexts["链接信息已补全。"] : app.buttons["重试补全"]
            for _ in 0..<4 where !expected.isHittable { app.swipeUp() }
            XCTAssertTrue(expected.waitForExistence(timeout: 20), app.debugDescription)
            if attempt == 1 {
                XCTAssertTrue(app.staticTexts["网页暂不可用或内容过大，原链接已保留。"].exists)
            }
            if attempt == 2 {
                XCTAssertTrue(app.staticTexts["请求超时。"].exists, app.debugDescription)
                let capture = XCTAttachment(screenshot: app.screenshot())
                capture.name = "Controlled URLSession timeout - saved content remains"
                capture.lifetime = .keepAlways
                add(capture)
            }
            if attempt < 3 { expected.tap() }
            else { XCTAssertFalse(app.buttons["重试补全"].exists) }
            app.navigationBars["收藏详情"].buttons["关闭"].tap()
        }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "record.")).count, 1)
        app.buttons[id].tap()
        XCTAssertEqual(app.textFields["标题"].value as? String, title)
        XCTAssertEqual(app.staticTexts["detail.body"].label, url)
        XCTAssertTrue(app.buttons["复制链接"].exists)
    }

    @MainActor
    func testSystemFileBatchReportsOversizeWithoutLosingSuccess() throws {
        // Requires the two independent files in the dedicated simulator's
        // local Files provider / KexunImport112. Never seed collection rows.
        let app = XCUIApplication()
        app.launch()
        func count() throws -> Int {
            let label = app.staticTexts["library.count"]
            XCTAssertTrue(label.waitForExistence(timeout: 10))
            let prefix = try XCTUnwrap(label.label.components(separatedBy: " 条收藏").first)
            return try XCTUnwrap(Int(prefix.replacingOccurrences(of: ",", with: "")))
        }
        let before = try count()
        app.buttons["添加内容"].tap()
        app.buttons["导入文件 / PDF"].tap()
        let good = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "Import112-good")).firstMatch
        let oversized = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "Import112-oversize")).firstMatch
        let folder = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "KexunImport112")).firstMatch
        if !good.waitForExistence(timeout: 2) {
            if !folder.waitForExistence(timeout: 2) {
                if app.buttons["浏览"].exists { app.buttons["浏览"].tap() }
                let local = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "我的iPhone")).firstMatch
                if local.waitForExistence(timeout: 3) { local.tap() }
            }
            XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
            folder.tap()
        }
        XCTAssertTrue(good.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(oversized.exists)
        good.tap()
        oversized.tap()
        XCTAssertTrue(app.buttons["打开"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["打开"].tap()
        let report = app.staticTexts["本次已导入 1 项，已保存到资料库。"]
        XCTAssertTrue(report.waitForExistence(timeout: 20), app.debugDescription)
        let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Import112-oversize.bin")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertTrue(failure.label.contains("最大 100 MB"), failure.label)
        XCTAssertFalse(app.buttons["停止剩余导入"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Real system file batch - success and oversize failure"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["import.done"].tap()
        XCTAssertTrue(app.buttons["import.confirmDiscard"].waitForExistence(timeout: 5))
        app.buttons["import.confirmDiscard"].firstMatch.tap()
        XCTAssertEqual(try count(), before + 1)
        app.terminate()
        app.launch()
        XCTAssertEqual(try count(), before + 1)
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText("Import112-oversize\n")
        XCTAssertTrue(app.staticTexts["没有找到内容"].waitForExistence(timeout: 10), app.debugDescription)
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        search.typeText("Import112-good\n")
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Import112-good.txt")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        saved.tap()
        for _ in 0..<8 where !app.buttons["导出附件"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["导出附件"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSystemMultiplePhotosAndCancelPreserveCounts() throws {
        // Run on the dedicated simulator with at least two controlled Photos
        // images. Selection uses the actual system picker, not injected transfers.
        let app = XCUIApplication()
        app.launch()
        func count() throws -> Int {
            let label = app.staticTexts["library.count"]
            XCTAssertTrue(label.waitForExistence(timeout: 10))
            let prefix = try XCTUnwrap(label.label.components(separatedBy: " 条收藏").first)
            return try XCTUnwrap(Int(prefix.replacingOccurrences(of: ",", with: "")))
        }
        func selectTwoPhotos() throws {
            let images = app.images.matching(identifier: "PXGGridLayout-Info")
            XCTAssertTrue(images.element(boundBy: 1).waitForExistence(timeout: 10), app.debugDescription)
            images.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            images.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            // The system can present a dismissible information layer. Its Close
            // button is not the Photos navigation bar's Cancel action.
            if app.buttons["关闭"].exists && app.buttons["关闭"].isHittable { app.buttons["关闭"].tap() }
            XCTAssertTrue(images.element(boundBy: 0).isSelected)
            XCTAssertTrue(images.element(boundBy: 1).isSelected)
        }
        let before = try count()
        app.buttons["添加内容"].tap()
        app.buttons["选择照片"].tap()
        try selectTwoPhotos()
        let picker = app.navigationBars["照片"]
        XCTAssertTrue(picker.buttons["Cancel"].waitForExistence(timeout: 5))
        picker.buttons["Cancel"].tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["添加内容"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["import.savedCount"].exists)
        app.navigationBars["添加内容"].buttons["关闭"].tap()
        XCTAssertEqual(try count(), before)
        app.terminate()
        app.launch()
        XCTAssertEqual(try count(), before, "Cancelling selected Photos must not persist records")

        app.buttons["添加内容"].tap()
        app.buttons["选择照片"].tap()
        try selectTwoPhotos()
        let confirm = app.navigationBars["照片"].buttons["Add"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()
        let report = app.staticTexts["本次已导入 2 项，已保存到资料库。"]
        XCTAssertTrue(report.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.buttons["停止剩余导入"].exists)
        XCTAssertFalse(app.navigationBars.buttons["保存"].exists)
        app.buttons["import.done"].tap()
        XCTAssertEqual(try count(), before + 2)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'record.'"))
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 10))
        let identifiers = [rows.element(boundBy: 0).identifier, rows.element(boundBy: 1).identifier]
        XCTAssertEqual(Set(identifiers).count, 2)
        print("MULTI_PHOTO_SAVED_IDS \(identifiers.joined(separator: " "))")
        app.terminate()
        app.launch()
        XCTAssertEqual(try count(), before + 2)
        for identifier in identifiers {
            let row = app.buttons[identifier]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            XCTAssertTrue(row.label.contains("图片"))
            for _ in 0..<8 where !row.isHittable { app.swipeUp() }
            row.tap()
            for _ in 0..<8 where !app.buttons["预览附件"].exists { app.swipeUp() }
            XCTAssertTrue(app.buttons["预览附件"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["导出附件"].exists)
            app.navigationBars.buttons["关闭"].tap()
        }
    }

    @MainActor
    func testPopulatedLibraryTypesOrderingLayoutAndArchiveCounts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-scale-fixture"]
        app.launch()
        XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 60))
        if app.buttons["关闭收集提示"].exists { app.buttons["关闭收集提示"].tap() }
        func identifier(_ index: Int) -> String { String(format: "record.00000000-0000-4000-8000-%012d", index) }
        func row(_ index: Int) -> XCUIElement { app.buttons[identifier(index)] }
        func tapControl(_ name: String) {
            let control = app.buttons[name]
            for _ in 0..<12 where !control.isHittable { app.swipeDown() }
            XCTAssertTrue(control.isHittable, name)
            control.tap()
        }
        func assertCount(_ count: Int) {
            chooseMore(app, "多选")
            tapControl("全选当前结果")
            XCTAssertTrue(app.staticTexts["已选 \(count.formatted()) 条"].waitForExistence(timeout: 10))
            tapControl("取消多选")
        }
        XCTAssertTrue(app.textFields["library.search"].exists)
        XCTAssertTrue(app.staticTexts["1,000 条收藏"].waitForExistence(timeout: 10))
        chooseMore(app, "卡片")
        for _ in 0..<8 where !row(999).isHittable || !row(998).isHittable { app.swipeUp() }
        XCTAssertTrue(row(999).exists && row(998).exists)
        XCTAssertEqual(row(999).frame.midY, row(998).frame.midY, accuracy: 2, "Grid centers cards of different heights in one row")
        XCTAssertLessThan(row(999).frame.maxX, row(998).frame.minX)
        XCTAssertLessThan(row(999).frame.width, app.frame.width * 0.6)
        chooseMore(app, "列表")
        for _ in 0..<8 where !row(999).isHittable || !row(998).isHittable { app.swipeUp() }
        XCTAssertGreaterThan(row(999).frame.width, app.frame.width * 0.8)
        XCTAssertGreaterThan(row(998).frame.minY, row(999).frame.minY)
        for (kind, newest) in [("链接", 996), ("文字", 997), ("图片", 998), ("文件", 999)] {
            chooseFilter(app, "filter.kind", kind)
            XCTAssertTrue(app.staticTexts["library.filterSummary"].label.contains(kind))
            for _ in 0..<8 where !row(newest).exists { app.swipeUp() }
            XCTAssertTrue(row(newest).waitForExistence(timeout: 10))
            assertCount(250)
        }
        chooseFilter(app, "filter.kind", "全部类型")
        chooseMore(app, "最早保存")
        XCTAssertTrue(app.descendants(matching: .any)["library.list"].exists)
        for _ in 0..<8 where !row(0).exists { app.swipeUp() }
        XCTAssertTrue(row(0).waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'record.'")).firstMatch.identifier, identifier(0))
        chooseMore(app, "最近保存")
        for _ in 0..<8 where !row(999).exists { app.swipeUp() }
        XCTAssertTrue(row(999).waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'record.'")).firstMatch.identifier, identifier(999))
        assertCount(1000)
        chooseFilter(app, "归档状态", "已归档")
        assertCount(200)
        tapControl("quick.all")
        for _ in 0..<8 where !row(999).isHittable { app.swipeUp() }
        row(999).tap()
        for _ in 0..<8 where !app.buttons["归档"].isHittable { app.swipeUp() }
        app.buttons["归档"].tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForNonExistence(timeout: 10))
        chooseFilter(app, "归档状态", "已归档")
        assertCount(201)
        tapControl("quick.unarchived")
        assertCount(799)
        tapControl("quick.all")
        assertCount(1000)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "1000-record library after type layout sort and archive verification"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testMixedThousandRecordGridScrollingPerformance() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-scale-fixture"]
        app.launch()
        XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 60))
        if app.buttons["关闭收集提示"].exists { app.buttons["关闭收集提示"].tap() }
        XCTAssertTrue(app.textFields["library.search"].exists)
        XCTAssertTrue(app.staticTexts["1,000 条收藏"].waitForExistence(timeout: 10))
        chooseMore(app, "卡片")
        app.swipeUp()
        print("SCROLL_FIXTURE: 1000 SQLite records; 250 each link/text/image/file; 250 distinct PNGs rendered at 640x480 points using device scale and 250 4KiB files; grid layout")
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            app.swipeUp()
            app.swipeUp()
            app.swipeDown()
            app.swipeDown()
        }
    }

    @MainActor
    func testMissingAttachmentReportsAndRetriesWithHostRestore() throws {
        // Isolated phase-105 file fixture only. The host must quarantine its one
        // attachment before launch, then restore it after ATTACHMENT_RESTORE_READY.
        let fileName = "FileShare-CC3D8692-C680-4BAD-AAFD-01124759C1A4.bin"
        let app = XCUIApplication()
        app.launch()
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText(fileName + "\n")
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 10))
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", fileName)).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        let retry = app.buttons["重试准备附件"]
        for _ in 0..<8 where !retry.exists { app.swipeUp() }
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "附件暂时无法打开：")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["收藏记录仍保留。请重试，或从完整备份恢复缺失附件。不会自动删除这条收藏。"].exists)
        XCTAssertFalse(app.buttons["预览附件"].exists)
        XCTAssertFalse(app.buttons["导出附件"].exists)
        let missing = XCTAttachment(screenshot: app.screenshot())
        missing.name = "Missing attachment with record retained"
        missing.lifetime = .keepAlways
        add(missing)
        print("ATTACHMENT_RESTORE_READY \(fileName)")
        // Bounded host coordination window; no simulated successful prepare URL.
        let hostWindow = expectation(description: "Allow host to restore the quarantined attachment")
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { hostWindow.fulfill() }
        wait(for: [hostWindow], timeout: 30)
        for _ in 0..<8 where !retry.isHittable { app.swipeUp() }
        retry.tap()
        XCTAssertTrue(app.buttons["预览附件"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["导出附件"].exists)
        XCTAssertFalse(retry.exists)
        app.navigationBars.buttons["关闭"].tap()
        XCTAssertTrue(app.staticTexts["1 条收藏"].exists)
    }

    @MainActor
    func testPDFEmptyTextAndCorruptRetryStates() throws {
        for argument in ["--share-empty-pdf", "--share-corrupt-pdf"] {
            let app = XCUIApplication()
            app.launchArguments = ["--share-multi-link-preview", "--share-file", argument]
            app.launch()
            let name = app.staticTexts["fixture.fileName"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            let fileName = name.label
            print("PDF_STATE_FIXTURE \(argument) \(fileName)")
            app.buttons["分享测试文件"].tap()
            openKexunShare(app)
            app.scrollViews.buttons["保存"].tap()
            XCTAssertTrue(app.staticTexts["共 1 项：已保存 1 项，已跳过 0 项，失败 0 项，待保存 0 项。"].waitForExistence(timeout: 15))
            app.buttons["完成"].tap()
            app.terminate()
            app.launchArguments = []
            app.launch()
            app.textFields["library.search"].tap()
            let search = app.textFields["library.search"]
            search.tap()
            search.typeText(fileName + "\n")
            XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 10))
            let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", fileName)).firstMatch
            XCTAssertTrue(record.waitForExistence(timeout: 5))
            record.tap()
            let message = argument == "--share-empty-pdf"
                ? "未识别到文字，仍可通过标题和备注查找。"
                : "PDF 无法读取或需要密码，原文件已保留。"
            let status = app.staticTexts[message]
            for _ in 0..<8 where !status.exists { app.swipeUp() }
            XCTAssertTrue(status.waitForExistence(timeout: 15))
            if argument == "--share-corrupt-pdf" {
                let retry = app.buttons["重试提取"]
                for _ in 0..<8 where !retry.isHittable { app.swipeUp() }
                XCTAssertTrue(retry.isEnabled)
                retry.tap()
                XCTAssertTrue(status.waitForExistence(timeout: 15))
                XCTAssertTrue(retry.waitForExistence(timeout: 15))
                XCTAssertTrue(retry.isEnabled, "Retry must report the real parse failure, not pretend success")
            } else {
                XCTAssertFalse(app.buttons["重试提取"].exists, "Empty text is a completed extraction, not a failure")
            }
            XCTAssertTrue(app.buttons["导出附件"].exists, "Original file remains available after extraction")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = argument
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.navigationBars.buttons["关闭"].tap()
            XCTAssertTrue(app.staticTexts["1 条收藏"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testSharedFileSurvivesRemovalOfSource() throws {
        try verifySharedFileSurvivesRemovalOfSource(terminateExtension: false)
    }

    /// Run only with a host-side supervisor that kills this simulator's KexunShare
    /// after SHARE_EXTENSION_READY_FOR_TERMINATION appears in the test log.
    @MainActor
    func testSharedFileSurvivesForcedExtensionTermination() throws {
        try verifySharedFileSurvivesRemovalOfSource(terminateExtension: true)
    }

    @MainActor
    private func verifySharedFileSurvivesRemovalOfSource(terminateExtension: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--share-multi-link-preview", "--share-file"]
        app.launch()
        let name = app.staticTexts["fixture.fileName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let fileName = name.label
        let expectedSHA = app.staticTexts["fixture.fileSHA"].label
        print("FILE_SHARE_FIXTURE \(fileName) \(expectedSHA)")
        app.buttons["分享测试文件"].tap()
        openKexunShare(app)
        app.scrollViews.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["共 1 项：已保存 1 项，已跳过 0 项，失败 0 项，待保存 0 项。"].waitForExistence(timeout: 15))
        if terminateExtension {
            print("SHARE_EXTENSION_READY_FOR_TERMINATION \(fileName)")
            XCTAssertTrue(app.staticTexts["收下到可寻"].waitForNonExistence(timeout: 45),
                          "The host supervisor must terminate the actual extension, not tap Done")
        } else {
            app.buttons["完成"].tap()
        }
        if !terminateExtension {
            let removeSource = app.buttons["移除测试来源文件"]
            XCTAssertTrue(removeSource.waitForExistence(timeout: 10), app.debugDescription)
            removeSource.tap()
            XCTAssertTrue(app.staticTexts["测试来源文件已移除"].waitForExistence(timeout: 5))
        }
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText(fileName + "\n")
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 10))
        let record = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", fileName)).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        for _ in 0..<8 where !record.isHittable || record.frame.maxY > visibleLibraryContentBottom(in: app) { app.swipeUp() }
        record.tap()
        XCTAssertTrue(app.buttons["预览附件"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["导出附件"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fileName)).firstMatch.exists)
        app.navigationBars.buttons["关闭"].tap()
    }

    @MainActor
    func testPopulatedFilterIntersectionAndReset() throws {
        let app = XCUIApplication()
        app.launch()
        let marker = "FilterUI-\(UUID().uuidString.prefix(8))"
        let titles = [marker + " positive", marker + " control"]
        for title in titles {
            app.buttons["添加内容"].tap()
            app.buttons["capture.text"].tap()
            app.segmentedControls.buttons["文字"].tap()
            let field = app.textFields["标题（选填）"]
            field.tap()
            field.typeText(title)
            let editor = app.textViews["收藏内容"]
            for _ in 0..<8 where !editor.isHittable { app.swipeUp() }
            editor.tap()
            editor.typeText("筛选测试正文 " + title)
            app.navigationBars.buttons["保存"].tap()
            XCTAssertTrue(app.navigationBars["新收藏"].waitForNonExistence(timeout: 5))
        }
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText(marker + "\n")
        XCTAssertTrue(app.staticTexts["2 条收藏"].waitForExistence(timeout: 5))
        let positive = app.buttons.containing(.staticText, identifier: titles[0]).firstMatch
        for _ in 0..<8 where !positive.isHittable || positive.frame.maxY > visibleLibraryContentBottom(in: app) { app.swipeUp() }
        positive.tap()
        for _ in 0..<8 where !app.buttons["detail.star"].isHittable { app.swipeUp() }
        app.buttons["detail.star"].tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForNonExistence(timeout: 5))
        for _ in 0..<8 where !positive.isHittable || positive.frame.maxY > visibleLibraryContentBottom(in: app) { app.swipeUp() }
        positive.tap()
        for _ in 0..<8 where !app.buttons["归档"].isHittable { app.swipeUp() }
        app.buttons["归档"].tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["2 条收藏"].waitForExistence(timeout: 5), "Global search includes the archived positive")

        chooseFilter(app, "filter.kind", "文字")
        app.buttons["quick.starred"].tap()
        chooseFilter(app, "归档状态", "已归档")
        chooseFilter(app, "保存时间", "最近 7 天")
        chooseFilter(app, "来源", "随手记")
        XCTAssertEqual(app.buttons["library.filters"].label, "筛选 4")
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 5))
        XCTAssertTrue(positive.exists)
        XCTAssertFalse(app.buttons.containing(.staticText, identifier: titles[1]).firstMatch.exists)
        app.buttons["library.filters"].tap()
        for _ in 0..<8 where !app.buttons["重置筛选"].isHittable { app.swipeUp() }
        app.buttons["重置筛选"].tap()
        app.navigationBars["筛选"].buttons["完成"].tap()
        XCTAssertEqual(app.buttons["library.filters"].label, "筛选")
        XCTAssertEqual(search.value as? String, marker)
        XCTAssertTrue(app.buttons["quick.all"].isSelected)
        XCTAssertFalse(app.staticTexts["library.filterSummary"].exists)
        XCTAssertTrue(app.staticTexts["2 条收藏"].waitForExistence(timeout: 5))
        for title in titles {
            XCTAssertTrue(app.buttons.containing(.staticText, identifier: title).firstMatch.exists)
        }
    }

    @MainActor
    func testMainAppDuplicateCancelViewAndSaveAnother() throws {
        let app = XCUIApplication()
        app.launch()
        let marker = "MainDuplicate-\(UUID().uuidString.prefix(8))"
        let url = "https://example.com/" + marker + "?business=keep"
        let originalTitle = marker + " original"
        let alternateTitle = marker + " alternate"
        let originalBody = "第一份原始分享文字\n" + url
        let alternateBody = "第二份独立分享文字\n" + url

        @MainActor func draft(title: String, body: String) {
            app.buttons["添加内容"].tap()
            app.buttons["capture.link"].tap()
            let field = app.textFields["标题（选填）"]
            for _ in 0..<8 where !field.isHittable { app.swipeUp() }
            field.tap()
            field.typeText(title)
            let editor = app.textViews["收藏内容"]
            for _ in 0..<8 where !editor.isHittable { app.swipeUp() }
            editor.tap()
            editor.typeText(body)
            app.navigationBars.buttons["保存"].tap()
        }
        @MainActor func expectCount(_ count: Int) {
            let search = app.textFields["library.search"]
            if search.value as? String != marker {
                search.tap()
                search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (search.value as? String == "搜索收藏" ? 0 : (search.value as? String ?? "").count)))
                search.typeText(marker + "\n")
            }
            XCTAssertTrue(app.staticTexts["\(count) 条收藏"].waitForExistence(timeout: 5), app.debugDescription)
        }
        let duplicate = app.staticTexts["这个链接已经收下过了"]
        draft(title: originalTitle, body: originalBody)
        XCTAssertTrue(app.navigationBars["新收藏"].waitForNonExistence(timeout: 5))

        draft(title: alternateTitle, body: alternateBody)
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        try XCTUnwrap(app.buttons.matching(identifier: "取消").allElementsBoundByIndex.last).tap()
        XCTAssertTrue(duplicate.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.textViews["收藏内容"].value as? String, alternateBody)
        app.navigationBars.buttons["取消"].tap()
        expectCount(1)

        draft(title: alternateTitle, body: alternateBody)
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        app.buttons["查看已有收藏"].tap()
        XCTAssertTrue(app.staticTexts["detail.body"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detail.body"].label, originalBody)
        XCTAssertEqual(app.textFields["标题"].value as? String, originalTitle)
        app.navigationBars.buttons["关闭"].tap()
        XCTAssertEqual(app.textViews["收藏内容"].value as? String, alternateBody)
        app.navigationBars.buttons["取消"].tap()
        expectCount(1)

        draft(title: alternateTitle, body: alternateBody)
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        app.buttons["仍然保存一条"].tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForNonExistence(timeout: 5))
        app.terminate()
        app.launch()
        expectCount(2)
        for (title, body) in [(originalTitle, originalBody), (alternateTitle, alternateBody)] {
            let record = app.buttons.containing(.staticText, identifier: title).firstMatch
            XCTAssertTrue(record.waitForExistence(timeout: 5))
            for _ in 0..<8 where !record.isHittable || record.frame.maxY > visibleLibraryContentBottom(in: app) { app.swipeUp() }
            record.tap()
            XCTAssertTrue(app.staticTexts["detail.body"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["detail.body"].label, body)
            XCTAssertTrue(app.staticTexts[url].exists)
            app.navigationBars.buttons["关闭"].tap()
        }
    }

    @MainActor
    func testManualMultipleLinksPreservesBodyAndInvalidatesSelection() throws {
        let app = XCUIApplication()
        app.launch()
        let marker = "ManualMulti-\(UUID().uuidString.prefix(8))"
        let firstURL = "https://example.com/a/" + marker
        let secondURL = "https://example.com/b/" + marker
        let body = "中文原文\n" + firstURL + "\n" + secondURL
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        let save = app.navigationBars.buttons["保存"]
        XCTAssertFalse(save.isEnabled)
        let title = app.textFields["标题（选填）"]
        for _ in 0..<8 where !title.isHittable { app.swipeUp() }
        title.tap()
        title.typeText(marker)
        let editor = app.textViews["收藏内容"]
        for _ in 0..<8 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        editor.typeText("中文原文")
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(app.staticTexts["未找到有效的 HTTP 或 HTTPS 链接；如果要保存纯文字，请切换到文字。"].exists)
        editor.typeText("\n" + firstURL + "\n" + secondURL)
        app.buttons["keyboard.dismiss"].tap()
        XCTAssertFalse(save.isEnabled, "Multiple URLs require an explicit choice")

        @MainActor func choose(_ url: String) {
            let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "选择要保存的链接")).firstMatch
            for _ in 0..<8 where !picker.isHittable { app.swipeUp() }
            XCTAssertTrue(picker.isHittable, app.debugDescription)
            picker.tap()
            let option = app.buttons[url]
            XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
            option.tap()
        }
        choose(secondURL)
        XCTAssertTrue(save.isEnabled)
        for _ in 0..<8 where !editor.isHittable { app.swipeDown() }
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        editor.typeText("/new")
        let finalBody = body + "/new"
        XCTAssertEqual(editor.value as? String, finalBody)
        app.buttons["keyboard.dismiss"].tap()
        XCTAssertFalse(save.isEnabled, "Editing away the selected URL must invalidate it")
        choose(secondURL + "/new")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForNonExistence(timeout: 5))
        app.terminate()
        app.launch()
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText(marker + "\n")
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 5))
        let record = app.buttons.containing(.staticText, identifier: marker).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        for _ in 0..<8 where !record.isHittable || record.frame.maxY > visibleLibraryContentBottom(in: app) { app.swipeUp() }
        record.tap()
        XCTAssertTrue(app.staticTexts["detail.body"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detail.body"].label, finalBody)
        XCTAssertTrue(app.staticTexts[secondURL + "/new"].exists)
        XCTAssertEqual(app.textFields["标题"].value as? String, marker)
        app.navigationBars.buttons["关闭"].tap()
    }

    @MainActor
    func testRapidTextSaveCreatesSingleRecord() throws {
        let app = XCUIApplication()
        app.launch()
        let marker = "RapidSave-\(UUID().uuidString.prefix(8))"
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        let kind = app.segmentedControls.buttons["文字"]
        for _ in 0..<8 where !kind.isHittable { app.swipeUp() }
        kind.tap()
        let editor = app.textViews["收藏内容"]
        for _ in 0..<8 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        editor.typeText(marker + "\n连续点击保存不能重复写入")
        app.navigationBars.buttons["保存"].doubleTap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForNonExistence(timeout: 5))
        app.terminate()
        app.launch()
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText(marker + "\n")
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 5), app.debugDescription)
        let record = app.buttons.containing(.staticText, identifier: marker + "\n连续点击保存不能重复写入").firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        for _ in 0..<8 where !record.isHittable || record.frame.maxY > visibleLibraryContentBottom(in: app) { app.swipeUp() }
        record.tap()
        XCTAssertTrue(app.staticTexts["detail.body"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detail.body"].label, marker + "\n连续点击保存不能重复写入")
        app.navigationBars.buttons["关闭"].tap()
    }

    @MainActor
    func testProcessingPauseKeepsContentReadableAndRetryHonest() throws {
        // Requires Tests/processing-pause-fixture.sql on a dedicated simulator.
        // The trigger affects only its named fixture and must be removed by the harness.
        let app = XCUIApplication()
        app.launch()
        let notice = app.alerts.buttons["知道了"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        notice.tap()
        let paused = app.staticTexts["自动处理已暂停"]
        XCTAssertTrue(paused.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["暂时无法读取资料"].exists)
        let retry = app.buttons["重试自动处理"]
        XCTAssertTrue(retry.isHittable)
        retry.tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "Persistent failure must not report recovery")
        notice.tap()
        XCTAssertTrue(paused.waitForExistence(timeout: 5))
        let repeatedAlert = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: app.alerts.firstMatch)
        repeatedAlert.isInverted = true
        wait(for: [repeatedAlert], timeout: 3)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Processing paused with explicit retry and readable library"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText("ProcessingPauseUI-98\n")
        let record = app.buttons.containing(.staticText, identifier: "ProcessingPauseUI-98").firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        // A partly exposed card can be reported hittable behind the bottom bar.
        for _ in 0..<6 where !record.isHittable || record.frame.maxY > visibleLibraryContentBottom(in: app) {
            app.swipeUp()
        }
        XCTAssertLessThan(record.frame.maxY, visibleLibraryContentBottom(in: app))
        record.tap()
        XCTAssertTrue(app.staticTexts["detail.body"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detail.body"].label, "暂停期间原始正文仍然可读")
        app.navigationBars.buttons["关闭"].tap()
    }

    @MainActor
    func testBodyEditorChineseKeyboardComposition() throws {
        // Dedicated simulator must use the Chinese Pinyin keyboard.
        let app = XCUIApplication()
        app.launch()
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        let textKind = app.segmentedControls.buttons["文字"]
        for _ in 0..<12 where !textKind.isHittable { app.swipeUp() }
        textKind.tap()
        let editor = app.textViews["收藏内容"]
        for _ in 0..<12 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Tap actual keys so the IME owns a live marked-text range; typeText with
        // precomposed Chinese alone does not exercise that contract.
        for key in ["n", "i", "h", "a", "o"] {
            XCTAssertTrue(app.keys[key].exists)
            app.keys[key].tap()
        }
        let candidate = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "你好")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5), app.debugDescription)
        candidate.tap()
        XCTAssertEqual(editor.value as? String, "你好")
        app.keys["delete"].tap()
        XCTAssertEqual(editor.value as? String, "你")
        app.buttons["keyboard.dismiss"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        editor.tap()
        XCTAssertEqual(editor.value as? String, "你")
        app.buttons["keyboard.dismiss"].tap()
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["有未保存的内容"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["draft.discard"].firstMatch.tap()
    }

    @MainActor
    func testLongDraftTailEditing() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        let textKind = app.segmentedControls.buttons["文字"]
        for _ in 0..<12 where !textKind.isHittable { app.swipeUp() }
        textKind.tap()
        let editor = app.textViews["收藏内容"]
        for _ in 0..<12 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        let prefix = (1...6).map { "第\($0)行：这里是需要连续编辑的长正文。" }.joined(separator: "\n")
        editor.typeText(prefix)
        editor.typeText("\n末尾可见")
        editor.typeText("X")
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(editor.value as? String, prefix + "\n末尾可见")
        let hierarchy = XCTAttachment(string: editor.debugDescription)
        hierarchy.name = "Long draft editor frame and accessibility state"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        try assertVisibleEditorText("末尾可见", editor: editor, app: app)
        app.buttons["keyboard.dismiss"].tap()
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["有未保存的内容"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["draft.discard"].firstMatch.tap()
    }

    @MainActor
    private func assertVisibleEditorText(_ expected: String, editor: XCUIElement, app: XCUIApplication) throws {
        let rendered = app.screenshot()
        let screenshot = XCTAttachment(screenshot: rendered)
        screenshot.name = "Visible editor tail: \(editor.label)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // Read pixels from the editor only, not its full accessibility value.
        // This fails if text is stored correctly but the viewport stays at the top.
        let image = try XCTUnwrap(rendered.image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let frame = editor.frame.intersection(app.frame)
        let crop = CGRect(x: (frame.minX - app.frame.minX) * scale,
                          y: (frame.minY - app.frame.minY) * scale,
                          width: frame.width * scale, height: frame.height * scale)
        let editorImage = try XCTUnwrap(image.cropping(to: crop))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: editorImage).perform([request])
        let visibleText = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined() ?? ""
        XCTAssertTrue(visibleText.replacingOccurrences(of: " ", with: "").contains(expected), visibleText)
    }

    @MainActor
    func testSmallScreenLongTextAndKeyboardPersistence() throws {
        let app = XCUIApplication()
        app.launch()
        let marker = "SmallText-\(UUID().uuidString.prefix(8))"
        let title = marker + " 小屏长标题验证，完整内容不会因列表截断而丢失"
        let body = "第一行：保留中文与标点。\n第二行：离线收藏仍能找到。\n第三行：键盘打开时也能保存。\n第四行：末尾标记 \(marker)"
        let note = (1...4).map { "第\($0)行备注：保存完整内容，保持可编辑。" }.joined(separator: "\n") + "\n\(marker)\n末尾可见"
        func reveal(_ element: XCUIElement) {
            for _ in 0..<30 where !element.isHittable { app.swipeUp() }
            XCTAssertTrue(element.isHittable)
        }
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        let textKind = app.segmentedControls.buttons["文字"]
        reveal(textKind)
        textKind.tap()
        let titleField = app.textFields["标题（选填）"]
        reveal(titleField)
        titleField.tap()
        titleField.typeText(title)
        let hideKeyboard = app.buttons["keyboard.dismiss"]
        XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 5))
        hideKeyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let editor = app.textViews["收藏内容"]
        reveal(editor)
        editor.tap()
        editor.typeText(body)
        XCTAssertEqual(editor.value as? String, body)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.navigationBars.buttons["保存"].isHittable)
        capture("Small screen long text with keyboard")
        app.navigationBars.buttons["保存"].tap()

        app.terminate()
        app.launch()
        let searchEntry = app.textFields["library.search"]
        reveal(searchEntry)
        searchEntry.tap()
        let search = app.textFields["library.search"]
        reveal(search)
        search.tap()
        search.typeText(marker + "\n")
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 5))
        let card = app.buttons.containing(.staticText, identifier: title).firstMatch
        reveal(card)
        card.tap()
        XCTAssertEqual(app.textFields["标题"].value as? String, title)
        XCTAssertEqual(app.staticTexts["detail.body"].label, body)
        let noteField = app.textViews["备注"]
        reveal(noteField)
        noteField.tap()
        noteField.typeText(note)
        noteField.typeText("X")
        noteField.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(noteField.value as? String, note)
        try assertVisibleEditorText("末尾可见", editor: noteField, app: app)
        XCTAssertTrue(hideKeyboard.isHittable)
        XCTAssertTrue(app.navigationBars.buttons["保存"].isHittable)
        capture("Small screen multiline note with keyboard")
        app.navigationBars.buttons["保存"].tap()
        app.terminate()
        app.launch()
        reveal(searchEntry)
        searchEntry.tap()
        reveal(search)
        search.tap()
        search.typeText(marker + "\n")
        reveal(card)
        card.tap()
        reveal(noteField)
        XCTAssertEqual(noteField.value as? String, note)
        XCTAssertEqual(app.staticTexts["detail.body"].label, body)
        app.navigationBars.buttons["关闭"].tap()
    }

    @MainActor
    func testSmallScreenAccessibilityAudit() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launch()
        let guide = app.buttons["关闭收集提示"]
        if guide.waitForExistence(timeout: 2) {
            for _ in 0..<8 where !guide.isHittable { app.swipeUp() }
            guide.tap()
            app.swipeDown()
        }
        func audit(_ name: String) throws {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
            try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .textClipped])
        }
        XCTAssertTrue(app.buttons["添加内容"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["library.search"].exists)
        XCTAssertFalse(app.buttons["收集箱"].exists)
        try audit("Small screen library accessibility")
        app.buttons["library.settings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["添加内容"].isHittable)
        try audit("Small screen settings accessibility")
        app.navigationBars["设置"].buttons["完成"].tap()
        app.buttons["添加内容"].tap()
        XCTAssertTrue(app.navigationBars["添加内容"].buttons["关闭"].waitForExistence(timeout: 5))
        try audit("Small screen capture accessibility")
        app.navigationBars["添加内容"].buttons["关闭"].tap()
    }

    @MainActor
    func testSettingsPrivacyAndBuildInformation() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        app.buttons["library.settings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        let privacy = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "目标网站可能接收网络请求信息")).firstMatch
        for _ in 0..<10 where !privacy.isHittable { app.swipeUp() }
        XCTAssertTrue(privacy.exists)
        XCTAssertTrue(privacy.label.contains("图片 OCR 与 PDF 文本提取在设备上进行"))
        let version = app.staticTexts["settings.version"]
        for _ in 0..<5 where !version.isHittable { app.swipeUp() }
        XCTAssertTrue(version.exists)
        // Match the current acceptance build settings; production reads its own bundle values.
        XCTAssertEqual(version.label, "可寻 1.0（1）")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Settings privacy and bundle version"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(app.navigationBars["设置"].buttons["完成"].exists)
        XCTAssertFalse(app.buttons["添加内容"].isHittable)
        app.navigationBars["设置"].buttons["完成"].tap()
        XCTAssertTrue(app.textFields["library.search"].exists)
        XCTAssertTrue(app.buttons["添加内容"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsAndTrashSheetsPreserveLibraryScope() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        let folders = app.buttons["library.folders"]
        let addButton = app.buttons["添加内容"]
        let settingsButton = app.buttons["library.settings"]
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }
        func assertLibraryNavigation() {
            for button in [folders, addButton, settingsButton] {
                XCTAssertTrue(button.isHittable)
                XCTAssertGreaterThanOrEqual(button.frame.height, 44)
                XCTAssertGreaterThanOrEqual(button.frame.width, 44)
                XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX)
                XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
            }
            XCTAssertEqual(settingsButton.label, "设置")
            XCTAssertFalse(app.buttons["收集箱"].exists)
        }

        XCTAssertTrue(folders.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["library.search"].isHittable, "Library must be the default destination")
        XCTAssertFalse(app.navigationBars["设置"].exists)
        XCTAssertTrue(app.buttons["quick.all"].isSelected, "The default library must include archived records")
        assertLibraryNavigation()
        capture("Default all-library navigation")

        addButton.tap()
        XCTAssertTrue(app.navigationBars["添加内容"].buttons["关闭"].waitForExistence(timeout: 5))
        app.navigationBars["添加内容"].buttons["关闭"].tap()
        XCTAssertTrue(app.textFields["library.search"].isHittable, "Cancelling capture returns to the library")

        app.buttons["quick.unarchived"].tap()
        XCTAssertTrue(app.buttons["quick.unarchived"].isSelected)
        settingsButton.tap()
        XCTAssertTrue(app.navigationBars["设置"].buttons["完成"].waitForExistence(timeout: 5))
        XCTAssertFalse(addButton.isHittable)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        capture("Settings independent sheet")

        app.buttons["数据与备份"].tap()
        XCTAssertTrue(app.navigationBars["数据与备份"].waitForExistence(timeout: 5))
        capture("Settings data and backup destination")
        app.navigationBars["数据与备份"].buttons["设置"].tap()
        app.navigationBars["设置"].buttons["完成"].tap()
        XCTAssertTrue(app.textFields["library.search"].isHittable)
        XCTAssertTrue(app.buttons["quick.unarchived"].isSelected, "Library filters must survive a settings round trip")
        capture("Library filter preserved after settings")
        settingsButton.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5), "Reopening settings starts at its root")
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["设置"].buttons["完成"].exists)

        app.buttons["settings.trash"].tap()
        XCTAssertTrue(app.staticTexts["回收站"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.buttons["完成"].exists)
        XCTAssertFalse(addButton.isHittable, "Trash is an independent sheet without capture")
        capture("Settings recycle bin shortcut")
        closeTrash(app)
        XCTAssertTrue(app.buttons["quick.unarchived"].isSelected, "Trash must not overwrite the library scope")
    }

    @MainActor
    func testDarkAppearanceMainSurfaces() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertTrue(app.buttons["添加内容"].waitForExistence(timeout: 5))
        capture("Dark library default")
        XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["quick.all"].isSelected)
        app.buttons["quick.unarchived"].tap()
        XCTAssertTrue(app.buttons["quick.unarchived"].isSelected)
        XCTAssertFalse(app.buttons["quick.all"].isSelected)
        app.buttons["quick.starred"].tap()
        XCTAssertTrue(app.buttons["quick.starred"].isSelected)
        XCTAssertFalse(app.buttons["quick.all"].isSelected)
        app.buttons["quick.all"].tap()
        chooseFilter(app, "归档状态", "已归档")
        XCTAssertTrue(app.staticTexts["library.filterSummary"].label.contains("已归档"))
        XCTAssertFalse(app.buttons["quick.starred"].isSelected)
        app.buttons["quick.all"].tap()
        capture("Dark library filters")
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        XCTAssertTrue(app.navigationBars.buttons["取消"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["粘贴链接或分享文字"].exists)
        app.segmentedControls.buttons["文字"].tap()
        XCTAssertTrue(app.staticTexts["写下要保存的文字"].exists)
        capture("Dark capture form")
        app.navigationBars.buttons["取消"].tap()
        app.buttons["library.settings"].tap()
        XCTAssertTrue(app.buttons["数据与备份"].waitForExistence(timeout: 5))
        capture("Dark settings")
    }

    @MainActor
    func testAccessibilityLargeTypeNavigation() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        for label in ["library.folders", "添加内容", "library.settings"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
        }
        XCTAssertTrue(app.textFields["library.search"].isHittable)
        XCTAssertFalse(app.buttons["收集箱"].exists)
        let home = XCTAttachment(screenshot: app.screenshot())
        home.name = "Accessibility XXXL default library"
        home.lifetime = .keepAlways
        add(home)
        XCTAssertTrue(app.buttons["library.filters"].waitForExistence(timeout: 5))
        let library = XCTAttachment(screenshot: app.screenshot())
        library.name = "Accessibility XXXL library"
        library.lifetime = .keepAlways
        add(library)
        openTrash(app)
        for _ in 0..<5 where !app.staticTexts["回收站为空"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["回收站为空"].isHittable)
        assertEmptyTrashCannotBeCleared(app)
        closeTrash(app)
        for _ in 0..<5 where !app.staticTexts["先收下第一条内容"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["先收下第一条内容"].isHittable)
        chooseMore(app, "多选")
        let selectAll = app.buttons["全选当前结果"]
        for _ in 0..<8 where !selectAll.isHittable { app.swipeUp() }
        XCTAssertTrue(selectAll.isHittable)
        XCTAssertGreaterThanOrEqual(selectAll.frame.height, 44)
        XCTAssertGreaterThanOrEqual(selectAll.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(selectAll.frame.maxX, app.frame.maxX)
        let selectionShot = XCTAttachment(screenshot: app.screenshot())
        selectionShot.name = "Accessibility XXXL selection actions"
        selectionShot.lifetime = .keepAlways
        add(selectionShot)
        let cancelSelection = app.buttons["取消多选"]
        for _ in 0..<8 where !cancelSelection.isHittable { app.swipeDown() }
        cancelSelection.tap()
        app.buttons["添加内容"].tap()
        XCTAssertTrue(app.navigationBars["添加内容"].buttons["关闭"].waitForExistence(timeout: 5))
        app.navigationBars["添加内容"].buttons["关闭"].tap()
    }

    @MainActor
    func testCopyCollectionTextIntoNewDraft() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        let title = "CopyUI-\(UUID().uuidString.prefix(8))"
        let body = "可寻复制验证\n第二行保留原文"
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        app.segmentedControls.buttons["文字"].tap()
        app.textFields["标题（选填）"].tap()
        app.textFields["标题（选填）"].typeText(title)
        app.textViews["收藏内容"].tap()
        app.textViews["收藏内容"].typeText(body)
        app.navigationBars.buttons["保存"].tap()
        let card = app.buttons.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.buttons["复制文字"].waitForExistence(timeout: 5))
        app.buttons["复制文字"].tap()
        app.navigationBars.buttons["关闭"].tap()
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        app.segmentedControls.buttons["文字"].tap()
        let draft = app.textViews["收藏内容"]
        draft.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        draft.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        draft.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).press(forDuration: 1)
        let menu = XCTAttachment(string: app.debugDescription)
        menu.name = "System paste menu for copied collection"
        menu.lifetime = .keepAlways
        add(menu)
        let paste = app.menuItems.matching(NSPredicate(format: "label IN %@", ["粘贴", "Paste"])).firstMatch
        if paste.waitForExistence(timeout: 2) { paste.tap() }
        else {
            XCTAssertTrue(app.buttons["粘贴"].waitForExistence(timeout: 3))
            app.buttons["粘贴"].tap()
        }
        XCTAssertEqual(draft.value as? String, body)
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["有未保存的内容"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["draft.discard"].firstMatch.tap()
    }

    @MainActor
    func testEmptyLibrarySearchAndTrashStates() throws {
        // Use the empty dedicated fresh-install device; do not clear existing data here.
        let app = XCUIApplication()
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        XCTAssertTrue(app.staticTexts["0 条收藏"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["library.filters"].label, "筛选")
        chooseFilter(app, "filter.kind", "文字")
        XCTAssertTrue(app.staticTexts["library.filterSummary"].label.contains("文字"))
        XCTAssertEqual(app.buttons["library.filters"].label, "筛选 1")
        chooseFilter(app, "filter.kind", "全部类型")
        XCTAssertFalse(app.staticTexts["library.filterSummary"].exists)
        XCTAssertEqual(app.buttons["library.filters"].label, "筛选")
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText("nothing here\n")
        XCTAssertTrue(app.staticTexts["没有找到内容"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["先收下第一条内容"].exists)
        app.buttons["library.cancelSearch"].tap()
        XCTAssertTrue(app.textFields["library.search"].exists)
        openTrash(app)
        XCTAssertTrue(app.staticTexts["回收站为空"].waitForExistence(timeout: 5))
        assertEmptyTrashCannotBeCleared(app)
        closeTrash(app)
        XCTAssertTrue(app.staticTexts["先收下第一条内容"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFreshInstallGuideAndEmptyLibrary() throws {
        // Run only on a newly created dedicated simulator; never reset a user's library for this test.
        let app = XCUIApplication()
        app.launch()
        let guide = app.buttons["关闭收集提示"]
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["0 条收藏"].exists)
        XCTAssertFalse(app.buttons["登录"].exists)
        XCTAssertEqual(app.alerts.count, 0)
        let first = XCTAttachment(screenshot: app.screenshot())
        first.name = "Clean install local capture guide"
        first.lifetime = .keepAlways
        add(first)
        guide.tap()
        XCTAssertTrue(app.staticTexts["先收下第一条内容"].waitForExistence(timeout: 5))
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        app.segmentedControls.buttons["文字"].tap()
        XCTAssertFalse(app.navigationBars.buttons["保存"].isEnabled)
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["0 条收藏"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["library.search"].exists)
        XCTAssertTrue(app.staticTexts["先收下第一条内容"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["0 条收藏"].waitForExistence(timeout: 5))
        XCTAssertFalse(guide.exists)
        XCTAssertTrue(app.staticTexts["先收下第一条内容"].exists)
    }

    @MainActor
    func testSharePresentationActionsStayReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--share-multi-link-preview"]
        app.launch()
        app.buttons["分享 URL 与附带文字"].tap()
        openKexunShare(app)
        let ready = XCTAttachment(screenshot: app.screenshot())
        ready.name = "Share presentation ready at configured appearance and type size"
        ready.lifetime = .keepAlways
        add(ready)
        let save = app.scrollViews.buttons["保存"]
        for _ in 0..<6 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable)
        XCTAssertGreaterThanOrEqual(save.frame.height, 44)
        save.tap()
        XCTAssertTrue(app.staticTexts["共 1 项：已保存 1 项，已跳过 0 项，失败 0 项，待保存 0 项。"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["重试未保存项目"].exists)
        let done = app.buttons["完成"]
        for _ in 0..<6 where !done.isHittable { app.swipeUp() }
        XCTAssertTrue(done.isHittable)
        XCTAssertGreaterThanOrEqual(done.frame.height, 44)
        let saved = XCTAttachment(screenshot: app.screenshot())
        saved.name = "Share presentation saved at configured appearance and type size"
        saved.lifetime = .keepAlways
        add(saved)
        done.tap()
        XCTAssertTrue(app.buttons["分享 URL 与附带文字"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testShareURLAndPlainTextRepresentationsSurviveProcessBoundary() throws {
        try verifyDualRepresentationShare(failText: false)
    }

    @MainActor
    func testShareOptionalTextFailureReportsWarningAndPreservesURL() throws {
        try verifyDualRepresentationShare(failText: true)
    }

    @MainActor
    private func verifyDualRepresentationShare(failText: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--share-multi-link-preview"] + (failText ? ["--share-text-failure"] : [])
        app.launch()
        let inputURL = app.staticTexts["fixture.dualURL"]
        XCTAssertTrue(inputURL.waitForExistence(timeout: 5))
        let expectedURL = inputURL.label
        let marker = try XCTUnwrap(URL(string: expectedURL)?.lastPathComponent)
        let expectedBody = failText ? expectedURL : marker + "\n中文附带说明\n  保留空格  \n" + expectedURL
        app.buttons["分享 URL 与附带文字"].tap()
        openKexunShare(app)
        let ready = XCTAttachment(screenshot: app.screenshot())
        ready.name = "Share ready card and primary save"
        ready.lifetime = .keepAlways
        add(ready)
        app.scrollViews.buttons["保存"].tap()
        if failText {
            let result = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "共 1 项：已保存 1 项，已跳过 0 项，失败 0 项，待保存 0 项。")).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 10))
            XCTAssertTrue(result.label.contains("来源附带文字读取失败"))
            XCTAssertTrue(result.label.contains("请返回来源复制文字后另行保存"))
            XCTAssertFalse(app.buttons["重试未保存项目"].exists, "A fully saved share must hide retry, including when optional text produced a warning")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Optional text failure with saved link and explicit warning"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        } else {
            XCTAssertTrue(app.staticTexts["共 1 项：已保存 1 项，已跳过 0 项，失败 0 项，待保存 0 项。"].waitForExistence(timeout: 10))
        }
        XCTAssertFalse(app.buttons["重试未保存项目"].exists)
        XCTAssertTrue(app.buttons["完成"].isHittable)
        let saved = XCTAttachment(screenshot: app.screenshot())
        saved.name = "Share saved with single Done action"
        saved.lifetime = .keepAlways
        add(saved)
        app.buttons["完成"].tap()
        app.terminate()
        app.launchArguments = []
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText(expectedURL + "\n")
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 5))
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", marker, "链接")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.staticTexts[expectedURL].waitForExistence(timeout: 5))
        let body = app.staticTexts["detail.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertEqual(body.label, expectedBody, "Only successfully supplied content may be saved; URL must survive system sharing and app restart")
        XCTAssertTrue(app.buttons["打开原文"].exists)
    }

    @MainActor
    private func openKexunShare(_ app: XCUIApplication) {
        let shareCell = app.cells["Kexun"]
        XCTAssertTrue(shareCell.waitForExistence(timeout: 10))
        var lastFrame = shareCell.frame
        var stableSince = ProcessInfo.processInfo.systemUptime
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = shareCell.frame
            if frame != lastFrame {
                lastFrame = frame
                stableSince = ProcessInfo.processInfo.systemUptime
            }
            return shareCell.isHittable && ProcessInfo.processInfo.systemUptime - stableSince >= 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
        shareCell.tap()
        XCTAssertTrue(app.staticTexts["收下到可寻"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testShareBatchStopPreservesCompletedAndRetriesRemainder() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--share-multi-link-preview", "--share-batch-stop"]
        app.launch()
        let input = app.staticTexts["fixture.dualURL"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let sourceURL = input.label
        let marker = try XCTUnwrap(URL(string: sourceURL)?.lastPathComponent)
        app.buttons["分享 URL 与附带文字"].tap()
        openKexunShare(app)
        app.scrollViews.buttons["保存"].tap()
        let loading = app.staticTexts["正在处理第 2 / 3 项。\n共 3 项：已保存 1 项，已跳过 0 项，失败 0 项，待保存 2 项。"]
        XCTAssertTrue(loading.waitForExistence(timeout: 10))
        app.buttons["停止保存"].tap()
        let stopped = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "共 3 项：已保存 1 项，已跳过 0 项，失败 0 项，待保存 2 项。")).firstMatch
        XCTAssertTrue(stopped.waitForExistence(timeout: 5))
        XCTAssertTrue(stopped.label.contains("已停止；失败和待保存的项目可重试，已保存及已跳过的项目不会重复处理。"))
        XCTAssertTrue(app.buttons["重试未保存项目"].isEnabled)
        let unexpectedChange = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !stopped.exists }, object: nil)
        unexpectedChange.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedChange], timeout: 14), .completed)
        XCTAssertTrue(stopped.exists, "A delayed provider result must not resume the stopped batch")
        app.buttons["重试未保存项目"].tap()
        // UIKit may cache the completed provider representation. Do not require
        // another delay; a duplicate prompt or extra record would fail below.
        XCTAssertTrue(app.staticTexts["共 3 项：已保存 3 项，已跳过 0 项，失败 0 项，待保存 0 项。"].waitForExistence(timeout: 25))
        app.buttons["完成"].tap()
        app.terminate()
        app.launchArguments = []
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText(marker + "\n")
        XCTAssertTrue(app.staticTexts["3 条收藏"].waitForExistence(timeout: 5))
        for (prefix, expectedBody) in [
            ("第二项慢速正文", "第二项慢速正文 \(marker)\n\(sourceURL)/slow"),
            ("第三项未开始正文", "第三项未开始正文 \(marker)")
        ] {
            let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", prefix)).firstMatch
            // A partially visible card can be reported hittable even when its
            // center is behind the bottom bar, where XCTest synthesizes a tap.
            for _ in 0..<5 {
                if card.isHittable && card.frame.midY < visibleLibraryContentBottom(in: app) - 8 { break }
                app.swipeUp()
            }
            XCTAssertTrue(card.isHittable)
            card.tap()
            XCTAssertTrue(app.staticTexts["detail.body"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["detail.body"].label, expectedBody)
            app.navigationBars.buttons["关闭"].tap()
        }
    }

    @MainActor
    func testShareBatchExplicitSkipPreservesSuccessWithoutRetry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--share-multi-link-preview", "--share-batch-partial"]
        app.launch()
        let input = app.staticTexts["fixture.dualURL"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let url = input.label
        let marker = try XCTUnwrap(URL(string: url)?.lastPathComponent)
        let firstBody = marker + "\n中文附带说明\n  保留空格  \n" + url
        app.buttons["分享 URL 与附带文字"].tap()
        openKexunShare(app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "共 2 项。")).firstMatch.exists)
        app.scrollViews.buttons["保存"].tap()
        XCTAssertTrue(app.alerts.buttons["跳过此项"].waitForExistence(timeout: 10))
        app.alerts.buttons["跳过此项"].tap()
        let partial = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "共 2 项：已保存 1 项，已跳过 1 项，失败 0 项，待保存 0 项。")).firstMatch
        XCTAssertTrue(partial.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["重试未保存项目"].exists, "Explicit skip resolves the item rather than offering a failure retry")
        app.buttons["完成"].tap()
        app.terminate()
        app.launchArguments = []
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText(marker + "\n")
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 5))
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", marker, "链接")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        for _ in 0..<8 where !app.staticTexts["detail.body"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["detail.body"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detail.body"].label, firstBody)
        app.navigationBars.buttons["关闭"].tap()
        let textCard = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", marker, "第二项独立正文")).firstMatch
        XCTAssertFalse(textCard.exists, "The skipped second item must never enter the library")
    }

    @MainActor
    func testShareMultiLinkAsCompleteText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--share-multi-link-preview"]
        app.launch()
        app.buttons["分享 21 个链接的文字"].tap()
        XCTAssertTrue(app.cells["Kexun"].waitForExistence(timeout: 5))
        app.cells["Kexun"].tap()
        XCTAssertTrue(app.staticTexts["收下到可寻"].waitForExistence(timeout: 5))
        app.scrollViews.buttons["保存"].tap()
        let first = app.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "https://example.com/KexunMultiLink/", "/page-1")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let prefix = String(first.label.dropLast(1))
        let expected = (1...21).map { prefix + String($0) }.joined(separator: "\n")
        app.alerts.buttons["完整保存为文字"].tap()
        XCTAssertTrue(app.staticTexts["共 1 项：已保存 1 项，已跳过 0 项，失败 0 项，待保存 0 项。"].waitForExistence(timeout: 10))
        app.buttons["完成"].tap()
        app.terminate()
        app.launchArguments = []
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        app.textFields["library.search"].tap()
        app.textFields["library.search"].tap()
        app.textFields["library.search"].typeText(prefix + "21\n")
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 5))
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "KexunMultiLink", "分享文字, 文字")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        let savedBody = app.staticTexts["detail.body"]
        XCTAssertTrue(savedBody.waitForExistence(timeout: 5))
        XCTAssertEqual(savedBody.label, expected, "All URLs and line breaks must remain intact")
        for _ in 0..<8 where !app.buttons["移入回收站"].isHittable { app.swipeUp() }
        XCTAssertFalse(app.buttons["打开原文"].exists)
        XCTAssertFalse(app.staticTexts["链接信息已补全。"].exists)
    }

    @MainActor
    func testShareMultiLinkSecondPageSelection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--share-multi-link-preview"]
        app.launch()
        app.buttons["分享 21 个链接的文字"].tap()
        XCTAssertTrue(app.cells["Kexun"].waitForExistence(timeout: 5))
        app.cells["Kexun"].tap()
        XCTAssertTrue(app.staticTexts["收下到可寻"].waitForExistence(timeout: 5))
        app.scrollViews.buttons["保存"].tap()
        let alert = app.staticTexts["选择要保存的链接"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let next = app.buttons["下一页链接"]
        func reveal(_ element: XCUIElement) {
            for _ in 0..<12 where !element.isHittable {
                app.scrollViews["share.linkChoices"].swipeUp()
            }
            var lastFrame = element.frame
            var unchangedSince = ProcessInfo.processInfo.systemUptime
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = element.frame
                if frame != lastFrame {
                    lastFrame = frame
                    unchangedSince = ProcessInfo.processInfo.systemUptime
                }
                return element.isHittable && ProcessInfo.processInfo.systemUptime - unchangedSince > 0.6
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
        }
        for _ in 0..<4 {
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            guard next.isHittable else {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Multi-link pagination inaccessible"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                XCTFail("Next-page action must remain reachable at the current text size")
                return
            }
            next.tap()
        }
        let last = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "https://example.com/KexunMultiLink/", "/page-21")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        let selectedURL = last.label
        XCTAssertTrue(app.buttons["上一页链接"].exists)
        XCTAssertFalse(app.buttons["下一页链接"].exists)
        app.buttons["上一页链接"].tap()
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["上一页链接"].exists)
        XCTAssertTrue(app.buttons[selectedURL.replacingOccurrences(of: "/page-21", with: "/page-16")].exists)
        reveal(app.buttons["跳过此项"])
        let paginationScreenshot = XCTAttachment(screenshot: app.screenshot())
        paginationScreenshot.name = "Multi-link page with previous next and skip"
        paginationScreenshot.lifetime = .keepAlways
        add(paginationScreenshot)
        guard app.buttons["跳过此项"].isHittable else {
            XCTFail("Skip must remain reachable at the current text size")
            return
        }
        app.buttons["跳过此项"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let cancelled = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "共 1 项：已保存 0 项，已跳过 1 项，失败 0 项，待保存 0 项。")).firstMatch
        XCTAssertTrue(cancelled.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["重试未保存项目"].exists)
        app.buttons["完成"].tap()
        // A skipped session is finished. Start a new real share to verify selection.
        XCTAssertTrue(app.buttons["分享 21 个链接的文字"].waitForExistence(timeout: 5))
        app.buttons["分享 21 个链接的文字"].tap()
        openKexunShare(app)
        app.scrollViews.buttons["保存"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        for _ in 0..<4 {
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            next.tap()
        }
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        reveal(last)
        last.tap()
        XCTAssertTrue(app.staticTexts["共 1 项：已保存 1 项，已跳过 0 项，失败 0 项，待保存 0 项。"].waitForExistence(timeout: 10))
        app.buttons["完成"].tap()
        app.terminate()
        app.launchArguments = []
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        app.textFields["library.search"].tap()
        app.textFields["library.search"].tap()
        app.textFields["library.search"].typeText(selectedURL + "\n")
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 5))
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "KexunMultiLink", "链接")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        for _ in 0..<5 where card.frame.maxY > app.frame.maxY - 100 { app.swipeUp() }
        card.tap()
        let original = app.staticTexts[selectedURL]
        for _ in 0..<12 where !original.isHittable { app.swipeUp() }
        XCTAssertTrue(original.exists, "The chosen URL must be page 21, not silently page 1")
    }

    @MainActor
    func testQuotaRestoreFailureKeepsSelection() throws {
        // Dedicated 100-active plus one trashed QuotaRestoreFixture record.
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["100 条收藏"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["library.search"].exists)
        openTrash(app)
        let card = app.buttons.containing(.staticText, identifier: "QuotaRestoreFixture").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        chooseMore(app, "多选")
        card.tap()
        XCTAssertTrue(app.staticTexts["已选 1 条"].exists)
        app.buttons["操作"].tap()
        app.buttons["恢复所选"].tap()
        XCTAssertTrue(app.buttons["升级可寻 Pro"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已选 1 条"].exists)
        XCTAssertTrue(card.exists)
        app.buttons["暂时不用"].tap()
        XCTAssertTrue(app.staticTexts["已选 1 条"].exists)
        XCTAssertFalse(app.buttons["升级可寻 Pro"].exists)
        app.buttons["操作"].tap()
        app.buttons["恢复所选"].tap()
        XCTAssertTrue(app.buttons["升级可寻 Pro"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已选 1 条"].exists)
        app.buttons["暂时不用"].tap()
        app.buttons["取消多选"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["100 条收藏"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["library.search"].exists)
        openTrash(app)
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        closeTrash(app)
        let active = app.buttons.containing(.staticText, identifier: "QuotaFixture-001").firstMatch
        XCTAssertTrue(active.waitForExistence(timeout: 5))
        active.tap()
        for _ in 0..<4 where !app.buttons["移入回收站"].isHittable { app.swipeUp() }
        app.buttons["移入回收站"].tap()
        app.buttons["移入回收站"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["99 条收藏"].waitForExistence(timeout: 5))
        openTrash(app)
        chooseMore(app, "多选")
        card.tap()
        app.buttons["操作"].tap()
        app.buttons["恢复所选"].tap()
        XCTAssertTrue(app.staticTexts["已选 0 条"].waitForExistence(timeout: 5))
        XCTAssertFalse(card.exists)
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 5), "Only the newly trashed quota fixture remains in the trash")
        app.buttons["取消多选"].tap()
        closeTrash(app)
        XCTAssertTrue(app.staticTexts["100 条收藏"].waitForExistence(timeout: 5))
        chooseFilter(app, "归档状态", "已归档")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Restoring must preserve the original archive state")
    }

    @MainActor
    func testQuotaUpgradeSheetPreservesDraft() throws {
        // Requires empty-library-quota-fixture.sql on a dedicated simulator only.
        let app = XCUIApplication()
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        let count = app.staticTexts["100 条收藏"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        app.segmentedControls.buttons["文字"].tap()
        let title = app.textFields["标题（选填）"]
        title.tap()
        title.typeText("QuotaBlockedDraft")
        let body = app.textViews["收藏内容"]
        body.tap()
        body.typeText("Keep this unsaved draft")
        app.navigationBars.buttons["保存"].tap()
        let upgrade = app.buttons["升级可寻 Pro"]
        XCTAssertTrue(upgrade.waitForExistence(timeout: 5))
        for _ in 0..<5 where !upgrade.isHittable { app.swipeUp() }
        upgrade.tap()
        XCTAssertTrue(app.navigationBars["可寻 Pro · 永久版"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["恢复购买"].exists)
        app.navigationBars.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForExistence(timeout: 5))
        XCTAssertEqual(body.value as? String, "Keep this unsaved draft")
        XCTAssertEqual(title.value as? String, "QuotaBlockedDraft")
        let later = app.buttons["暂时不用"]
        for _ in 0..<5 where !later.isHittable { app.swipeUp() }
        later.tap()
        XCTAssertFalse(upgrade.exists)
        XCTAssertEqual(body.value as? String, "Keep this unsaved draft")
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
    }

    @MainActor
    func testUnsavedDetailNoteSurvivesBackgroundWithoutCommitting() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        let title = "DraftLifeUI-\(UUID().uuidString.prefix(8))"
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        app.segmentedControls.buttons["文字"].tap()
        app.textFields["标题（选填）"].tap()
        app.textFields["标题（选填）"].typeText(title)
        app.textViews["收藏内容"].tap()
        app.textViews["收藏内容"].typeText("Draft lifecycle fixture")
        app.navigationBars.buttons["保存"].tap()
        let card = app.buttons.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        let note = app.textViews["备注"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("Uncommitted draft note")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(note.value as? String, "Uncommitted draft note")
        XCTAssertEqual(app.textFields["标题"].value as? String, title)
        app.navigationBars.buttons["关闭"].tap()
        XCTAssertTrue(app.staticTexts["有未保存的内容"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["draft.discard"].firstMatch.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertNotEqual(note.value as? String, "Uncommitted draft note", "Closing must not implicitly commit draft edits")
        app.navigationBars.buttons["关闭"].tap()
    }

    @MainActor
    func testEmptyTrashCancelThenConfirm() throws {
        // Dedicated test device only. Never clear a pre-existing trash collection.
        let app = XCUIApplication()
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        XCTAssertTrue(app.textFields["library.search"].exists)
        openTrash(app)
        XCTAssertTrue(app.staticTexts["回收站为空"].waitForExistence(timeout: 5))
        assertEmptyTrashCannotBeCleared(app)
        closeTrash(app)
        let title = "EmptyTrashUI-\(UUID().uuidString.prefix(8))"
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        app.segmentedControls.buttons["文字"].tap()
        app.textFields["标题（选填）"].tap()
        app.textFields["标题（选填）"].typeText(title)
        app.textViews["收藏内容"].tap()
        app.textViews["收藏内容"].typeText("Only this test-created record may be cleared")
        app.navigationBars.buttons["保存"].tap()
        let card = app.buttons.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        for _ in 0..<4 where !app.buttons["移入回收站"].isHittable { app.swipeUp() }
        app.buttons["移入回收站"].tap()
        app.buttons["移入回收站"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForNonExistence(timeout: 5))
        openTrash(app)
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        chooseMore(app, "清空回收站")
        let warning = app.staticTexts["永久删除 1 条收藏及其无引用附件？此操作不可撤销。"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(card.exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["library.search"].exists)
        openTrash(app)
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Cancellation must survive restart")
        chooseMore(app, "清空回收站")
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        app.buttons["永久删除"].tap()
        XCTAssertTrue(app.staticTexts["回收站为空"].waitForExistence(timeout: 5))
        assertEmptyTrashCannotBeCleared(app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["library.search"].exists)
        openTrash(app)
        XCTAssertTrue(app.staticTexts["回收站为空"].waitForExistence(timeout: 5))
        XCTAssertFalse(card.exists)
    }

    @MainActor
    func testSinglePermanentDeleteRequiresConfirmation() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        let title = "PermanentUI-\(UUID().uuidString.prefix(8))"
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        app.segmentedControls.buttons["文字"].tap()
        app.textFields["标题（选填）"].tap()
        app.textFields["标题（选填）"].typeText(title)
        app.textViews["收藏内容"].tap()
        app.textViews["收藏内容"].typeText("仅删除本次新建的验收内容")
        app.navigationBars.buttons["保存"].tap()
        let card = app.buttons.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        for _ in 0..<4 where !app.buttons["移入回收站"].isHittable { app.swipeUp() }
        app.buttons["移入回收站"].tap()
        let trashConfirmation = app.buttons["移入回收站"].firstMatch
        XCTAssertTrue(trashConfirmation.waitForExistence(timeout: 5))
        trashConfirmation.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.textFields["library.search"].exists)
        openTrash(app)
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        let delete = app.buttons["永久删除"]
        for _ in 0..<4 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        XCTAssertTrue(app.alerts["永久删除这条收藏？"].waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["恢复收藏"].exists)
        app.navigationBars.buttons["关闭"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Cancel must preserve the trashed record")
        card.tap()
        for _ in 0..<4 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        app.alerts.buttons["永久删除"].tap()
        XCTAssertTrue(app.staticTexts["回收站"].waitForExistence(timeout: 5))
        XCTAssertFalse(card.exists)
        app.terminate()
        app.launch()
        app.textFields["library.search"].tap()
        app.textFields["library.search"].tap()
        app.textFields["library.search"].typeText(title + "\n")
        XCTAssertTrue(app.staticTexts["0 条收藏"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testBatchArchiveTrashAndRestore() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        let prefix = "BatchUI-\(UUID().uuidString.prefix(8))"
        let titles = [prefix + "-A", prefix + "-B"]
        for title in titles {
            app.buttons["添加内容"].tap()
            app.buttons["capture.text"].tap()
            app.segmentedControls.buttons["文字"].tap()
            app.textFields["标题（选填）"].tap()
            app.textFields["标题（选填）"].typeText(title)
            app.textViews["收藏内容"].tap()
            app.textViews["收藏内容"].typeText("批量操作验收 " + title)
            app.navigationBars.buttons["保存"].tap()
            XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 5))
        }
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText(prefix + "\n")
        XCTAssertTrue(app.staticTexts["2 条收藏"].waitForExistence(timeout: 5))
        chooseMore(app, "多选")
        app.buttons["全选当前结果"].tap()
        XCTAssertTrue(app.staticTexts["已选 2 条"].exists)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["2 条收藏"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已选 2 条"].exists, "Foreground reload must preserve selection for unchanged results")
        app.buttons["取消多选"].tap()
        XCTAssertTrue(app.staticTexts["2 条收藏"].exists)
        chooseMore(app, "多选")
        XCTAssertTrue(app.staticTexts["已选 0 条"].exists)
        app.buttons["全选当前结果"].tap()
        app.buttons["操作"].tap()
        app.buttons["星标"].tap()
        XCTAssertTrue(app.staticTexts["已选 0 条"].waitForExistence(timeout: 5))
        app.buttons["全选当前结果"].tap()
        app.buttons["操作"].tap()
        app.buttons["归档"].tap()
        XCTAssertTrue(app.staticTexts["已选 0 条"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["2 条收藏"].exists, "Global search retains both archived items")
        app.buttons["全选当前结果"].tap()
        app.buttons["操作"].tap()
        app.buttons["移入回收站"].tap()
        let confirm = app.buttons["移入回收站"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["0 条收藏"].waitForExistence(timeout: 5))
        app.buttons["library.cancelSearch"].tap()
        openTrash(app)
        chooseMore(app, "多选")
        for title in titles {
            let card = app.buttons.containing(.staticText, identifier: title).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            for _ in 0..<4 where !card.isHittable { app.swipeUp() }
            card.tap()
        }
        for _ in 0..<4 where !app.buttons["操作"].isHittable { app.swipeDown() }
        XCTAssertTrue(app.staticTexts["已选 2 条"].exists)
        app.buttons["操作"].tap()
        app.buttons["恢复所选"].tap()
        XCTAssertTrue(app.staticTexts["已选 0 条"].waitForExistence(timeout: 5))
        closeTrash(app)
        chooseFilter(app, "归档状态", "已归档")
        for title in titles {
            let card = app.buttons.containing(.staticText, identifier: title).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            for _ in 0..<4 where !card.isHittable { app.swipeUp() }
            card.tap()
            for _ in 0..<4 where !app.buttons["取消星标"].isHittable { app.swipeUp() }
            XCTAssertTrue(app.buttons["取消星标"].exists)
            XCTAssertTrue(app.buttons["取消归档"].exists)
            app.navigationBars.buttons["关闭"].tap()
        }
        chooseMore(app, "多选")
        for title in titles {
            let card = app.buttons.containing(.staticText, identifier: title).firstMatch
            for _ in 0..<8 where !card.isHittable || card.frame.maxY > visibleLibraryContentBottom(in: app) { app.swipeUp() }
            card.tap()
        }
        for _ in 0..<8 where !app.buttons["操作"].isHittable { app.swipeDown() }
        XCTAssertTrue(app.staticTexts["已选 2 条"].exists)
        app.buttons["操作"].tap()
        app.buttons["取消归档"].tap()
        for title in titles {
            XCTAssertTrue(app.buttons.containing(.staticText, identifier: title).firstMatch.waitForNonExistence(timeout: 5),
                          "Moved records must leave the archived filter")
        }
        app.terminate()
        app.launch()
        // Select the unarchived filter explicitly; the default library includes archives.
        XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 5))
        app.buttons["quick.unarchived"].tap()
        XCTAssertTrue(app.buttons["quick.unarchived"].isSelected)
        for title in titles {
            let card = app.buttons.containing(.staticText, identifier: title).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            for _ in 0..<8 where !card.isHittable || card.frame.maxY > visibleLibraryContentBottom(in: app) { app.swipeUp() }
            card.tap()
            XCTAssertEqual(app.staticTexts["detail.body"].label, "批量操作验收 " + title)
            for _ in 0..<8 where !app.buttons["取消星标"].isHittable { app.swipeUp() }
            XCTAssertTrue(app.buttons["取消星标"].exists)
            XCTAssertTrue(app.buttons["归档"].exists)
            XCTAssertFalse(app.buttons["取消归档"].exists)
            app.navigationBars.buttons["关闭"].tap()
        }
    }

    @MainActor
    func testFaultRecoveryFromSystemBackup() throws {
        // Run only on the isolated fault-injected clone with the exported backup fixture.
        let app = XCUIApplication()
        app.launch()
        if app.alerts.buttons["知道了"].waitForExistence(timeout: 3) { app.alerts.buttons["知道了"].tap() }
        XCTAssertTrue(app.staticTexts["暂时无法读取资料"].waitForExistence(timeout: 10))
        app.buttons["library.settings"].tap()
        app.buttons["数据与备份"].tap()
        let recovery = app.buttons["从备份进行故障恢复"]
        for _ in 0..<6 where !recovery.isHittable { app.swipeUp() }
        XCTAssertTrue(recovery.isHittable)
        recovery.tap()
        XCTAssertTrue(app.buttons["选择备份并恢复"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        recovery.tap()
        app.buttons["选择备份并恢复"].tap()
        // The clone inherits stale Recent Documents bookmarks. Browse the actual local file.
        let browse = app.tabBars.buttons["浏览"]
        if browse.waitForExistence(timeout: 5) { browse.tap() }
        let local = app.cells.matching(NSPredicate(format: "label CONTAINS '我的 iPhone' OR label CONTAINS 'On My iPhone'")).firstMatch
        if local.waitForExistence(timeout: 3) { local.tap() }
        let backup = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "BackupUITest-7D3EB20C.zip")).firstMatch
        XCTAssertTrue(backup.waitForExistence(timeout: 10), app.debugDescription)
        backup.tap()
        let report = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "故障恢复完成：已载入备份中的")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 30), app.debugDescription)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Fault recovery from real system file picker"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["暂时无法读取资料"].exists)
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText("KEXUN SEARCH 2026\n")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '识别文本' AND label CONTAINS 'KEXUN'")).firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func testSystemPDFImportSearchAndPreview() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        app.buttons["添加内容"].tap()
        app.buttons["导入文件 / PDF"].tap()
        let file = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "KexunPDF-UI-41")).firstMatch
        if !file.waitForExistence(timeout: 3) {
            let browse = app.buttons["浏览"]
            if browse.exists { browse.tap() }
            let local = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "我的iPhone")).firstMatch
            if local.waitForExistence(timeout: 3) { local.tap() }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 10), "Requires the isolated native PDF fixture in this dedicated simulator's Files provider")
        file.tap()
        let open = app.buttons["打开"]
        if open.waitForExistence(timeout: 3) { open.tap() }
        XCTAssertTrue(app.staticTexts["本次已导入 1 项，已保存到资料库。"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.navigationBars.buttons["保存"].exists)
        app.buttons["import.done"].tap()
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText("retrieval\n")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS '识别文本' AND label CONTAINS 'KEXUN'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        result.tap()
        XCTAssertTrue(app.staticTexts["searchMatch.status"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["searchMatch.status"].label, "第 1 / 1 处")
        let excerpt = app.staticTexts["searchMatch.excerpt"]
        XCTAssertTrue(excerpt.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(excerpt.label.contains("KEXUN native PDF retrieval"), excerpt.label)

        let locatePDF = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchMatch.pdf.")).firstMatch
        XCTAssertTrue(locatePDF.waitForExistence(timeout: 10), app.debugDescription)
        locatePDF.tap()
        XCTAssertTrue(app.navigationBars["KexunPDF-UI-41.pdf"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["pdfSearchMatch.status"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["pdfSearchMatch.status"].label, "第 1 / 1 处")
        XCTAssertTrue(app.staticTexts["第 1 页"].exists)
        let pdfExcerpt = app.staticTexts["pdfSearchMatch.excerpt"]
        XCTAssertTrue(pdfExcerpt.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(pdfExcerpt.label.contains("KEXUN native PDF retrieval"), pdfExcerpt.label)
        XCTAssertTrue(app.descendants(matching: .any)["pdfSearchMatch.document"].exists)
        let positioned = XCTAttachment(screenshot: app.screenshot())
        positioned.name = "System PDF search positioned retrieval on page 1"
        positioned.lifetime = .keepAlways
        add(positioned)
        app.navigationBars["KexunPDF-UI-41.pdf"].buttons["完成"].tap()

        let previewButton = app.buttons["预览附件"]
        for _ in 0..<8 {
            if previewButton.isHittable { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.78))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.28))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(previewButton.isHittable, app.debugDescription)
        previewButton.tap()
        let close = app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "System imported PDF Quick Look"
        preview.lifetime = .keepAlways
        add(preview)
        close.tap()
        XCTAssertTrue(app.buttons["导出附件"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSystemFileImport() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        app.buttons["添加内容"].tap()
        app.buttons["导入文件 / PDF"].tap()
        let file = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "BackupUITest-7D3EB20C.zip")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "Requires the ZIP produced by the system backup test in this dedicated simulator")
        file.tap()
        let open = app.buttons["打开"]
        if open.waitForExistence(timeout: 3) { open.tap() }
        XCTAssertTrue(app.staticTexts["本次已导入 1 项，已保存到资料库。"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.navigationBars.buttons["保存"].exists)
        app.buttons["import.done"].tap()
        let card = app.buttons.containing(.staticText, identifier: "BackupUITest-7D3EB20C.zip").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.buttons["预览附件"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["导出附件"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "File imported through native document picker"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["预览附件"].tap()
        let preview = XCTAttachment(string: app.debugDescription)
        preview.name = "Native Quick Look file preview"
        preview.lifetime = .keepAlways
        add(preview)
        let closePreview = app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"]
        XCTAssertTrue(closePreview.waitForExistence(timeout: 10))
        closePreview.tap()
        XCTAssertTrue(app.buttons["导出附件"].waitForExistence(timeout: 5))
        app.buttons["导出附件"].tap()
        let exporter = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        XCTAssertTrue(exporter.waitForExistence(timeout: 10))
        exporter.swipeDown()
        XCTAssertTrue(exporter.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已取消导出，原附件仍保留。"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["附件已导出。"].exists)
        let cancelled = XCTAttachment(string: app.debugDescription)
        cancelled.name = "Attachment export cancellation"
        cancelled.lifetime = .keepAlways
        add(cancelled)
        app.buttons["导出附件"].tap()
        let filename = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(filename.waitForExistence(timeout: 10))
        filename.tap()
        filename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        filename.typeText("AttachmentUITest-\(UUID().uuidString.prefix(8)).zip")
        exporter.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["附件已导出。"].waitForExistence(timeout: 10))
        app.buttons["预览附件"].tap()
        XCTAssertTrue(closePreview.waitForExistence(timeout: 10))
        closePreview.tap()
    }

    @MainActor
    func testBackupSystemExportCancellation() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        app.buttons["library.settings"].tap()
        XCTAssertTrue(app.buttons["数据与备份"].waitForExistence(timeout: 5))
        app.buttons["数据与备份"].tap()
        for _ in 0..<5 where !app.buttons["导出备份"].isHittable { app.swipeUp() }
        app.buttons["导出备份"].tap()
        let exporter = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        XCTAssertTrue(exporter.waitForExistence(timeout: 15))
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Backup system file exporter"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        exporter.swipeDown()
        XCTAssertTrue(app.staticTexts["已取消导出，未保存备份文件。"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["备份已导出。"].exists)
        app.buttons["从备份恢复"].tap()
        XCTAssertTrue(exporter.waitForExistence(timeout: 5))
        exporter.swipeDown()
        XCTAssertTrue(app.buttons["从备份恢复"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "恢复完成：")).firstMatch.exists)
        app.buttons["导出备份"].tap()
        let filename = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(filename.waitForExistence(timeout: 15))
        let name = "BackupUITest-\(UUID().uuidString.prefix(8))"
        filename.tap()
        filename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        filename.typeText(name)
        exporter.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["备份已导出。"].waitForExistence(timeout: 15))
        app.buttons["从备份恢复"].tap()
        let backup = app.cells.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        backup.tap()
        let report = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "恢复完成：新增 0 条（其中冲突保留 0 条）")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 15))
        let restored = XCTAttachment(screenshot: app.screenshot())
        restored.name = "System backup export and identical restore report"
        restored.lifetime = .keepAlways
        add(restored)
    }

    @MainActor
    func testPhotosShareBeforeFirstMainAppLaunch() throws {
        // Run only on a newly created simulator with a photo fixture, never on an existing library.
        // Explicitly simctl install the built Kexun.app first, without launching it: XCTest may
        // defer installing the target until app.launch(), which would invalidate this scenario.
        let app = XCUIApplication()
        XCTAssertEqual(app.state, .notRunning)
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.terminate()
        photos.launch()
        if photos.buttons["继续"].waitForExistence(timeout: 5) { photos.buttons["继续"].tap() }
        if photos.buttons["PUOneUpBarButtonItemIdentifierDone"].exists { photos.buttons["PUOneUpBarButtonItemIdentifierDone"].tap() }
        let grid = photos.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(grid.firstMatch.waitForExistence(timeout: 10))
        grid.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(photos.buttons["PUOneUpBarButtonItemIdentifierShare"].waitForExistence(timeout: 5))
        photos.buttons["PUOneUpBarButtonItemIdentifierShare"].tap()
        if !photos.cells["Kexun"].waitForExistence(timeout: 3), photos.cells["更多"].exists {
            photos.cells["更多"].tap()
            let hierarchy = XCTAttachment(string: photos.debugDescription)
            hierarchy.name = "First-install share More list"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(photos.cells["Kexun"].waitForExistence(timeout: 10))
        photos.cells["Kexun"].tap()
        XCTAssertTrue(photos.staticTexts["收下到可寻"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .notRunning)
        photos.scrollViews.buttons["保存"].tap()
        XCTAssertTrue(photos.staticTexts["共 1 项：已保存 1 项，已跳过 0 项，失败 0 项，待保存 0 项。"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .notRunning)
        photos.buttons["完成"].tap()
        app.launch()
        XCTAssertTrue(app.buttons["关闭收集提示"].waitForExistence(timeout: 5), "Main app must still show its first-launch guide")
        app.buttons["关闭收集提示"].tap()
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 10))
        let imported = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "系统分享", "图片")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 10))
        for _ in 0..<5 where imported.frame.maxY > app.frame.maxY - 100 { app.swipeUp() }
        imported.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForExistence(timeout: 5))
        let saved = XCTAttachment(screenshot: app.screenshot())
        saved.name = "First main launch reads extension-created library"
        saved.lifetime = .keepAlways
        add(saved)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testPhotosShareWhileMainAppStopped() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        let countLabel = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "条收藏")).firstMatch
        XCTAssertTrue(countLabel.waitForExistence(timeout: 5))
        let before = try XCTUnwrap(Int(countLabel.label.components(separatedBy: " ")[0]))
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        if photos.buttons["继续"].waitForExistence(timeout: 5) { photos.buttons["继续"].tap() }
        if photos.buttons["PUOneUpBarButtonItemIdentifierDone"].exists { photos.buttons["PUOneUpBarButtonItemIdentifierDone"].tap() }
        let hierarchy = XCTAttachment(string: photos.debugDescription)
        hierarchy.name = "Independent Photos source hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let grid = photos.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(grid.firstMatch.waitForExistence(timeout: 5))
        // Dedicated simulator fixture: last grid image is the generated OCR PNG.
        grid.element(boundBy: grid.count - 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(photos.buttons["PUOneUpBarButtonItemIdentifierShare"].waitForExistence(timeout: 5))
        photos.buttons["PUOneUpBarButtonItemIdentifierShare"].tap()
        XCTAssertTrue(photos.cells["Kexun"].waitForExistence(timeout: 10))
        photos.cells["Kexun"].tap()
        XCTAssertTrue(photos.staticTexts["收下到可寻"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .notRunning)
        let extensionShot = XCTAttachment(screenshot: photos.screenshot())
        extensionShot.name = "Independent share extension before save"
        extensionShot.lifetime = .keepAlways
        add(extensionShot)
        photos.scrollViews.buttons["保存"].tap()
        XCTAssertTrue(photos.staticTexts["共 1 项：已保存 1 项，已跳过 0 项，失败 0 项，待保存 0 项。"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .notRunning, "Extension must not need to launch the main app")
        photos.buttons["完成"].tap()
        app.launch()
        XCTAssertTrue(app.staticTexts["\(before + 1) 条收藏"].waitForExistence(timeout: 10))
        let imported = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "系统分享", "图片")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 10))
        for _ in 0..<5 where imported.frame.maxY > app.frame.maxY - 100 { app.swipeUp() }
        imported.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForExistence(timeout: 5))
        let saved = XCTAttachment(screenshot: app.screenshot())
        saved.name = "Image received from Photos while main app stopped"
        saved.lifetime = .keepAlways
        add(saved)
    }

    @MainActor
    func testSystemShareExtensionLink() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["关闭收集提示"].waitForExistence(timeout: 2) { app.buttons["关闭收集提示"].tap() }
        let title = "ShareTest-\(UUID().uuidString.prefix(8))"
        let url = "https://example.com/\(title)"
        let folder = "分享组-\(UUID().uuidString.prefix(8))"

        func hideKeyboard() {
            let button = app.buttons["keyboard.dismiss"].firstMatch
            if button.exists && button.isHittable { button.tap() }
        }
        func reveal(_ element: XCUIElement, in container: XCUIElement? = nil) {
            hideKeyboard()
            let surface: XCUIElement = container ?? app
            for _ in 0..<12 {
                if element.isHittable && element.frame.midY < app.frame.maxY - 90 { break }
                surface.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.78))
                    .press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.28)))
            }
            XCTAssertTrue(element.isHittable)
        }
        func chooseExistingFolder() {
            let picker = app.buttons["share.folder"]
            reveal(picker)
            XCTAssertEqual(picker.label, "收藏夹：未分组", "Each new share session must start ungrouped")
            picker.tap()
            let panel = app.scrollViews["share.folderChoices"]
            XCTAssertTrue(panel.waitForExistence(timeout: 10))
            let choice = panel.buttons.matching(NSPredicate(format: "label == %@", folder)).firstMatch
            for _ in 0..<20 where !choice.exists {
                let next = panel.buttons["下一页收藏夹"]
                guard next.exists else { break }
                reveal(next, in: panel)
                next.tap()
                XCTAssertTrue(panel.waitForExistence(timeout: 5))
            }
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            reveal(choice, in: panel)
            XCTAssertGreaterThanOrEqual(choice.frame.height, 44)
            XCTAssertEqual(choice.label, folder)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Share existing folder is readable and reachable"
            shot.lifetime = .keepAlways
            add(shot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Share folder selection accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            choice.tap()
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertEqual(picker.label, "收藏夹：\(folder)")
        }
        func searchUniqueLink(expectedCount: Int) {
            XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 10))
            app.textFields["library.search"].tap()
            let search = app.textFields["library.search"]
            search.tap()
            search.typeText(title + "\n")
            hideKeyboard()
            XCTAssertTrue(app.staticTexts["\(expectedCount) 条收藏"].waitForExistence(timeout: 10))
        }

        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        app.textFields["标题（选填）"].tap()
        app.textFields["标题（选填）"].typeText(title)
        app.textViews["收藏内容"].tap()
        app.textViews["收藏内容"].typeText(url)
        hideKeyboard()
        app.navigationBars["新收藏"].buttons["保存"].tap()
        let card = app.buttons.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        reveal(card)
        card.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForExistence(timeout: 5))
        let groupField = app.textFields["detail.folder"]
        reveal(groupField)
        groupField.tap()
        groupField.typeText(folder)
        hideKeyboard()
        app.navigationBars["收藏详情"].buttons["保存"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        reveal(card)
        card.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForExistence(timeout: 5))
        let share = app.buttons["分享链接"]
        reveal(share)
        share.tap()
        openKexunShare(app)
        chooseExistingFolder()
        reveal(app.buttons["share.save"])
        app.buttons["share.save"].tap()
        XCTAssertTrue(app.alerts.buttons["查看已有收藏"].waitForExistence(timeout: 10))
        app.alerts.buttons["查看已有收藏"].tap()
        let existing = app.staticTexts["share.existingContent"]
        XCTAssertTrue(existing.waitForExistence(timeout: 5))
        XCTAssertTrue(existing.label.contains(url))
        XCTAssertTrue(existing.label.contains("原始内容："))
        XCTAssertTrue(existing.label.contains("收藏夹：\(folder)"))
        let back = app.buttons["返回重复提醒"]
        reveal(back, in: app.scrollViews["share.linkChoices"])
        back.tap()
        XCTAssertTrue(app.alerts.buttons["跳过"].waitForExistence(timeout: 5))
        app.alerts.buttons["跳过"].tap()
        let skippedSummary = "共 1 项：已保存 0 项，已跳过 1 项，失败 0 项，待保存 0 项。"
        XCTAssertTrue(app.staticTexts[skippedSummary].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["share.status"].label, skippedSummary)
        XCTAssertFalse(app.buttons["重试未保存项目"].exists, "An explicit skip completes the share input without a retry loop")
        let skippedShot = XCTAttachment(screenshot: app.screenshot())
        skippedShot.name = "Duplicate explicitly skipped with zero failures and no retry"
        skippedShot.lifetime = .keepAlways
        add(skippedShot)
        reveal(app.buttons["share.close"])
        app.buttons["share.close"].tap()
        app.terminate()
        app.launch()
        searchUniqueLink(expectedCount: 1)

        // Saving another copy requires a new share session, not retrying a skip.
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        reveal(card)
        card.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForExistence(timeout: 5))
        reveal(share)
        share.tap()
        openKexunShare(app)
        chooseExistingFolder()
        reveal(app.buttons["share.save"])
        app.buttons["share.save"].tap()
        XCTAssertTrue(app.alerts.buttons["仍然保存"].waitForExistence(timeout: 10))
        app.alerts.buttons["仍然保存"].tap()
        let savedSummary = "共 1 项：已保存 1 项，已跳过 0 项，失败 0 项，待保存 0 项。"
        XCTAssertTrue(app.staticTexts[savedSummary].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["share.status"].label, savedSummary)
        XCTAssertFalse(app.buttons["重试未保存项目"].exists)
        reveal(app.buttons["share.close"])
        app.buttons["share.close"].tap()
        app.terminate()
        app.launch()
        searchUniqueLink(expectedCount: 2)
        let results = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", title, "链接"))
        XCTAssertEqual(results.count, 2)
        for index in 0..<2 {
            let result = results.element(boundBy: index)
            reveal(result)
            result.tap()
            XCTAssertTrue(app.navigationBars["收藏详情"].waitForExistence(timeout: 5))
            reveal(groupField)
            XCTAssertEqual(groupField.value as? String, folder, "Both the original and the new shared copy must retain the chosen folder after relaunch")
            app.navigationBars["收藏详情"].buttons["关闭"].tap()
            XCTAssertTrue(app.staticTexts["2 条收藏"].waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testTextCaptureArchiveSearchAndRelaunch() throws {
        let app = XCUIApplication()
        app.launch()
        let guide = app.buttons["关闭收集提示"]
        if guide.waitForExistence(timeout: 3) { guide.tap() }
        app.buttons["quick.unarchived"].tap()
        XCTAssertTrue(app.buttons["quick.unarchived"].isSelected)
        let title = "UITest-\(UUID().uuidString.prefix(8))"
        let body = "离线保存后仍可找回 \(title)"
        XCTAssertTrue(app.buttons["添加内容"].waitForExistence(timeout: 10))
        app.buttons["添加内容"].tap()
        app.buttons["capture.link"].tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["文字"].tap()
        app.textFields["标题（选填）"].tap()
        app.textFields["标题（选填）"].typeText(title)
        app.textViews["收藏内容"].tap()
        app.textViews["收藏内容"].typeText(body)
        app.navigationBars.buttons["保存"].tap()
        let card = app.buttons.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[body].exists)
        for _ in 0..<4 where !app.buttons["归档"].isHittable { app.swipeUp() }
        app.buttons["归档"].tap()
        XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 5))
        XCTAssertFalse(card.exists, "Archived content must leave the unarchived filter")
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(title + "\n")
        XCTAssertFalse(card.exists, "Search initially retains the unarchived scope")
        app.buttons["在全部收藏中搜索"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Global search must include archived content")
        app.buttons["library.cancelSearch"].tap()
        XCTAssertTrue(app.buttons["quick.unarchived"].isSelected, "Cancelling search restores its original scope")
        XCTAssertFalse(card.exists)
        search.tap()
        search.typeText(title + "\n")
        app.buttons["在全部收藏中搜索"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Archived content found by global search"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 10))
        app.textFields["library.search"].tap()
        search.tap()
        search.typeText(title + "\n")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Saved content must survive process restart")
        card.tap()
        XCTAssertTrue(app.staticTexts[body].waitForExistence(timeout: 5))
        for _ in 0..<4 where !app.buttons["detail.star"].isHittable { app.swipeUp() }
        app.buttons["detail.star"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        for _ in 0..<8 where !app.buttons["detail.star"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["取消星标"].waitForExistence(timeout: 5))
        for _ in 0..<4 where !app.buttons["移入回收站"].isHittable { app.swipeUp() }
        app.buttons["移入回收站"].tap()
        let confirmDelete = app.buttons["移入回收站"].firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertFalse(card.exists, "Trashed content must not appear in global search")
        app.buttons["library.cancelSearch"].tap()
        openTrash(app)
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        for _ in 0..<4 where !app.buttons["恢复收藏"].isHittable { app.swipeUp() }
        app.buttons["恢复收藏"].tap()
        XCTAssertTrue(app.staticTexts["回收站"].waitForExistence(timeout: 5))
        let trashContents = app.scrollViews.containing(.staticText, identifier: "回收站").firstMatch
        let trashedCard = trashContents.buttons.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(trashedCard.waitForNonExistence(timeout: 5), "Restored content must leave the trash even when its main-library row exists behind the sheet")
        closeTrash(app)
        chooseFilter(app, "归档状态", "已归档")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Restore must preserve archive status")
        card.tap()
        for _ in 0..<8 where !app.buttons["detail.star"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["取消星标"].waitForExistence(timeout: 5), "Restore must preserve starred status")
        for _ in 0..<5 where !app.buttons["取消归档"].exists || !app.buttons["取消归档"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["取消归档"].exists)
        // Keep the uniquely named record as evidence in this dedicated simulator.
    }

    @MainActor
    func testSystemPhotoImportAndOCRSearch() throws {
        // Prepare only the dedicated simulator using simctl addmedia with the
        // generated ExtractionChecks OCR fixture; never use a personal device.
        let app = XCUIApplication()
        app.launch()
        let guide = app.buttons["关闭收集提示"]
        if guide.waitForExistence(timeout: 3) { guide.tap() }
        app.buttons["添加内容"].tap()
        app.buttons["选择照片"].tap()
        let cell = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        guard cell.waitForExistence(timeout: 10) else {
            XCTFail("Photo picker did not expose fixture cells: \(app.debugDescription)")
            return
        }
        let pickerScreenshot = XCTAttachment(screenshot: app.screenshot())
        pickerScreenshot.name = "System photo picker before selection"
        pickerScreenshot.lifetime = .keepAlways
        add(pickerScreenshot)
        // The remote Photos picker exposes grid frames but can report no AX hit
        // point. Tap the observed image's center, not an unrelated form cell.
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let addButton = app.buttons.matching(NSPredicate(format: "label == '完成' OR label == 'Done' OR label == 'Add' OR label == '添加'")).firstMatch
        guard addButton.waitForExistence(timeout: 5) else {
            XCTFail("Photo confirmation not found: \(app.debugDescription)")
            return
        }
        addButton.tap()
        let saved = app.staticTexts["本次已导入 1 项，已保存到资料库。"]
        XCTAssertTrue(saved.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.navigationBars.buttons["保存"].exists)
        let resultScreenshot = XCTAttachment(screenshot: app.screenshot())
        resultScreenshot.name = "Photo import completed with dedicated Done and View Saved controls"
        resultScreenshot.lifetime = .keepAlways
        add(resultScreenshot)
        // Exact saved ID routing avoids matching an older photo or punctuation in a card label.
        app.buttons["import.viewSaved"].tap()
        let uniqueTitle = "PhotoOCR-\(UUID().uuidString.prefix(8))"
        let title = app.textFields["标题"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 100))
        title.typeText(uniqueTitle)
        app.navigationBars.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForNonExistence(timeout: 5))
        app.textFields["library.search"].tap()
        let search = app.textFields["library.search"]
        search.tap()
        search.typeText(uniqueTitle + " KEXUN SEARCH 2026\n")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS '识别文本' AND label CONTAINS 'KEXUN'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "Imported image OCR must be searchable")
        result.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '收藏' AND label CONTAINS 'KEXUN'")).firstMatch.waitForExistence(timeout: 10))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Imported photo and local Chinese English OCR"
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
