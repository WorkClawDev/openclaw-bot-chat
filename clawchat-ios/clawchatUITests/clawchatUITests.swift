//
//  clawchatUITests.swift
//  clawchatUITests
//
//  Created by Changer Ding on 2026/4/12.
//

import XCTest

final class clawchatUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
    }

    @MainActor
    func testAuthenticationFormsValidateRequiredFieldsAndNavigation() throws {
        let app = launchApp(authenticated: false)

        XCTAssertTrue(app.staticTexts["Welcome back"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.textFields["Email or username"].exists)
        XCTAssertTrue(app.secureTextFields["Password"].exists)

        app.buttons["Login"].tap()
        XCTAssertTrue(app.staticTexts["Username or email is required"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Password is required"].exists)

        button(containing: "Create account", in: app).tap()
        XCTAssertTrue(app.textFields["Username"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.textFields["Email"].exists)
        XCTAssertTrue(app.secureTextFields["Password"].exists)

        app.buttons["Register"].tap()
        XCTAssertTrue(app.staticTexts["Username is required"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Email is required"].exists)
        XCTAssertTrue(app.staticTexts["Password is required"].exists)

        button(containing: "Sign in", in: app).tap()
        XCTAssertTrue(app.staticTexts["Sign in to ClawChat"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testAuthenticatedShellNavigatesEveryPrimaryTabAndKeySheets() throws {
        let app = launchApp(authenticated: true)

        assertHomeTab(in: app)
        assertContactsTab(in: app)
        assertTasksTabAndCreateSheet(in: app)
        assertDocumentsTabAndEditor(in: app)
        assertSettingsTabAndLogout(in: app)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            _ = launchApp(authenticated: false)
        }
    }

    @MainActor
    private func launchApp(authenticated: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestResetState",
            "-openclawApiBaseURL", "http://127.0.0.1:8080"
        ]
        if authenticated {
            app.launchArguments.append("-uiTestAuthenticated")
        }
        app.launchEnvironment["OPENCLAW_DOCUMENTS_ENABLED"] = "true"
        app.launch()
        return app
    }

    @MainActor
    private func assertHomeTab(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Messages"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Welcome back"].exists)
        XCTAssertTrue(app.staticTexts["Chats"].exists)
        XCTAssertTrue(app.buttons["Add"].exists)
    }

    @MainActor
    private func assertContactsTab(in app: XCUIApplication) {
        tapTab("Contacts", in: app)
        XCTAssertTrue(app.navigationBars["Contacts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Search bots"].exists)

        let groupsSegment = app.buttons["Groups"]
        XCTAssertTrue(groupsSegment.waitForExistence(timeout: 3))
        groupsSegment.tap()
        XCTAssertTrue(app.textFields["Search groups"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func assertTasksTabAndCreateSheet(in app: XCUIApplication) {
        tapTab("Tasks", in: app)
        XCTAssertTrue(app.staticTexts["tasks-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["tasks-view-mode-picker"].exists)

        let createButton = app.buttons["tasks-create-button"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 3))
        createButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tasks-create-sheet"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Create task"].exists || app.navigationBars["New task"].exists)
        app.buttons["Cancel"].tap()
    }

    @MainActor
    private func assertDocumentsTabAndEditor(in app: XCUIApplication) {
        tapTab("Docs", in: app)
        XCTAssertTrue(app.staticTexts["Documents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Search documents"].exists)

        app.buttons["New document"].tap()
        XCTAssertTrue(app.navigationBars["New document"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.textFields["Title"].exists)
        XCTAssertTrue(app.staticTexts["Live preview"].exists)
        app.buttons["Cancel"].tap()
    }

    @MainActor
    private func assertSettingsTabAndLogout(in app: XCUIApplication) {
        tapTab("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Test Runner"].exists)
        XCTAssertTrue(app.staticTexts["@ui-test"].exists)
        XCTAssertTrue(app.staticTexts["ui-test@example.com"].exists)

        app.buttons["settings.profile-edit-button"].tap()
        XCTAssertTrue(app.staticTexts["Display name"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["settings.display-name-field"].exists)
        app.buttons["settings.profile-edit-button"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["settings.display-name-field"].waitForExistence(timeout: 1))

        tapElement("settings.password-row", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings.current-password-field"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["settings.new-password-field"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["settings.confirm-password-field"].exists)
        app.buttons["Update password"].tap()
        XCTAssertTrue(app.staticTexts["New password must be at least 8 characters"].waitForExistence(timeout: 2))

        let logoutButton = app.buttons["settings.logout-button"]
        scrollToElement(logoutButton, in: app)
        logoutButton.tap()
        XCTAssertTrue(app.staticTexts["Sign in to ClawChat"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func tapTab(_ name: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "Missing \(name) tab")
        tab.tap()
    }

    @MainActor
    private func button(containing text: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons.containing(.staticText, identifier: text).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 4), "Missing button containing \(text)")
        return button
    }

    @MainActor
    private func tapElement(_ identifier: String, in app: XCUIApplication) {
        let element = app.descendants(matching: .any)[identifier]
        scrollToElement(element, in: app)
        element.tap()
    }

    @MainActor
    private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 3), "Missing \(element)")
        for _ in 0..<6 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "Element is not hittable: \(element)")
    }
}
