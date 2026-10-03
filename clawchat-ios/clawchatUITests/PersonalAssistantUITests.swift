import XCTest
final class PersonalAssistantUITests:XCTestCase {
 override func setUpWithError()throws{continueAfterFailure=false}
 @MainActor func testAssistantApprovalInputAndManagement()throws {
  let app=XCUIApplication();app.launchArguments=["-uiTestMode","assistantConsole","-uiTestAuthenticated","-openclawApiBaseURL","http://127.0.0.1:18082"]
  app.launch()
  XCTAssertTrue(app.navigationBars["个人助手"].waitForExistence(timeout:10))
  XCTAssertTrue(app.staticTexts["请补充报告的目标读者"].waitForExistence(timeout:10))
  let input=app.textFields["补充信息"];input.tap();input.typeText("For weekly meeting")
  app.buttons["assistant.resume"].tap()
  XCTAssertTrue(app.staticTexts["已收到补充信息"].waitForExistence(timeout:10))
  app.swipeUp();let approve=app.buttons["批准本次操作"];if !approve.isHittable{app.swipeUp()};XCTAssertTrue(approve.waitForExistence(timeout:5));approve.tap()
  let shot=XCTAttachment(screenshot:app.screenshot());shot.name="personal-assistant-runtime";shot.lifetime = .keepAlways;add(shot)
  app.swipeDown();app.swipeDown();app.buttons["记忆与计划"].tap()
  XCTAssertTrue(app.navigationBars["记忆与计划"].waitForExistence(timeout:5))
  let memory=app.textFields["记忆内容"];memory.tap();memory.typeText("Use CNY for reports")
  app.buttons["确认保存记忆"].tap()
  XCTAssertTrue(app.staticTexts["Use CNY for reports"].waitForExistence(timeout:10))
  app.buttons["删除"].tap()
  let management=XCTAttachment(screenshot:app.screenshot());management.name="personal-assistant-management";management.lifetime = .keepAlways;add(management)
 }
}
