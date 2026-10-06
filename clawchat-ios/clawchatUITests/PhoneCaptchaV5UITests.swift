import XCTest

final class PhoneCaptchaV5UITests: XCTestCase {
    @MainActor func testVerificationCancelExpiryFailureAndSMSRetry() async throws {
        continueAfterFailure = false
        _ = try await fixture("/fixture/reset", body: [:])
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetState", "-settings.languageMode", "english", "-settings.appearanceMode", "light", "-openclawApiBaseURL", "http://127.0.0.1:18086"]
        app.launch()
        let mode = app.buttons["Use phone code"]
        XCTAssertTrue(mode.waitForExistence(timeout: 15))
        mode.tap()
        let phone = app.textFields["Phone number"]
        XCTAssertTrue(phone.waitForExistence(timeout: 10))
        phone.tap(); phone.typeText("13800138000")

        openChallenge(app)
        app.buttons["Cancel"].tap()
        waitForDismissal(app)
        XCTAssertTrue(app.buttons["Get code"].isEnabled)
        XCTAssertEqual(phone.value as? String, "13800138000")
        try await assertAttempts(0)
        attach("V5-phone-verification-cancelled")

        openChallenge(app)
        tapWeb("Verification expires", app)
        waitForDismissal(app)
        XCTAssertTrue(app.staticTexts["Verification expired. Request a new code."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Get code"].isEnabled)
        try await assertAttempts(0)
        attach("V5-phone-verification-expired")

        openChallenge(app)
        tapWeb("Verification fails", app)
        waitForDismissal(app)
        XCTAssertTrue(app.staticTexts["Verification did not complete. Please try again."].waitForExistence(timeout: 10))
        try await assertAttempts(0)

        _ = try await fixture("/fixture/mode", body: ["unavailable_page": true])
        app.buttons["Get code"].tap()
        XCTAssertTrue(app.staticTexts["Verification did not complete. Please try again."].waitForExistence(timeout: 10))
        let retryReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["Get code"])
        XCTAssertEqual(XCTWaiter.wait(for: [retryReady], timeout: 10), .completed)
        try await assertAttempts(0)
        attach("V5-phone-verification-load-failed")

        _ = try await fixture("/fixture/mode", body: ["reject_next": true])
        openChallenge(app)
        attach("V5-phone-verification-webview")
        tapWeb("Verify successfully", app)
        waitForDismissal(app)
        XCTAssertTrue(app.staticTexts["SMS temporarily unavailable"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Get code"].isEnabled)
        try await assertAttempts(1)
        attach("V5-phone-sms-retry")

        openChallenge(app)
        tapWeb("Verify successfully", app)
        waitForDismissal(app)
        let cooldown = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+s")).firstMatch
        XCTAssertTrue(cooldown.waitForExistence(timeout: 10))
        XCTAssertFalse(cooldown.isEnabled)
        try await assertAttempts(2)
        let events = try await fixture("/fixture/events")
        XCTAssertEqual(events["challenge_loads"] as? Int, 6, "Every retry must load a fresh challenge")
        attach("V5-phone-sms-code-sent")
    }

    @MainActor private func openChallenge(_ app: XCUIApplication) {
        let button = app.buttons["Get code"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(button.isEnabled)
        button.tap()
        XCTAssertTrue(app.navigationBars["Security verification"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.buttons["Verify successfully"].waitForExistence(timeout: 15))
    }

    @MainActor private func tapWeb(_ title: String, _ app: XCUIApplication) {
        let button = app.webViews.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        if !button.isHittable { app.webViews.firstMatch.swipeUp() }
        button.tap()
    }

    @MainActor private func waitForDismissal(_ app: XCUIApplication) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["Security verification"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)
    }

    @MainActor private func assertAttempts(_ count: Int) async throws {
        let events = try await fixture("/fixture/events")
        let attempts = try XCTUnwrap(events["attempts"] as? [[String: Any]])
        XCTAssertEqual(attempts.count, count)
        for attempt in attempts {
            XCTAssertEqual(attempt["phone"] as? String, "13800138000")
            XCTAssertEqual(attempt["valid_token"] as? Bool, true)
        }
    }

    private func fixture(_ path: String, body: [String: Bool]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18086" + path)!)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(envelope["data"] as? [String: Any])
    }

    @MainActor private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
