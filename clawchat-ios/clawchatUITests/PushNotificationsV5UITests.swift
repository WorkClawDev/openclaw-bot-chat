import XCTest
import UIKit

final class PushNotificationsV5UITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testUnconfiguredServerDoesNotClaimNotificationsAreOn() async throws {
        let app = try await launch(available: false)
        let toggle = app.switches["settings.push.toggle"]
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        XCTAssertTrue(app.staticTexts["Push is not configured on this server"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists, "An unconfigured server must not ask for system notification permission")
        let retry = app.buttons["settings.push.retry"]
        XCTAssertTrue(retry.exists)
        attach("V5-push-unconfigured")
        retry.tap()
        XCTAssertTrue(app.staticTexts["Push is not configured on this server"].waitForExistence(timeout: 10))
        toggle.tap()
        let off = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [off], timeout: 5), .completed)
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18085/fixture/events")!)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(response["data"] as? [[String: String]])
        XCTAssertGreaterThanOrEqual(events.filter { $0["type"] == "status" }.count, 2)
        XCTAssertFalse(events.contains { $0["type"] == "PUT" }, "No device should be registered with an unavailable provider")
        attach("V5-push-off")
    }

    @MainActor func testPermissionDeniedKeepsNotificationsOff() async throws {
        let app = try await launch(available: true)
        app.switches["settings.push.toggle"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Run this case with notification permission reset")
        attach("V5-push-permission")
        permissionButton(in: alert, allow: false).tap()
        XCTAssertTrue(app.staticTexts["Allow notifications in system Settings"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.switches["settings.push.toggle"].value as? String, "0")
        XCTAssertTrue(app.buttons["Open system Settings"].exists)
        attach("V5-push-denied")
    }

    // Run separately after reinstalling the test app. The local test driver
    // injects a notification with simctl after the fixture readiness handshake.
    // This verifies native delivery callbacks/navigation, not Apple's provider.
    @MainActor func testNotificationTapOpensAboveSettingsAndReturnsToSettings() async throws {
        let app = try await launch(available: true)
        try await tapInjectedNotification(in: app)
        XCTAssertTrue(app.collectionViews["chatRoomV2.collectionView"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Notification Assistant"].exists)
        let message = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Notification history loaded.")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists, "The opened chat must load without an error alert")
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18085/fixture/events")!)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(response["data"] as? [[String: String]])
        let authorized = try XCTUnwrap(events.firstIndex { $0["type"] == "authorize-history" })
        let resolved = try XCTUnwrap(events.firstIndex { $0["type"] == "resolve-bot" })
        let loaded = try XCTUnwrap(events.firstIndex { $0["type"] == "load-history" })
        XCTAssertLessThan(authorized, resolved)
        XCTAssertLessThan(resolved, loaded)
        attach("V5-push-open-chat")
        app.buttons["Back"].tap()
        assertSettingsVisible(in: app)
        XCTAssertTrue(app.switches["settings.push.toggle"].exists)
        attach("V5-push-return-settings")
    }

    @MainActor func testGroupNotificationLoadsGroupAndReturnsToSettings() async throws {
        let app = try await launch(available: true, scenario: "group")
        try await tapInjectedNotification(in: app)
        XCTAssertTrue(app.collectionViews["chatRoomV2.collectionView"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Notification Group"].exists)
        XCTAssertTrue(historyMessage(in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let events = try await fixtureEvents()
        let authorized = try XCTUnwrap(events.firstIndex { $0["type"] == "authorize-history" })
        let resolved = try XCTUnwrap(events.firstIndex { $0["type"] == "resolve-group" })
        let loaded = try XCTUnwrap(events.firstIndex { $0["type"] == "load-history" })
        XCTAssertLessThan(authorized, resolved)
        XCTAssertLessThan(resolved, loaded)
        attach("V5-push-group")
        app.buttons["Back"].tap()
        assertSettingsVisible(in: app)
    }

    @MainActor func testRevokedNotificationShowsErrorAboveSettings() async throws {
        let app = try await launch(available: true, scenario: "forbidden")
        try await tapInjectedNotification(in: app)
        let alert = app.alerts["Could not open chat"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        XCTAssertTrue(alert.staticTexts["This chat could not be opened. Check your connection and access, then try again."].exists)
        XCTAssertFalse(app.collectionViews["chatRoomV2.collectionView"].exists)
        let events = try await fixtureEvents()
        XCTAssertTrue(events.contains { $0["type"] == "authorize-history" })
        XCTAssertFalse(events.contains { $0["type"] == "resolve-bot" || $0["type"] == "load-history" })
        attach("V5-push-revoked")
        alert.buttons["OK"].tap()
        assertSettingsVisible(in: app)
        XCTAssertTrue(app.switches["settings.push.toggle"].exists)
        attach("V5-push-revoked-return-settings")
    }

    @MainActor func testNotificationColdLaunchRestoresAccountAndOpensChat() async throws {
        let app = try await launch(available: true, scenario: "cold")
        try await tapInjectedNotification(in: app, cold: true)
        XCTAssertTrue(app.collectionViews["chatRoomV2.collectionView"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Notification Assistant"].exists)
        XCTAssertTrue(historyMessage(in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        // Cold launch comes from SpringBoard without -uiTestMode. The regular
        // home shell restores the cached account and persisted local endpoint.
        XCTAssertFalse(app.staticTexts["chatRoomV2.diagnostics"].exists)
        attach("V5-push-cold-chat")
        app.buttons["Back"].tap()
        let homeID = UIDevice.current.userInterfaceIdiom == .pad ? "ipad.section.home" : "home.account"
        XCTAssertTrue(app.buttons[homeID].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["home.utility.close"].exists)
        attach("V5-push-cold-home")
    }

    @MainActor func testMediaNotificationsLoadImageAudioAndFile() async throws {
        let app = try await launch(available: true, scenario: "media")
        try grantNotificationPermission(in: app)
        let collection = app.collectionViews["chatRoomV2.collectionView"]
        for (index, kind) in ["image", "audio", "file"].enumerated() {
            try await openInjectedNotification(app, index: String(index + 1), media: kind)
            XCTAssertTrue(collection.waitForExistence(timeout: 15))
            let suffix = "-" + kind + "-0"
            let block = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", suffix)).firstMatch
            for _ in 0..<5 where !block.isHittable { collection.swipeDown() }
            XCTAssertTrue(block.waitForExistence(timeout: 10))
            XCTAssertTrue(block.isHittable)
            block.tap()
            if kind == "image" {
                XCTAssertTrue(app.buttons["chat.imagePreview.close"].waitForExistence(timeout: 15))
                attach("V5-push-media-image")
                app.buttons["chat.imagePreview.close"].tap()
            } else if kind == "audio" {
                let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: block)
                XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 15), .completed)
                attach("V5-push-media-audio")
                block.tap()
            } else {
                let body = app.textViews["chat.file.text"]
                XCTAssertTrue(body.waitForExistence(timeout: 15))
                XCTAssertTrue((body.value as? String)?.contains("V5 NOTIFICATION FILE BODY VERIFIED") == true)
                attach("V5-push-media-file")
                app.buttons["Done"].tap()
            }
            XCTAssertFalse(app.alerts.firstMatch.exists)
            app.buttons["Back"].tap()
            assertSettingsVisible(in: app)
        }
        let events = try await fixtureEvents()
        for kind in ["image", "audio", "file"] {
            XCTAssertTrue(events.contains { $0["type"] == "download-" + kind }, "The real media bytes must be requested")
        }
        XCTAssertGreaterThanOrEqual(events.filter { $0["type"] == "authorize-history" }.count, 3)
    }

    @MainActor func testOldAccountNotificationIsIgnoredAfterSwitchAndCurrentAccountOpens() async throws {
        let app = try await launch(available: true, scenario: "account")
        try grantNotificationPermission(in: app)
        let logout = app.buttons["settings.logout-button"]
        let scroll = app.scrollViews.containing(.button, identifier: "settings.logout-button").firstMatch
        for _ in 0..<8 where !logout.isHittable { scroll.swipeUp() }
        XCTAssertTrue(logout.isHittable); logout.tap()
        let username = app.textFields["Email or username"]
        XCTAssertTrue(username.waitForExistence(timeout: 15))
        username.tap(); username.typeText("notification-b")
        app.secureTextFields["Password"].tap(); app.secureTextFields["Password"].typeText("fixture-password")
        app.buttons["Login"].tap()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        XCTAssertTrue(app.buttons[isPad ? "ipad.section.home" : "home.account"].waitForExistence(timeout: 15))
        if isPad { app.buttons["ipad.section.settings"].tap() }
        else { app.buttons["home.account"].tap(); app.buttons["home.menu.settings"].tap() }
        XCTAssertTrue(app.staticTexts["Notification Account B"].firstMatch.waitForExistence(timeout: 10))
        let settingsScroll = app.scrollViews.containing(.button, identifier: "settings.logout-button").firstMatch
        let pushToggle = app.switches["settings.push.toggle"]
        for _ in 0..<7 {
            if pushToggle.isHittable && pushToggle.frame.midY < app.frame.height * 0.65 { break }
            settingsScroll.swipeUp()
        }
        XCTAssertTrue(pushToggle.isHittable)
        // Notification preference belongs to the signed-in account. Logging
        // out intentionally disables it; enable B explicitly before checking
        // both the delayed A notification and B's own delivery.
        XCTAssertEqual(pushToggle.value as? String, "0")
        pushToggle.tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: pushToggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        try await openInjectedNotification(app, index: "old", recipient: "a")
        assertSettingsVisible(in: app)
        let unexpectedChat = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: app.collectionViews["chatRoomV2.collectionView"])
        unexpectedChat.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedChat], timeout: 2), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let oldEvents = try await fixtureEvents()
        XCTAssertFalse(oldEvents.contains { ["authorize-history", "resolve-bot", "load-history"].contains($0["type"] ?? "") }, "A notification for the old account must be rejected before fetching any conversation")
        attach("V5-push-account-old-ignored")
        try await openInjectedNotification(app, index: "current", recipient: "b")
        XCTAssertTrue(app.collectionViews["chatRoomV2.collectionView"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Notification Assistant B"].exists)
        let body = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Account B notification history.")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        let events = try await fixtureEvents()
        let accountB = "00000000-0000-0000-0000-000000000222"
        for type in ["authorize-history", "resolve-bot", "load-history"] {
            XCTAssertTrue(events.contains { $0["type"] == type && $0["account"] == accountB })
        }
        attach("V5-push-account-current-chat")
        app.buttons["Back"].tap(); assertSettingsVisible(in: app)
    }

    @MainActor private func grantNotificationPermission(in app: XCUIApplication) throws {
        app.switches["settings.push.toggle"].tap()
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        permissionButton(in: alert, allow: true).tap()
    }

    @MainActor private func openInjectedNotification(_ app: XCUIApplication, index: String, recipient: String = "a", media: String = "") async throws {
        XCUIDevice.shared.press(.home)
        guard app.wait(for: .runningBackground, timeout: 10) else {
            XCTFail("The app must be in the background before injecting a system notification")
            throw NotificationTestError.notInBackground
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18085/fixture/ready-for-push")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["index": index, "recipient": recipient, "media": media])
        _ = try await URLSession.shared.data(for: request)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notification = springboard.staticTexts["V5 notification acceptance " + index]
        if !notification.waitForExistence(timeout: 8) {
            // A second notification need not produce a second banner. Open
            // the real Notification Center and tap the delivered notification.
            let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.005))
            let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.65))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        guard notification.waitForExistence(timeout: 20) else {
            attach("V5-push-missing-" + index)
            XCTFail("The injected notification must be visible in the system UI")
            throw NotificationTestError.notificationNotVisible
        }
        notification.tap()
    }

    private enum NotificationTestError: Error { case notInBackground, notificationNotVisible }

    @MainActor private func assertSettingsVisible(in app: XCUIApplication) {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let control = app.buttons[isPad ? "ipad.section.settings" : "home.utility.close"]
        let usable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [usable], timeout: 10), .completed)
        if isPad { XCTAssertTrue(control.isSelected) }
        XCTAssertTrue(app.switches["settings.push.toggle"].exists)
    }

    @MainActor private func historyMessage(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Notification history loaded.")).firstMatch
    }

    @MainActor private func fixtureEvents() async throws -> [[String: String]] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18085/fixture/events")!)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(response["data"] as? [[String: String]])
    }

    @MainActor private func tapInjectedNotification(in app: XCUIApplication, cold: Bool = false) async throws {
        app.switches["settings.push.toggle"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Run this case after reinstalling the test app")
        permissionButton(in: alert, allow: true).tap()
        if cold {
            app.terminate()
            XCTAssertEqual(app.state, .notRunning)
        } else {
            XCUIDevice.shared.press(.home)
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18085/fixture/ready-for-push")!)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
        let notification = springboard.staticTexts["V5 notification acceptance"]
        XCTAssertTrue(notification.waitForExistence(timeout: 30), "Expected native notification injected by the local test driver")
        notification.tap()
    }

    @MainActor private func launch(available: Bool, scenario: String = "settings") async throws -> XCUIApplication {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18085/fixture/reset")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["available": available, "scenario": scenario])
        _ = try await URLSession.shared.data(for: request)
        let app = XCUIApplication()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        app.launchArguments = ["-uiTestMode", isPad ? "ipadWorkspaceSettings" : "homeV5", "-uiTestAuthenticated", "-uiTestResetPush", "-settings.languageMode", "english", "-settings.appearanceMode", "light", "-openclawApiBaseURL", "http://127.0.0.1:18085"]
        if scenario == "cold" { app.launchArguments.append("-uiTestPersistEndpoint") }
        if scenario == "account" { app.launchArguments.removeFirst(2) }
        app.launch()
        if isPad {
            if scenario == "account" {
                XCTAssertTrue(app.buttons["ipad.section.home"].waitForExistence(timeout: 15))
                app.buttons["ipad.section.settings"].tap()
            }
            XCTAssertTrue(app.buttons["ipad.section.settings"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["ipad.section.settings"].isSelected)
        } else {
            XCTAssertTrue(app.buttons["home.account"].waitForExistence(timeout: 15))
            app.buttons["home.account"].tap()
            app.buttons["home.menu.settings"].tap()
        }
        let toggle = app.switches["settings.push.toggle"]
        for _ in 0..<7 {
            if toggle.exists && toggle.isHittable && toggle.frame.midY < app.frame.height * 0.65 { break }
            app.scrollViews.containing(.button, identifier: "settings.logout-button").firstMatch.swipeUp()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.isHittable)
        XCTAssertLessThan(toggle.frame.midY, app.frame.height * 0.65, "Keep the notification status and retry action visible in captures")
        return app
    }

    @MainActor private func permissionButton(in alert: XCUIElement, allow: Bool) -> XCUIElement {
        // App language and SpringBoard language are independent. Match the
        // observed system labels exactly so Allow cannot accidentally match Deny.
        let labels = allow ? ["Allow", "允许"] : ["Don’t Allow", "Don't Allow", "不允许"]
        let button = alert.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        return button
    }

    @MainActor private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
