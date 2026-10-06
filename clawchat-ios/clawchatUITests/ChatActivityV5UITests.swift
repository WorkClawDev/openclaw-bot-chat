import XCTest

final class ChatActivityV5UITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch() async throws -> XCUIApplication {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18082/fixture/reset")!)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "chatActivityV5", "-uiTestAuthenticated", "-settings.languageMode", "chinese", "-openclawApiBaseURL", "http://127.0.0.1:18082"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.activity.approve"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor func testResumeAndApproveInsideConversation() async throws {
        let app = try await launch()
        let resume = app.buttons["chat.activity.resume"]
        XCTAssertFalse(resume.isEnabled)
        let input = app.textFields["chat.activity.input"]
        input.tap()
        input.typeText("For our weekly meeting")
        resume.tap()
        let disappear = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: input)
        await fulfillment(of: [disappear], timeout: 10)
        attach(app, name: "V5-inline-confirmation")
        app.buttons["chat.activity.approve"].tap()
        let approved = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["chat.activity.approve"])
        await fulfillment(of: [approved], timeout: 10)
        XCTAssertTrue(app.collectionViews["chatRoomV2.collectionView"].exists)
    }

    @MainActor func testDenyAndStopInsideConversation() async throws {
        let app = try await launch()
        app.buttons["chat.activity.deny"].tap()
        let denied = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["chat.activity.approve"])
        await fulfillment(of: [denied], timeout: 10)
        app.buttons["chat.activity.stop"].tap()
        let stopped = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["chat.activity.stop"])
        await fulfillment(of: [stopped], timeout: 10)
        XCTAssertTrue(app.descendants(matching: .any)["chat.composer.input"].firstMatch.exists)
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
