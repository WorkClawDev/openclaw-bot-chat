import XCTest

final class AudioPlaybackV5UITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "chatRoomV2", "-fixture", "audioPlayback", "-settings.languageMode", "english", "-settings.appearanceMode", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["v5-audio-long-a-audio-0"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor func testPlaybackSwitchStopAndCellReuse() {
        let app = launch()
        let first = app.buttons["v5-audio-long-a-audio-0"]
        let second = app.buttons["v5-audio-long-b-audio-0"]
        let anchor = app.collectionViews.cells["chatRoomV2.message.v5-audio-anchor"]
        let originalFrame = anchor.frame
        let firstFrame = first.frame
        let secondFrame = second.frame
        first.tap()
        state(first, "Playing")
        stable(anchor, originalFrame)
        stable(first, firstFrame)
        second.tap()
        state(second, "Playing")
        state(first, "Not playing")
        stable(anchor, originalFrame)
        stable(second, secondFrame)
        first.tap()
        state(first, "Playing")
        state(second, "Not playing")
        let collection = app.collectionViews["chatRoomV2.collectionView"]
        collection.swipeDown()
        collection.swipeDown()
        XCTAssertFalse(first.isHittable, "Playback row must leave the viewport to exercise cell reuse")
        for _ in 0..<8 where !anchor.isHittable { collection.swipeUp() }
        collection.swipeUp() // Settle at the same bottom edge as the initial state.
        state(first, "Playing")
        stable(anchor, originalFrame)
        stable(first, firstFrame)
        attach("V5-audio-playing-after-scroll")
        first.tap()
        state(first, "Not playing")
        stable(anchor, originalFrame)
        stable(first, firstFrame)
    }

    @MainActor func testCompletionAndInvalidDataPreserveGeometry() {
        let app = launch()
        let short = app.buttons["v5-audio-short-audio-0"]
        let invalid = app.buttons["v5-audio-invalid-audio-0"]
        let anchor = app.collectionViews.cells["chatRoomV2.message.v5-audio-anchor"]
        let originalFrame = anchor.frame
        let shortFrame = short.frame
        let invalidFrame = invalid.frame
        short.tap()
        state(short, "Playing")
        state(short, "Not playing", timeout: 15)
        stable(anchor, originalFrame)
        stable(short, shortFrame)
        invalid.tap()
        state(invalid, "Unable to play")
        XCTAssertEqual(invalid.label, "Retry voice message")
        stable(anchor, originalFrame)
        stable(invalid, invalidFrame)
        invalid.tap()
        state(invalid, "Unable to play")
        stable(anchor, originalFrame)
        stable(invalid, invalidFrame)
        attach("V5-audio-invalid-file")
        // A failed message must not prevent another valid voice from playing.
        let first = app.buttons["v5-audio-long-a-audio-0"]
        first.tap()
        state(first, "Playing")
        stable(anchor, originalFrame)
        first.tap()
        state(first, "Not playing")
    }

    @MainActor private func state(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 10) {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: timeout), .completed, "Expected \(value), got \(String(describing: element.value))")
    }

    @MainActor private func stable(_ element: XCUIElement, _ frame: CGRect) {
        XCTAssertEqual(element.frame.minY, frame.minY, accuracy: 1, "Audio state must not shift message position")
        XCTAssertEqual(element.frame.height, frame.height, accuracy: 1, "Audio state must not resize a message")
        XCTAssertEqual(element.frame.width, frame.width, accuracy: 1)
    }

    @MainActor private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
