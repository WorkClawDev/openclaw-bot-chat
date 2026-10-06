import XCTest

final class HomeV5UITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "homeV5", "-settings.languageMode", "chinese", "-uiTestAuthenticated", "-openclawApiBaseURL", "http://127.0.0.1:18082"]
        app.launch()
        XCTAssertTrue(app.buttons["home.search"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor func testCompactHomeSearchAndChatNavigation() {
        let app = launch()
        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertFalse(app.textFields["home.search.input"].exists)
        attach(app, name: "V5-home")
        app.buttons["home.search"].tap()
        let search = app.textFields["home.search.input"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Code")
        XCTAssertTrue(app.buttons["home.conversation.preview-bot-1"].exists)
        XCTAssertFalse(app.buttons["home.conversation.preview-bot-0"].exists)
        app.buttons["home.search.cancel"].tap()
        app.buttons["home.conversation.preview-bot-0"].tap()
        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chatRoomV2.avatar.")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chatRoomV2.status"].exists)
        XCTAssertTrue(app.buttons["chat.attachments"].exists)
        XCTAssertTrue(app.buttons["chat.send"].exists)
        attach(app, name: "V5-chat")
        app.buttons["chat.attachments"].tap()
        XCTAssertTrue(app.buttons["chat.file.attach"].waitForExistence(timeout: 5))
        attach(app, name: "V5-attachments")
    }

    @MainActor func testAllUtilityDestinationsRemainReachable() {
        let app = launch()
        for destination in ["contacts", "tasks", "documents", "assistant", "settings"] {
            app.buttons["home.account"].tap()
            let item = app.buttons["home.menu.\(destination)"]
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            item.tap()
            XCTAssertTrue(app.buttons["home.utility.close"].waitForExistence(timeout: 10))
            XCTAssertLessThan(app.buttons["home.utility.close"].frame.minY, app.frame.height * 0.25, "Utility headers must remain at the top even with empty content")
            attach(app, name: "V5-\(destination)")
            app.buttons["home.utility.close"].tap()
            XCTAssertTrue(app.buttons["home.search"].waitForExistence(timeout: 5))
        }
    }

    @MainActor func testSearchEmptyStateCanBeCancelled() {
        let app = launch()
        app.buttons["home.search"].tap()
        let search = app.textFields["home.search.input"]
        search.tap()
        search.typeText("no-matching-bot")
        XCTAssertFalse(app.buttons["home.conversation.preview-bot-0"].exists)
        attach(app, name: "V5-search-empty")
        app.buttons["home.search.cancel"].tap()
        XCTAssertTrue(app.buttons["home.conversation.preview-bot-0"].exists)
    }

    @MainActor func testRealKeyboardKeepsLastMessageAboveComposer() {
        let app = launch()
        app.buttons["home.conversation.preview-bot-0"].tap()
        let input = app.descendants(matching: .any)["chat.composer.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        input.typeText("A short follow-up")
        let last = app.collectionViews["chatRoomV2.collectionView"].cells["chatRoomV2.message.v5-preview-4"]
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(last.frame.maxY, input.frame.minY + 1)
        XCTAssertLessThanOrEqual(input.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        attach(app, name: "V5-real-keyboard")
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
