import XCTest
import UIKit

final class ActivityV5UITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(expired: Bool = false) async throws -> XCUIApplication {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18082/fixture/reset")!)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
        if expired {
            request.url = URL(string: "http://127.0.0.1:18082/fixture/expired-approval")!
            _ = try await URLSession.shared.data(for: request)
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "assistantConsole", "-uiTestAuthenticated", "-settings.languageMode", "english", "-settings.appearanceMode", "light", "-openclawApiBaseURL", "http://127.0.0.1:18082"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Activity and approvals"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor func testEnglishActivityDetailsDenyAndStop() async throws {
        let app = try await launch()
        XCTAssertFalse(app.navigationBars["个人助手"].exists)
        let title = app.navigationBars["Activity and approvals"]
        XCTAssertLessThan(title.frame.height, 60)
        let deny = app.buttons["Deny"]
        reveal(deny, in: app)
        XCTAssertTrue(app.staticTexts["Awaiting confirmation"].exists)
        XCTAssertFalse(app.staticTexts["Parameter fingerprint: fixture-hash"].isHittable)
        attach("V5-activity-english")
        deny.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: deny)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
        app.swipeDown()
        let stop = app.buttons["Stop"]
        reveal(stop, in: app)
        stop.tap()
        XCTAssertTrue(app.staticTexts["Stopped · 2/80 steps"].waitForExistence(timeout: 10))
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18082/api/v1/agent/runs")!)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let runs = try XCTUnwrap(rows["data"] as? [[String: Any]])
        XCTAssertEqual(runs.first?["status"] as? String, "cancelled")
        app.swipeDown()
        app.swipeDown()
        app.buttons["assistant.management"].tap()
        XCTAssertTrue(app.navigationBars["Memory and schedules"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Memory content"].exists)
        XCTAssertFalse(app.buttons["Confirm and save memory"].isEnabled)
        XCTAssertFalse(app.buttons["Create schedule"].isEnabled)
        XCTAssertFalse(app.textFields["记忆内容"].exists)
        attach("V5-management-english")
    }

    @MainActor func testExpiredApprovalCannotBeSubmitted() async throws {
        let app = try await launch(expired: true)
        let expired = app.staticTexts["Expired"]
        reveal(expired, in: app)
        XCTAssertFalse(app.buttons["Approve this operation"].exists)
        XCTAssertFalse(app.buttons["Deny"].exists)
        attach("V5-activity-expired-approval")
    }

    @MainActor func testScheduleCreatePauseResumeAndCancel() async throws {
        let app = try await launch()
        app.buttons["assistant.management"].tap()
        let title = app.textFields["Title"]
        reveal(title, in: app)
        title.tap()
        title.typeText("Weekly design review")
        let instructions = app.textFields["Instructions"]
        reveal(instructions, in: app)
        instructions.tap()
        instructions.typeText("Review the latest prototype")
        let zone = app.textFields["Time zone"]
        reveal(zone, in: app)
        zone.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        zone.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (zone.value as? String ?? "").count))
        zone.typeText("Invalid/Zone")
        XCTAssertTrue(app.staticTexts["Enter a valid time zone, such as Asia/Shanghai."].exists)
        XCTAssertFalse(app.buttons["Create schedule"].isEnabled)
        zone.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        zone.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (zone.value as? String ?? "").count))
        zone.typeText("UTC")
        let create = app.buttons["Create schedule"]
        reveal(create, in: app)
        create.tap()
        let keyboardClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardClosed], timeout: 10), .completed)
        let pause = app.buttons["Pause"]
        reveal(pause, in: app)
        XCTAssertTrue(app.staticTexts["Weekly design review"].exists)
        pause.tap()
        let resume = app.buttons["Resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10))
        attach("V5-schedule-english")
        app.buttons["Cancel schedule"].tap()
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18082/api/v1/agent/schedules")!)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let schedules = try XCTUnwrap(envelope["data"] as? [[String: Any]])
        XCTAssertEqual(schedules.first?["title"] as? String, "Weekly design review")
        XCTAssertEqual(schedules.first?["timezone"] as? String, "UTC")
        // Wait for the action acknowledgement before server readback.
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["Cancel schedule"])
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 10), .completed)
        let (finalData, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18082/api/v1/agent/schedules")!)
        let finalEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: finalData) as? [String: Any])
        let finalRows = try XCTUnwrap(finalEnvelope["data"] as? [[String: Any]])
        XCTAssertEqual(finalRows.first?["status"] as? String, "cancelled")
    }

    @MainActor func testIPadActivityLanguagesAndOrientations() async throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18082/fixture/reset")!)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
        defer { XCUIDevice.shared.orientation = .portrait }
        for (language, title, operation) in [("english", "Activity and approvals", "Edit file contents"), ("chinese", "执行与授权", "修改文件内容")] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTestMode", "ipadWorkspace", "-uiTestAuthenticated", "-settings.languageMode", language, "-settings.appearanceMode", "light", "-openclawApiBaseURL", "http://127.0.0.1:18082"]
            app.launch()
            XCTAssertTrue(app.buttons["ipad.section.assistant"].waitForExistence(timeout: 15))
            app.buttons["ipad.section.assistant"].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts[operation].waitForExistence(timeout: 10))
            for (orientation, label) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
                XCUIDevice.shared.orientation = orientation
                let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    label == "portrait" ? app.frame.height > app.frame.width : app.frame.width > app.frame.height
                }, object: app)
                XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 10), .completed)
                XCTAssertLessThan(app.navigationBars[title].frame.height, 60)
                XCTAssertTrue(app.frame.contains(app.staticTexts[operation].frame))
                attach("V5-iPad-activity-\(language)-\(label)")
            }
            app.terminate()
        }
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
