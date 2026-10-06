import XCTest
import UIKit

final class LiveSettingsV5UITests: XCTestCase {
    @MainActor func testRegistrationFormCreatesAccountRestoresSessionAndRejectsDuplicates() async throws {
        continueAfterFailure = false
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["V5_TEST_BASE_URL"])
        try XCTSkipUnless(["127.0.0.1", "localhost"].contains(URL(string: base)?.host ?? ""), "Registration uses disposable local accounts only")
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let username = "v5register\(suffix)"
        let email = username + "@v5.invalid"
        let password = UUID().uuidString + "aA7!"
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetState", "-settings.languageMode", "english", "-settings.appearanceMode", "light", "-openclawApiBaseURL", base]
        app.launch()
        openRegistration(in: app)
        fillRegistration(in: app, username: username, email: email, password: password)
        submitRegistration(in: app)
        assertRegisteredProfile(in: app, username: username)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        attach(app, name: "V5-live-registration-created")

        // The account must have been created by the form, not an API seed.
        let (loginData, loginStatus) = try await request(base: base, path: "/api/v1/auth/login", method: "POST", body: ["username": username, "password": password])
        XCTAssertEqual(loginStatus, 200)
        let payload = try XCTUnwrap(loginData as? [String: Any])
        let user = try XCTUnwrap(payload["user"] as? [String: Any])
        let userID = try XCTUnwrap(user["id"] as? String)
        XCTAssertEqual(user["username"] as? String, username)
        XCTAssertEqual(user["email"] as? String, email)

        app.terminate()
        app.launchArguments.removeAll { $0 == "-uiTestResetState" }
        app.launch()
        assertRegisteredProfile(in: app, username: username)
        attach(app, name: "V5-live-registration-cold-restored")
        let logout = app.buttons["settings.logout-button"]
        scrollTo(logout, app: app); logout.tap()
        XCTAssertTrue(app.textFields["Email or username"].waitForExistence(timeout: 15))

        openRegistration(in: app)
        fillRegistration(in: app, username: username, email: email, password: password)
        submitRegistration(in: app)
        let usernameError = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "username already taken")).firstMatch
        XCTAssertTrue(usernameError.waitForExistence(timeout: 15))
        XCTAssertEqual(app.textFields["Username"].value as? String, username)
        XCTAssertEqual(app.textFields["Email"].value as? String, email)
        XCTAssertTrue(app.buttons["Register"].isEnabled)
        attach(app, name: "V5-live-registration-username-conflict")

        // A different username with the existing email must also be rejected.
        let alternate = "v5other\(suffix)"
        let name = app.textFields["Username"]
        revealRegistrationControl(name, in: app, upward: false)
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: username.count) + alternate)
        submitRegistration(in: app)
        let emailError = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "email already taken")).firstMatch
        XCTAssertTrue(emailError.waitForExistence(timeout: 15))
        XCTAssertEqual(app.textFields["Username"].value as? String, alternate)
        XCTAssertEqual(app.textFields["Email"].value as? String, email)
        XCTAssertTrue(app.buttons["Register"].isEnabled)
        attach(app, name: "V5-live-registration-email-conflict")
        let (_, rejectedStatus) = try await request(base: base, path: "/api/v1/auth/login", method: "POST", body: ["username": alternate, "password": password])
        XCTAssertEqual(rejectedStatus, 401, "Rejected duplicate registration must not leave a usable second account")

        let signIn = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Sign in")).firstMatch
        revealRegistrationControl(signIn, in: app)
        signIn.tap()
        let identifier = app.textFields["Email or username"]
        XCTAssertTrue(identifier.waitForExistence(timeout: 10))
        identifier.tap(); identifier.typeText(email)
        app.secureTextFields["Password"].tap(); app.secureTextFields["Password"].typeText(password)
        app.buttons["Login"].tap()
        assertRegisteredProfile(in: app, username: username)
        let (again, status) = try await request(base: base, path: "/api/v1/auth/login", method: "POST", body: ["email": email, "password": password])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(((again as? [String: Any])?["user"] as? [String: Any])?["id"] as? String, userID)
        attach(app, name: "V5-live-registration-email-login")
    }

    @MainActor private func openRegistration(in app: XCUIApplication) {
        let create = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Create account")).firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        for _ in 0..<6 where !create.isHittable { app.scrollViews.firstMatch.swipeUp() }
        create.tap()
        XCTAssertTrue(app.textFields["Username"].waitForExistence(timeout: 10))
    }

    @MainActor private func fillRegistration(in app: XCUIApplication, username: String, email: String, password: String) {
        for (field, value) in [(app.textFields["Username"], username), (app.textFields["Email"], email)] {
            revealRegistrationControl(field, in: app)
            field.tap(); field.typeText(value)
        }
        let secure = app.secureTextFields["Password"]
        revealRegistrationControl(secure, in: app)
        secure.tap(); secure.typeText(password)
    }

    @MainActor private func submitRegistration(in app: XCUIApplication) {
        let submit = app.buttons["Register"]
        revealRegistrationControl(submit, in: app)
        submit.tap()
    }

    @MainActor private func revealRegistrationControl(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        let scroll = app.scrollViews.containing(.button, identifier: "Register").firstMatch
        for _ in 0..<8 {
            let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
            if element.isHittable && element.frame.minY > 90 && element.frame.maxY < bottom - 8 { return }
            if upward { scroll.swipeUp() } else { scroll.swipeDown() }
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func assertRegisteredProfile(in app: XCUIApplication, username: String) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(app.buttons["ipad.section.home"].waitForExistence(timeout: 20))
            app.buttons["ipad.section.settings"].tap()
        } else {
            XCTAssertTrue(app.buttons["home.account"].waitForExistence(timeout: 20))
            app.buttons["home.account"].tap(); app.buttons["home.menu.settings"].tap()
        }
        XCTAssertTrue(app.staticTexts["@\(username)"].waitForExistence(timeout: 15))
    }

    @MainActor private func registerAccount() async throws -> (base: String, username: String, password: String, token: String) {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["V5_TEST_BASE_URL"] == nil, "Requires the isolated local integration runner")
        let base = try XCTUnwrap(env["V5_TEST_BASE_URL"])
        try XCTSkipUnless(["127.0.0.1", "localhost"].contains(URL(string: base)?.host ?? ""), "Creates a disposable account only on local test services")
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let username = "v5settings\(suffix)"
        let password = UUID().uuidString + "aA7!"
        let (registered, registerStatus) = try await request(base: base, path: "/api/v1/auth/register", method: "POST", body: ["username": username, "email": "\(username)@v5.invalid", "password": password])
        XCTAssertTrue((200...299).contains(registerStatus))
        let registration = try XCTUnwrap(registered as? [String: Any])
        let tokens = try XCTUnwrap(registration["tokens"] as? [String: Any])
        let token = try XCTUnwrap(tokens["access_token"] as? String)
        return (base, username, password, token)
    }

    @MainActor func testAvatarAndProfilePersistThroughRealServices() async throws {
        let (base, username, password, token) = try await registerAccount()
        let app = XCUIApplication()
        login(app, base: base, username: username, password: password)
        app.buttons["home.account"].tap()
        app.buttons["home.menu.settings"].tap()
        let edit = app.buttons["settings.profile-edit-button"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        edit.tap()
        app.buttons["Choose avatar"].tap()
        let photo = app.descendants(matching: .any).matching(identifier: "PXGGridLayout-Info").firstMatch
        guard photo.waitForExistence(timeout: 30) else {
            attach(app, name: "V5-avatar-picker-failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "V5-avatar-picker-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail("System Photos picker must expose a selectable image")
            return
        }
        XCTAssertFalse(photo.frame.isEmpty)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Use"].waitForExistence(timeout: 20))
        let scale = app.sliders.firstMatch
        XCTAssertTrue(scale.exists)
        scale.adjust(toNormalizedSliderPosition: 0.5)
        app.buttons["Reset"].tap()
        attach(app, name: "V5-avatar-crop")
        app.buttons["Use"].tap()
        let avatarURLField = app.textFields["HTTPS image link"]
        XCTAssertTrue(avatarURLField.waitForExistence(timeout: 10))
        let uploaded = expectation(for: NSPredicate(format: "value CONTAINS %@", "/api/v1/assets/image/"), evaluatedWith: avatarURLField)
        wait(for: [uploaded], timeout: 30)
        let name = app.textFields["Add a display name"]
        scrollTo(name, app: app)
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let oldName = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldName.count) + "V5 Updated Profile")
        let save = app.buttons["Save profile"]
        scrollTo(save, app: app)
        save.tap()
        let saved = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: save)
        wait(for: [saved], timeout: 15)
        let keyboardDismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        wait(for: [keyboardDismissed], timeout: 10)
        let (profileData, profileStatus) = try await request(base: base, path: "/api/v1/auth/me", token: token)
        XCTAssertEqual(profileStatus, 200)
        let profile = try XCTUnwrap(profileData as? [String: Any])
        XCTAssertEqual(profile["nickname"] as? String, "V5 Updated Profile")
        let avatar = try XCTUnwrap(profile["avatar_url"] as? String)
        let (bytes, response) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: avatar)))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let image = try XCTUnwrap(UIImage(data: bytes))
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertEqual(image.size.width, image.size.height)
        attach(app, name: "V5-live-profile-saved")
        app.terminate()
        login(app, base: base, username: username, password: password)
        app.buttons["home.account"].tap()
        app.buttons["home.menu.settings"].tap()
        XCTAssertTrue(app.staticTexts["V5 Updated Profile"].waitForExistence(timeout: 15))
    }

    @MainActor func testPasswordChangeRejectsOldPasswordAndAllowsNewLogin() async throws {
        let (base, username, password, _) = try await registerAccount()
        let newPassword = UUID().uuidString + "bB8!More"
        let app = XCUIApplication()
        login(app, base: base, username: username, password: password)
        app.buttons["home.account"].tap()
        app.buttons["home.menu.settings"].tap()
        let passwordRow = app.buttons["settings.password-row"]
        scrollTo(passwordRow, app: app)
        passwordRow.tap()
        for (identifier, value) in [("settings.current-password-field", password), ("settings.new-password-field", newPassword), ("settings.confirm-password-field", newPassword)] {
            let field = app.secureTextFields[identifier]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            scrollTo(field, app: app)
            // Tap inside the visible text area; XCTest's synthesized hit point can
            // remain on the previous field after SwiftUI scrolls for the keyboard.
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
            let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
            guard XCTWaiter.wait(for: [focused], timeout: 5) == .completed else {
                attach(app, name: "V5-password-focus-failure")
                XCTFail("Visible password field must acquire keyboard focus before typing")
                return
            }
            let existing = field.value as? String ?? ""
            if !existing.isEmpty && existing != field.placeholderValue {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
            }
            field.typeText(value)
            XCTAssertEqual((field.value as? String)?.count, value.count, "Secure field must contain exactly the entered number of characters")
        }
        XCTAssertEqual((app.secureTextFields["settings.current-password-field"].value as? String)?.count, password.count)
        XCTAssertEqual((app.secureTextFields["settings.new-password-field"].value as? String)?.count, newPassword.count)
        XCTAssertEqual((app.secureTextFields["settings.confirm-password-field"].value as? String)?.count, newPassword.count)
        let update = app.buttons["Update password"]
        scrollTo(update, app: app)
        attach(app, name: "V5-password-ready-to-submit")
        update.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        guard app.staticTexts["Password updated"].waitForExistence(timeout: 10) else {
            attach(app, name: "V5-password-submit-failure")
            XCTFail("Password change must show its explicit success acknowledgement")
            return
        }
        let (_, rejectedStatus) = try await request(base: base, path: "/api/v1/auth/login", method: "POST", body: ["username": username, "password": password])
        XCTAssertEqual(rejectedStatus, 401, "The previous password must stop working")
        app.terminate()
        login(app, base: base, username: username, password: newPassword)
        app.buttons["home.account"].tap()
        app.buttons["home.menu.settings"].tap()
        XCTAssertTrue(app.staticTexts["@\(username)"].waitForExistence(timeout: 15))
        attach(app, name: "V5-live-new-password-login")
    }

    @MainActor private func login(_ app: XCUIApplication, base: String, username: String, password: String) {
        app.launchArguments = ["-uiTestResetState", "-settings.languageMode", "english", "-openclawApiBaseURL", base]
        app.launch()
        let name = app.textFields["Email or username"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        name.typeText(username)
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText(password)
        app.buttons["Login"].tap()
        XCTAssertTrue(app.buttons["home.account"].waitForExistence(timeout: 20))
    }

    @MainActor private func scrollTo(_ element: XCUIElement, app: XCUIApplication) {
        // The keyboard's Passwords accessory also contains a ScrollView and may
        // appear first in the hierarchy after focus changes. Select settings.
        let scroll = app.scrollViews.containing(.button, identifier: "settings.logout-button").firstMatch
        for _ in 0..<8 {
            let frame = scroll.frame
            var keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
            for identifier in ["SystemInputAssistantView", "inputView"] {
                let accessory = app.otherElements[identifier].firstMatch
                if accessory.exists && !accessory.frame.isEmpty { keyboardTop = min(keyboardTop, accessory.frame.minY) }
            }
            let visibleBottom = min(frame.maxY, keyboardTop) - 8
            let visibleTop = max(frame.minY, 110) + 8
            if element.exists && element.isHittable && element.frame.minY >= visibleTop && element.frame.maxY <= visibleBottom { return }
            let height = visibleBottom - visibleTop
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let top = origin.withOffset(CGVector(dx: frame.midX, dy: visibleTop + height * 0.2))
            let bottom = origin.withOffset(CGVector(dx: frame.midX, dy: visibleTop + height * 0.8))
            if element.exists && element.frame.minY < visibleTop { top.press(forDuration: 0.05, thenDragTo: bottom) }
            else { bottom.press(forDuration: 0.05, thenDragTo: top) }
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor private func request(base: String, path: String, method: String = "GET", token: String? = nil, body: [String: String]? = nil) async throws -> (Any?, Int) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: base + path)))
        request.httpMethod = method
        request.timeoutInterval = 20
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        return (envelope?["data"], (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
