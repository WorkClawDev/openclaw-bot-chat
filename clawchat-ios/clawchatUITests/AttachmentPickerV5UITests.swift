import XCTest

final class AttachmentPickerV5UITests: XCTestCase {
    @MainActor func testSelectedPhotoPreviewCanBeCancelled() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "chatFilesV5", "-uiTestAuthenticated", "-settings.languageMode", "english", "-openclawApiBaseURL", "http://127.0.0.1:18082"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.attachments"].waitForExistence(timeout: 15))
        app.buttons["chat.attachments"].tap()
        app.buttons["Photo"].tap()
        // The system picker exposes photos as images on iOS 26, not collection cells.
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 30), "Seed a photo into the dedicated simulator with simctl addmedia")
        let picker = XCTAttachment(string: app.debugDescription)
        picker.name = "V5-photo-grid-accessibility"
        picker.lifetime = .keepAlways
        add(picker)
        // Photos exposes virtual image elements without an XCTest hit point.
        // Tap the visible image's observed frame rather than a fixed screen coordinate.
        XCTAssertFalse(photo.frame.isEmpty)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.images["chat.photo.preview"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["chat.photo.send"].isEnabled)
        let original = app.buttons["chat.photo.original"]
        XCTAssertEqual(original.value as? String, "Compressed")
        original.tap()
        XCTAssertEqual(original.value as? String, "Original")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "V5-selected-photo-preview"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["chat.photo.cancel"].tap()
        XCTAssertTrue(app.buttons["v5-file-file-0"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    @MainActor func testPhotoAndFilePickersCancelWithoutChangingChat() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "chatFilesV5", "-uiTestAuthenticated", "-settings.languageMode", "english", "-openclawApiBaseURL", "http://127.0.0.1:18082"]
        app.launch()
        let file = app.buttons["v5-file-file-0"]
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        let before = file.frame
        for kind in ["Photo", "File"] {
            app.buttons["chat.attachments"].tap()
            app.buttons[kind == "File" ? "chat.file.attach" : "Photo"].tap()
            let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消", "Close", "关闭"])).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 15))
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "V5-\(kind)-picker"
            shot.lifetime = .keepAlways
            add(shot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "V5-\(kind)-picker-accessibility"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            cancel.tap()
            XCTAssertTrue(file.waitForExistence(timeout: 5))
            XCTAssertFalse(app.alerts.firstMatch.exists)
            XCTAssertEqual(file.frame.minY, before.minY, accuracy: 1)
        }
    }
}
