import XCTest
import UIKit

final class LayoutVariantsV5UITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testIPadAuthenticationFormsFitBothOrientations() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetState", "-settings.appearanceMode", "light", "-settings.languageMode", "english", "-openclawApiBaseURL", "http://127.0.0.1:18082"]
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        for (orientation, label) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            XCUIDevice.shared.orientation = orientation
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                label == "landscape" ? app.frame.width > app.frame.height : app.frame.height > app.frame.width
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 10), .completed)
            let create = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Create account")).firstMatch
            for element in [app.staticTexts["Welcome back"], app.textFields["Email or username"], app.secureTextFields["Password"], app.buttons["Login"], create] {
                assertAuthControlVisible(element, in: app)
            }
            attach(app, "V5-iPad-\(label)-login-form")
            create.tap()
            for element in [app.staticTexts["Create account"], app.textFields["Username"], app.textFields["Email"], app.secureTextFields["Password"], app.buttons["Register"]] {
                assertAuthControlVisible(element, in: app)
            }
            attach(app, "V5-iPad-\(label)-register-form")
            let signIn = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Sign in")).firstMatch
            assertAuthControlVisible(signIn, in: app)
            signIn.tap()
            XCTAssertTrue(app.textFields["Email or username"].waitForExistence(timeout: 10))
        }
    }

    @MainActor private func assertAuthControlVisible(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.isHittable && !element.frame.isEmpty && app.frame.contains(element.frame)
        }, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed, "Authentication content must fit inside the viewport")
    }

    @MainActor func testPhoneEmptyTasksAndProfileCancellation() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetState", "-uiTestAuthenticated", "-settings.appearanceMode", "light", "-settings.languageMode", "english", "-openclawApiBaseURL", "http://127.0.0.1:18082"]
        app.launch()
        XCTAssertTrue(app.buttons["home.account"].waitForExistence(timeout: 15))
        app.buttons["home.account"].tap()
        app.buttons["home.menu.tasks"].tap()
        let empty = app.staticTexts["No matching tasks"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertTrue(app.frame.contains(empty.frame))
        attach(app, "V5-phone-empty-tasks")
        app.buttons["home.utility.close"].tap()
        app.buttons["home.account"].tap()
        app.buttons["home.menu.settings"].tap()
        let edit = app.buttons["settings.profile-edit-button"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        edit.tap()
        let keyboardClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardClosed], timeout: 5), .completed)
        XCTAssertFalse(app.descendants(matching: .any)["settings.display-name-field"].exists)
        attach(app, "V5-phone-profile-cancelled")
    }

    @MainActor func testDarkHomeChatAndCreationSheets() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetState", "-uiTestMode", "homeV5", "-uiTestAuthenticated", "-settings.appearanceMode", "dark", "-openclawApiBaseURL", "http://127.0.0.1:18082"]
        app.launch()
        XCTAssertTrue(app.buttons["home.search"].waitForExistence(timeout: 15))
        attach(app, "V5-dark-home")
        for destination in ["Create bot", "Create group"] {
            app.buttons["home.add"].tap()
            app.buttons[destination].tap()
            XCTAssertTrue(app.navigationBars[destination].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Create"].isEnabled)
            attach(app, "V5-\(destination)")
            app.buttons["Cancel"].tap()
        }
        app.buttons["home.conversation.preview-bot-0"].tap()
        let list = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        for cell in list.cells.allElementsBoundByIndex {
            XCTAssertGreaterThanOrEqual(cell.frame.minX, 0)
            XCTAssertLessThanOrEqual(cell.frame.maxX, app.frame.maxX + 1)
        }
        XCTAssertTrue(app.buttons["chat.attachments"].isHittable)
        attach(app, "V5-dark-chat")
    }

    @MainActor func testIPadSecondaryDestinationsStayReachable() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "iPad layout acceptance")
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetState", "-uiTestAuthenticated", "-settings.appearanceMode", "light", "-openclawApiBaseURL", "http://127.0.0.1:18082"]
        app.launch()
        XCTAssertTrue(app.buttons["ipad.section.home"].waitForExistence(timeout: 15))
        defer { XCUIDevice.shared.orientation = .portrait }
        for (orientation, label) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            XCUIDevice.shared.orientation = orientation
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = app.frame
                return label == "landscape" ? frame.width > frame.height : frame.height > frame.width
            }, object: app)
            guard XCTWaiter.wait(for: [rotated], timeout: 10) == .completed else {
                attach(app, "V5-iPad-\(label)-rotation-failed")
                XCTFail("The app must actually adopt the requested orientation before layout acceptance")
                return
            }
            for section in ["home", "bots", "groups", "tasks", "documents", "assistant", "settings"] {
                let button = app.buttons["ipad.section.\(section)"]
                let visible = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: button)
                wait(for: [visible], timeout: 5)
                XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX)
                XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
                button.tap()
                let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: button)
                XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
                if section == "tasks" {
                    let empty = app.staticTexts["No matching tasks"]
                    XCTAssertTrue(empty.waitForExistence(timeout: 10))
                    XCTAssertTrue(app.frame.contains(empty.frame))
                }
                if section == "bots" {
                    let title = app.staticTexts["ipad.entity.title"]
                    XCTAssertTrue(title.waitForExistence(timeout: 10))
                    XCTAssertEqual(title.label, "Fixture Assistant")
                    XCTAssertGreaterThan(title.frame.width, 100)
                    XCTAssertTrue(app.buttons["ipad.entity.start-chat"].isHittable)
                }
                if section == "settings" {
                    let settings = app.scrollViews.containing(.button, identifier: "settings.logout-button").firstMatch
                    let profile = settings.staticTexts["Test Runner"]
                    let appearance = settings.staticTexts["Appearance mode"]
                    XCTAssertTrue(profile.waitForExistence(timeout: 10))
                    attach(app, "V5-iPad-\(label)-settings")
                    XCTAssertGreaterThan(profile.frame.width, 100)
                    XCTAssertTrue(app.frame.contains(profile.frame))
                    XCTAssertTrue(app.frame.contains(appearance.frame))
                    if label == "portrait" {
                        XCTAssertGreaterThan(appearance.frame.minY, profile.frame.maxY + 20)
                    } else {
                        XCTAssertGreaterThan(appearance.frame.minX, profile.frame.maxX)
                    }
                    let edit = app.buttons["settings.profile-edit-button"]
                    XCTAssertTrue(edit.isHittable)
                    edit.tap()
                    XCTAssertTrue(app.descendants(matching: .any)["settings.display-name-field"].waitForExistence(timeout: 5))
                    edit.tap()
                    let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.descendants(matching: .any)["settings.display-name-field"])
                    XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
                }
                if section != "settings" { attach(app, "V5-iPad-\(label)-\(section)") }
            }
        }
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        // Capture the display after rotation; application-bound captures can retain
        // portrait clipping bounds in the simulator even when the UI is landscape.
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
