import XCTest

final class KexunEditingFeatureTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureCancelKeepsOrDiscardsDirtyDraftAndEmptyCancelClosesDirectly() throws {
        let app = launchApp()
        let marker = "CaptureDraft-\(UUID().uuidString.prefix(8))"

        openTextCapture(in: app)
        let title = app.textFields["标题（选填）"]
        reveal(title, in: app)
        title.tap()
        title.typeText(marker)
        let body = app.textViews["收藏内容"]
        reveal(body, in: app)
        body.tap()
        body.typeText("尚未保存的正文 \(marker)")
        app.buttons["keyboard.dismiss"].tap()

        dragSheetDown(in: app)
        XCTAssertTrue(app.navigationBars["新收藏"].exists, "A dirty capture must reject interactive dismissal")
        XCTAssertEqual(body.value as? String, "尚未保存的正文 \(marker)")

        app.navigationBars["新收藏"].buttons["取消"].tap()
        assertDraftDialog(in: app)
        capture("Dirty capture cancellation choices", app: app)
        app.buttons["draft.continue"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, marker)
        XCTAssertEqual(body.value as? String, "尚未保存的正文 \(marker)")

        app.navigationBars["新收藏"].buttons["取消"].tap()
        assertDraftDialog(in: app)
        app.buttons["draft.discard"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForNonExistence(timeout: 5))

        app.buttons["添加内容"].tap()
        app.buttons["capture.text"].tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForExistence(timeout: 5))
        app.navigationBars["新收藏"].buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["有未保存的内容"].exists, "An empty capture must close without asking")

        search(marker, in: app)
        XCTAssertTrue(app.staticTexts["0 条收藏"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testTextBodyDraftSavesAndRemainsSearchableAfterRelaunch() throws {
        let app = launchApp()
        let marker = "BodyEdit-\(UUID().uuidString.prefix(8))"
        let originalBody = "原始正文 \(marker)"
        let finalToken = "EDITED-\(UUID().uuidString.prefix(8))"
        let finalBody = "完成编辑后的正文 \(finalToken)\n第二行也必须持久化"

        createTextRecord(title: marker, body: originalBody, in: app)
        search(marker, in: app)
        openRecord(containing: marker, in: app)
        assertDetailBody(originalBody, in: app)

        let editBody = app.buttons["detail.editBody"]
        reveal(editBody, in: app)
        editBody.tap()
        let editor = app.textViews["正文"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(in: editor, with: finalBody)
        // The inline completion row can sit underneath the keyboard accessory even when XCTest reports it hittable.
        app.buttons["keyboard.dismiss"].tap()
        let finishBodyEditing = app.buttons["完成正文编辑"]
        reveal(finishBodyEditing, in: app)
        finishBodyEditing.tap()
        let finishedState = XCTAttachment(string: app.debugDescription)
        finishedState.name = "Accessibility after finishing body editing"
        finishedState.lifetime = .keepAlways
        add(finishedState)
        capture("Body editor immediately after finishing", app: app)
        XCTAssertTrue(app.buttons["detail.editBody"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), app.debugDescription)
        assertDetailBody(finalBody, in: app,
                         message: "Finishing inline editing should update only the draft presentation")

        app.navigationBars["收藏详情"].buttons["关闭"].tap()
        assertDraftDialog(in: app)
        app.buttons["draft.continue"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForExistence(timeout: 5))
        assertDetailBody(finalBody, in: app)
        capture("Edited body retained after choosing continue", app: app)

        app.navigationBars["收藏详情"].buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForNonExistence(timeout: 5))
        search(finalToken, in: app)
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 5), app.debugDescription)
        openRecord(containing: marker, in: app)
        assertDetailBody(finalBody, in: app)
        let status = app.descendants(matching: .any)["searchMatch.status"]
        reveal(status, in: app)
        XCTAssertTrue(status.label.contains("1"), status.label)
        XCTAssertTrue(app.buttons["searchMatch.previous"].exists)
        XCTAssertTrue(app.buttons["searchMatch.next"].exists)
        capture("Saved body opened at its global search match", app: app)
        app.navigationBars["收藏详情"].buttons["关闭"].tap()

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["添加内容"].waitForExistence(timeout: 10))
        search(finalToken, in: app)
        XCTAssertTrue(app.staticTexts["1 条收藏"].waitForExistence(timeout: 5), app.debugDescription)
        openRecord(containing: marker, in: app)
        assertDetailBody(finalBody, in: app)
    }

    @MainActor
    func testDirtyDetailStarCanSaveAtomicallyAndCloseCanDiscard() throws {
        let app = launchApp()
        let marker = "AtomicDraft-\(UUID().uuidString.prefix(8))"
        let originalBody = "用于详情原子保存的正文 \(marker)"
        let savedTitle = marker + "-SAVED"
        let savedNote = "与星标一起保存的备注 \(marker)"

        createTextRecord(title: marker, body: originalBody, in: app)
        search(marker, in: app)
        openRecord(containing: marker, in: app)

        let title = app.textFields["标题"]
        replaceText(in: title, with: savedTitle)
        let note = app.textViews["备注"]
        reveal(note, in: app)
        note.tap()
        note.typeText(savedNote)
        app.buttons["keyboard.dismiss"].tap()

        let star = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "星标", "quick.starred"
        )).firstMatch
        reveal(star, in: app)
        star.tap()
        assertDraftDialog(in: app)
        capture("Dirty detail action waits for an explicit draft choice", app: app)
        app.buttons["draft.save"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForNonExistence(timeout: 5))

        search(marker, in: app)
        openRecord(containing: savedTitle, in: app)
        XCTAssertEqual(app.textFields["标题"].value as? String, savedTitle)
        let persistedNote = app.textViews["备注"]
        reveal(persistedNote, in: app)
        XCTAssertEqual(persistedNote.value as? String, savedNote)
        let unstar = app.buttons["取消星标"]
        reveal(unstar, in: app)
        XCTAssertTrue(unstar.exists, "The action and draft must commit together")

        let discardTitle = app.textFields["标题"]
        reveal(discardTitle, in: app, upFirst: false)
        replaceText(in: discardTitle, with: marker + "-DISCARDED")
        reveal(persistedNote, in: app)
        replaceText(in: persistedNote, with: "这段备注应被放弃")
        app.buttons["keyboard.dismiss"].tap()
        app.navigationBars["收藏详情"].buttons["关闭"].tap()
        assertDraftDialog(in: app)
        app.buttons["draft.discard"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForNonExistence(timeout: 5))

        search(marker, in: app)
        openRecord(containing: savedTitle, in: app)
        XCTAssertEqual(app.textFields["标题"].value as? String, savedTitle)
        let reloadedNote = app.textViews["备注"]
        reveal(reloadedNote, in: app)
        XCTAssertEqual(reloadedNote.value as? String, savedNote)
        reveal(app.buttons["取消星标"], in: app)
        XCTAssertTrue(app.buttons["取消星标"].exists)
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let guide = app.buttons["关闭收集提示"]
        if guide.waitForExistence(timeout: 3) { guide.tap() }
        XCTAssertTrue(app.buttons["添加内容"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["library.folders"].exists, "资料库 should be the default destination")
        return app
    }

    @MainActor
    private func openTextCapture(in app: XCUIApplication) {
        app.buttons["添加内容"].tap()
        app.buttons["capture.text"].tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForExistence(timeout: 5), app.debugDescription)
        let textKind = app.segmentedControls.buttons["文字"]
        reveal(textKind, in: app)
        textKind.tap()
    }

    @MainActor
    private func createTextRecord(title: String, body: String, in app: XCUIApplication) {
        openTextCapture(in: app)
        let titleField = app.textFields["标题（选填）"]
        reveal(titleField, in: app)
        titleField.tap()
        titleField.typeText(title)
        let editor = app.textViews["收藏内容"]
        reveal(editor, in: app)
        editor.tap()
        editor.typeText(body)
        app.navigationBars["新收藏"].buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["新收藏"].waitForNonExistence(timeout: 8), app.debugDescription)
    }

    @MainActor
    private func search(_ query: String, in app: XCUIApplication) {
        let field = app.textFields["library.search"]
        reveal(field, in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(in: field, with: query + "\n")
    }

    @MainActor
    private func openRecord(containing title: String, in app: XCUIApplication) {
        let record = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "record.", title
        )).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 8), app.debugDescription)
        reveal(record, in: app)
        record.tap()
        XCTAssertTrue(app.navigationBars["收藏详情"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func replaceText(in element: XCUIElement, with replacement: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let tapOffset = element.elementType == .textView
            ? CGVector(dx: 0.95, dy: 0.9)
            : CGVector(dx: 0.95, dy: 0.5)
        element.coordinate(withNormalizedOffset: tapOffset).tap()
        let existing = element.value as? String ?? ""
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                count: max(existing.count + 8, 32)))
        element.typeText(replacement)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, maximumSwipes: Int = 10, upFirst: Bool = true) {
        let dismissKeyboard = app.buttons["keyboard.dismiss"]
        if dismissKeyboard.exists && dismissKeyboard.isHittable {
            dismissKeyboard.tap()
        }
        if element.exists && element.isHittable { return }
        for _ in 0..<maximumSwipes {
            dragOuterForm(up: upFirst, in: app)
            if element.exists && element.isHittable { return }
        }
        for _ in 0..<(maximumSwipes * 2) {
            dragOuterForm(up: !upFirst, in: app)
            if element.exists && element.isHittable { return }
        }
        XCTFail("Element was not reachable after bounded outer-form scrolling: \(element)\n\(app.debugDescription)")
    }

    @MainActor
    private func assertDetailBody(_ expected: String, in app: XCUIApplication, message: String = "") {
        let body = app.staticTexts["detail.body"]
        reveal(body, in: app)
        XCTAssertEqual(body.label, expected, message)
    }

    @MainActor
    private func assertDraftDialog(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["有未保存的内容"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["draft.save"].exists)
        XCTAssertTrue(app.buttons["draft.discard"].exists)
        XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 2), app.debugDescription)
    }

    @MainActor
    private func dragOuterForm(up: Bool, in app: XCUIApplication) {
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.28))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.78))
        let start = up ? bottom : top
        let end = up ? top : bottom
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func dragSheetDown(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
