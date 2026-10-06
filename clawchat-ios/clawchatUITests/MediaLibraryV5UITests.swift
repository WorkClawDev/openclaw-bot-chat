import XCTest

final class MediaLibraryV5UITests: XCTestCase {
    @MainActor func testPreviewSavesImageToSystemPhotoLibrary() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "chatRoomV2ImagePreview", "-settings.languageMode", "english"]
        app.launch()
        let image = app.buttons["v2-live-image-message-image-0"]
        XCTAssertTrue(image.waitForExistence(timeout: 15))
        let before = image.frame
        image.tap()
        XCTAssertTrue(app.buttons["chat.imagePreview.save"].waitForExistence(timeout: 10))
        app.buttons["chat.imagePreview.save"].tap()
        XCTAssertTrue(app.alerts["Saved"].waitForExistence(timeout: 20), "Run with Photos add-only permission granted on the dedicated simulator")
        XCTAssertTrue(app.alerts["Saved"].staticTexts["Image saved to Photos."].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "V5-image-saved-to-photos"
        shot.lifetime = .keepAlways
        add(shot)
        app.alerts["Saved"].buttons["OK"].tap()
        app.buttons["chat.imagePreview.close"].tap()
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        XCTAssertEqual(image.frame.minY, before.minY, accuracy: 1)
    }
}
