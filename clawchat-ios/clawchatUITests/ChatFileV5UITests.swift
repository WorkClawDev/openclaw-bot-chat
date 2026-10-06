import XCTest

final class ChatFileV5UITests: XCTestCase {
    @MainActor func testUploadedFileOpensSystemPreviewAndCanBeShared() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "chatFilesV5", "-uiTestAuthenticated", "-settings.languageMode", "english", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-openclawApiBaseURL", "http://127.0.0.1:18082"]
        app.launch()
        let file = app.buttons["v5-file-file-0"]
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        let before = file.frame
        file.tap()
        XCTAssertTrue(app.buttons["chat.file.share"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.textViews["chat.file.text"].waitForExistence(timeout: 10))
        XCTAssertTrue((app.textViews["chat.file.text"].value as? String)?.contains("# Actual UI fixture") == true)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "V5-file-preview"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["chat.file.share"].tap()
        let copy = app.collectionViews["activityCollectionView"].cells["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "The system share sheet must offer a file action")
        let share = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        share.name = "V5-file-share-sheet"
        share.lifetime = .keepAlways
        add(share)
        copy.tap()
        XCTAssertTrue(app.buttons["chat.file.share"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        XCTAssertEqual(file.frame.minY, before.minY, accuracy: 1)
    }
}
