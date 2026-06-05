//
//  clawchatUITests.swift
//  clawchatUITests
//
//  Created by Changer Ding on 2026/4/12.
//

import XCTest

final class clawchatUITests: XCTestCase {

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
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testChatRoomScrollsThroughLongFixture() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-test-chat-room")
        app.launch()

        XCTAssertTrue(waitForVisibleText("Chat Scroll Test", in: app, timeout: 5))
        XCTAssertTrue(waitForAnyVisibleText(["Scroll probe 179", "Scroll probe 180"], in: app, timeout: 8))

        XCTAssertTrue(dragUntilText(
            "Image probe 176",
            in: app,
            from: CGVector(dx: 0.5, dy: 0.34),
            to: CGVector(dx: 0.5, dy: 0.86),
            maxAttempts: 4
        ))
        XCTAssertTrue(dragUntilText(
            "Scroll probe 131",
            in: app,
            from: CGVector(dx: 0.5, dy: 0.34),
            to: CGVector(dx: 0.5, dy: 0.86),
            maxAttempts: 32
        ))
        XCTAssertTrue(isVisibleText(containing: "Chat Scroll Test", in: app))

        slowDrag(in: app, from: CGVector(dx: 0.5, dy: 0.42), to: CGVector(dx: 0.5, dy: 0.58), count: 1)
        XCTAssertTrue(waitForVisibleText("Scroll probe 131", in: app, timeout: 2))

        XCTAssertTrue(dragUntilText(
            "Image probe 126",
            in: app,
            from: CGVector(dx: 0.5, dy: 0.34),
            to: CGVector(dx: 0.5, dy: 0.86),
            maxAttempts: 24
        ), app.debugDescription)

        XCTAssertTrue(dragUntilText(
            "Scroll probe 179",
            in: app,
            from: CGVector(dx: 0.5, dy: 0.82),
            to: CGVector(dx: 0.5, dy: 0.28),
            maxAttempts: 36
        ))
        XCTAssertTrue(isVisibleText(containing: "Chat Scroll Test", in: app))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    private func waitForVisibleText(_ value: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isVisibleText(containing: value, in: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return false
    }

    @MainActor
    private func waitForAnyVisibleText(_ values: [String], in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if values.contains(where: { isVisibleText(containing: $0, in: app) }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return false
    }

    @MainActor
    private func isVisibleText(containing value: String, in app: XCUIApplication) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", value)
        let candidates = app.descendants(matching: .any)
            .matching(predicate)
            .allElementsBoundByIndex
        let window = app.windows.firstMatch
        let visibleFrame = window.exists ? window.frame : app.frame

        return candidates.contains { element in
            guard element.exists else { return false }
            let frame = element.frame
            guard !frame.isEmpty else { return false }
            return visibleFrame.intersects(frame)
        }
    }

    @MainActor
    private func drag(in app: XCUIApplication, from start: CGVector, to end: CGVector, count: Int) {
        let startCoordinate = app.coordinate(withNormalizedOffset: start)
        let endCoordinate = app.coordinate(withNormalizedOffset: end)

        for _ in 0..<count {
            startCoordinate.press(forDuration: 0.05, thenDragTo: endCoordinate)
        }
    }

    @MainActor
    private func slowDrag(in app: XCUIApplication, from start: CGVector, to end: CGVector, count: Int) {
        let startCoordinate = app.coordinate(withNormalizedOffset: start)
        let endCoordinate = app.coordinate(withNormalizedOffset: end)

        for _ in 0..<count {
            startCoordinate.press(
                forDuration: 0.15,
                thenDragTo: endCoordinate,
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
        }
    }

    @MainActor
    private func dragUntilText(
        _ value: String,
        in app: XCUIApplication,
        from start: CGVector,
        to end: CGVector,
        maxAttempts: Int
    ) -> Bool {
        if isVisibleText(containing: value, in: app) {
            return true
        }

        for _ in 0..<maxAttempts {
            drag(in: app, from: start, to: end, count: 1)
            if waitForVisibleText(value, in: app, timeout: 0.3) {
                return true
            }
        }

        return false
    }
}
