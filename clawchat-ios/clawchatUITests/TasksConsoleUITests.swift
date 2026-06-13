import XCTest

final class TasksConsoleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTaskConsoleFixtureShowsTimelineAndSheets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "tasksConsole"]
        app.launch()

        XCTAssertTrue(app.staticTexts["tasks-title"].waitForExistence(timeout: 5), "Tasks fixture title did not appear")
        XCTAssertTrue(app.descendants(matching: .any)["tasks-gantt-board"].waitForExistence(timeout: 5), "Gantt board did not render")

        let createButton = app.buttons["tasks-create-button"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 3), "Create task button did not appear")
        createButton.tap()
        let createSheet = app.descendants(matching: .any)["tasks-create-sheet"]
        let createTitle = app.navigationBars["Create task"].exists || app.navigationBars["新建任务"].exists
        XCTAssertTrue(createSheet.waitForExistence(timeout: 3) || createTitle, "Create task sheet did not open")
        app.buttons["tasks-create-cancel-button"].tap()

        let openFirstTask = app.buttons["tasks-fixture-open-first-task"]
        XCTAssertTrue(openFirstTask.waitForExistence(timeout: 3), "Fixture task opener did not render")
        openFirstTask.tap()
        let inspectorSheet = app.descendants(matching: .any)["tasks-inspector-sheet"]
        let inspectorTitle = app.navigationBars["Task detail"].exists || app.navigationBars["任务详情"].exists
        XCTAssertTrue(inspectorSheet.waitForExistence(timeout: 3) || inspectorTitle, "Task inspector did not open")
    }
}
