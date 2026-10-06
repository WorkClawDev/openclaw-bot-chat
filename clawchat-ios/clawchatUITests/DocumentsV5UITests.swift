import XCTest

final class DocumentsV5UITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testChatDocumentCardOpensDetailAndContinuesEditing() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18082/api/v1/documents")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["title": "V5 linked document", "body": "Document opened from the chat card."])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let document = try XCTUnwrap(envelope["data"] as? [String: Any])
        let id = try XCTUnwrap(document["id"] as? String)

        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "chatFilesV5", "-uiTestAuthenticated", "-uiTestDocumentID", id, "-settings.languageMode", "english", "-openclawApiBaseURL", "http://127.0.0.1:18082"]
        app.launch()
        let card = app.buttons["v5-document-document-0.open"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        let before = card.frame
        card.tap()
        XCTAssertTrue(app.staticTexts["Document opened from the chat card."].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Edit document"].exists)
        let detail = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        detail.name = "V5-document-from-chat"
        detail.lifetime = .keepAlways
        add(detail)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(card.frame.minY, before.minY, accuracy: 1)
        app.buttons["v5-document-document-0.continue"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let input = app.descendants(matching: .any)["chat.composer.input"].firstMatch
        XCTAssertTrue(app.staticTexts["chat.document.context.title"].exists)
        XCTAssertFalse((input.value as? String ?? "").lowercased().contains(id.lowercased()))
        input.typeText("Make the introduction shorter.")
        let composer = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        composer.name = "V5-document-continue-in-chat"
        composer.lifetime = .keepAlways
        add(composer)
        let beforeRemovingReference = card.frame
        app.buttons["chat.document.context.remove"].tap()
        XCTAssertFalse(app.staticTexts["chat.document.context.title"].exists)
        XCTAssertEqual(input.value as? String, "Make the introduction shorter.")
        XCTAssertEqual(card.frame.minY, beforeRemovingReference.minY, accuracy: 1)
    }

    @MainActor func testCreateEditSearchAndCopyDocument() async throws {
        var reset = URLRequest(url: URL(string: "http://127.0.0.1:18082/fixture/reset")!)
        reset.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: reset)

        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetState", "-uiTestAuthenticated", "-settings.languageMode", "english", "-openclawApiBaseURL", "http://127.0.0.1:18082"]
        app.launch()
        XCTAssertTrue(app.buttons["home.account"].waitForExistence(timeout: 15))
        app.buttons["home.account"].tap()
        app.buttons["home.menu.documents"].tap()
        app.buttons["New document"].tap()
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        focus(title, in: app)
        title.typeText("V5 document acceptance")
        let editor = app.textViews.firstMatch
        focus(editor, in: app)
        editor.typeText("# Verified content\n\nOriginal document body.")
        app.buttons["Create"].tap()

        let row = app.staticTexts["V5 document acceptance"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let edit = app.buttons["Edit document"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let body = app.textViews.firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        focus(body, in: app)
        body.typeText("\n\nSecond revision saved from iOS.")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Second revision saved from iOS.")).firstMatch.waitForExistence(timeout: 5))
        for (action, confirmation) in [("Copy Markdown", "Markdown copied."), ("Copy edit prompt", "Edit prompt copied.")] {
            app.buttons["Document actions"].tap()
            XCTAssertFalse(app.buttons["PDF export coming soon"].exists)
            app.buttons[action].tap()
            XCTAssertTrue(app.alerts.staticTexts[confirmation].waitForExistence(timeout: 5))
            app.alerts.buttons["OK"].tap()
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "V5-document-edited"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Back"].tap()
        app.buttons["Search documents"].tap()
        let search = app.textFields["Search documents"]
        focus(search, in: app)
        search.typeText("no-matching-document")
        XCTAssertTrue(app.staticTexts["No matching documents"].waitForExistence(timeout: 5))
    }

    @MainActor private func focus(_ field: XCUIElement, in app: XCUIApplication) {
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 15) { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15))
    }
}
