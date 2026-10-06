import XCTest
import UIKit

final class LivePhoneAuthV5UITests: XCTestCase {
    @MainActor func testPhoneRegistrationWrongCodeSingleUseAndSessionRestore() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let base = try XCTUnwrap(env["V5_TEST_BASE_URL"])
        try XCTSkipUnless(["127.0.0.1", "localhost"].contains(URL(string: base)?.host ?? ""), "Disposable local accounts only")
        let phone = try XCTUnwrap(env["V5_TEST_PHONE"])
        let code = try XCTUnwrap(env["V5_TEST_PHONE_CODE"])
        XCTAssertEqual(code.count, 6)
        let (configuration, configStatus) = try await request(base, "/api/v1/auth/phone/config")
        XCTAssertEqual(configStatus, 200)
        XCTAssertEqual(configuration["enabled"] as? Bool, true)
        XCTAssertEqual(configuration["captcha_provider"] as? String, "mock")

        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetState", "-settings.languageMode", "english", "-settings.appearanceMode", "light", "-openclawApiBaseURL", base]
        app.launch()
        openPhoneForm(app, phone: phone)
        app.buttons["Get code"].tap()
        let countdown = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+s")).firstMatch
        XCTAssertTrue(countdown.waitForExistence(timeout: 10))
        XCTAssertFalse(countdown.isEnabled)
        attach("V5-live-phone-code-requested")

        replaceCode(app, code == "000000" ? "111111" : "000000")
        app.buttons["Log in / Register"].tap()
        let invalid = app.staticTexts["invalid or expired verification code"]
        XCTAssertTrue(invalid.waitForExistence(timeout: 15))
        XCTAssertEqual(app.textFields["Phone number"].value as? String, phone)
        XCTAssertTrue(app.buttons["Log in / Register"].isEnabled)
        attach("V5-live-phone-wrong-code")

        replaceCode(app, code)
        app.buttons["Log in / Register"].tap()
        openSettings(app)
        let identity = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "@u" + phone.suffix(4))).firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 15))
        let username = String(identity.label.dropFirst())
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        attach("V5-live-phone-created")

        // The first successful login above must come from the real UI, not API seeding.
        let (_, replayStatus) = try await request(base, "/api/v1/auth/phone/login", body: ["phone": phone, "code": code])
        XCTAssertEqual(replayStatus, 401, "A consumed code must not authenticate again")
        try await requestFreshCode(base, phone: phone)
        let (readback, readbackStatus) = try await request(base, "/api/v1/auth/phone/login", body: ["phone": phone, "code": code])
        XCTAssertEqual(readbackStatus, 200, "The form already created this account; readback must not create it")
        let user = try XCTUnwrap(readback["user"] as? [String: Any])
        let userID = try XCTUnwrap(user["id"] as? String)
        XCTAssertEqual(user["username"] as? String, username)
        XCTAssertEqual(user["phone"] as? String, "+86" + phone)
        XCTAssertEqual(user["email"] as? String, "")
        XCTAssertEqual(user["has_password"] as? Bool, false)
        let tokens = try XCTUnwrap(readback["tokens"] as? [String: Any])
        let token = try XCTUnwrap(tokens["access_token"] as? String)

        app.terminate()
        app.launchArguments.removeAll { $0 == "-uiTestResetState" }
        app.launch()
        openSettings(app)
        XCTAssertTrue(app.staticTexts["@" + username].waitForExistence(timeout: 15))
        attach("V5-live-phone-cold-restored")
        logout(app)

        openPhoneForm(app, phone: phone)
        replaceCode(app, code)
        app.buttons["Log in / Register"].tap()
        XCTAssertTrue(invalid.waitForExistence(timeout: 15))
        attach("V5-live-phone-consumed-code")
        app.buttons["Get code"].tap()
        XCTAssertTrue(countdown.waitForExistence(timeout: 10))
        XCTAssertFalse(countdown.isEnabled)
        app.buttons["Log in / Register"].tap()
        openSettings(app)
        XCTAssertTrue(app.staticTexts["@" + username].waitForExistence(timeout: 15))
        let (profile, profileStatus) = try await request(base, "/api/v1/auth/me", token: token)
        XCTAssertEqual(profileStatus, 200)
        XCTAssertEqual(profile["id"] as? String, userID)
        XCTAssertEqual(profile["username"] as? String, username)
        XCTAssertEqual(profile["phone"] as? String, "+86" + phone)
        XCTAssertEqual(profile["has_password"] as? Bool, false)
        attach("V5-live-phone-existing-account")
    }

    @MainActor private func openPhoneForm(_ app: XCUIApplication, phone: String) {
        let mode = app.buttons["Use phone code"]
        XCTAssertTrue(mode.waitForExistence(timeout: 15))
        mode.tap()
        let field = app.textFields["Phone number"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText(phone)
    }

    @MainActor private func replaceCode(_ app: XCUIApplication, _ code: String) {
        let field = app.textFields["Code"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let current = field.value as? String ?? ""
        let length = current == "Code" ? 0 : current.count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length) + code)
    }

    @MainActor private func openSettings(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(app.buttons["ipad.section.home"].waitForExistence(timeout: 20))
            app.buttons["ipad.section.settings"].tap()
        } else {
            XCTAssertTrue(app.buttons["home.account"].waitForExistence(timeout: 20))
            app.buttons["home.account"].tap(); app.buttons["home.menu.settings"].tap()
        }
        let method = app.descendants(matching: .any).matching(identifier: "settings.passwordless-sign-in").firstMatch
        XCTAssertTrue(method.waitForExistence(timeout: 15))
        XCTAssertTrue(method.label.contains("Phone verification"))
        XCTAssertFalse(app.buttons["settings.password-row"].exists)
        XCTAssertFalse(app.secureTextFields["settings.current-password-field"].exists)
    }

    @MainActor private func logout(_ app: XCUIApplication) {
        let button = app.buttons["settings.logout-button"]
        let scroll = app.scrollViews.containing(.button, identifier: "settings.logout-button").firstMatch
        for _ in 0..<8 where !button.isHittable { scroll.swipeUp() }
        XCTAssertTrue(button.isHittable)
        button.tap()
        XCTAssertTrue(app.textFields["Email or username"].waitForExistence(timeout: 15))
    }

    private func requestFreshCode(_ base: String, phone: String) async throws {
        for _ in 0..<15 {
            let (_, status) = try await request(base, "/api/v1/auth/phone/code", body: ["phone": phone, "captcha_token": "mock", "purpose": "login"])
            if status == 200 { return }
            XCTAssertEqual(status, 429)
            try await Task.sleep(for: .seconds(1))
        }
        XCTFail("Local phone code cooldown did not clear")
    }

    private func request(_ base: String, _ path: String, token: String? = nil, body: [String: String]? = nil) async throws -> ([String: Any], Int) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: base + path)))
        request.timeoutInterval = 20
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        return (envelope["data"] as? [String: Any] ?? [:], (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    @MainActor private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
