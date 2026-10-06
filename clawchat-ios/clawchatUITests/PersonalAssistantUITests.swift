import XCTest
final class PersonalAssistantUITests:XCTestCase {
 override func setUpWithError()throws{continueAfterFailure=false}
 @MainActor func testAssistantApprovalInputAndManagement()async throws {
  var req=URLRequest(url:URL(string:"http://127.0.0.1:18082/fixture/reset")!);req.httpMethod="POST";_ = try await URLSession.shared.data(for:req)
  let app=XCUIApplication();app.launchArguments=["-settings.languageMode","chinese","-uiTestMode","assistantConsole","-uiTestAuthenticated","-openclawApiBaseURL","http://127.0.0.1:18082"]
  app.launch()
  XCTAssertTrue(app.navigationBars["执行与授权"].waitForExistence(timeout:10))
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
 @MainActor func testUncertainOperationEvidenceAndResume()async throws {
  var req=URLRequest(url:URL(string:"http://127.0.0.1:18082/fixture/reset")!);req.httpMethod="POST";_ = try await URLSession.shared.data(for:req)
  req.url=URL(string:"http://127.0.0.1:18082/fixture/uncertain")!;_ = try await URLSession.shared.data(for:req)
  let app=XCUIApplication();app.launchArguments=["-settings.languageMode","chinese","-uiTestMode","assistantConsole","-uiTestAuthenticated","-openclawApiBaseURL","http://127.0.0.1:18082"];app.launch()
  XCTAssertTrue(app.staticTexts["需要核对：fixture_external_write"].waitForExistence(timeout:10))
  let input=app.textFields["核对证据"];input.tap();input.typeText("Provider audit confirms no effect")
  let confirm=app.buttons["确认未执行，允许重试"];if !confirm.isHittable{app.swipeUp()};confirm.tap()
  let vanished=expectation(for:NSPredicate(format:"exists == false"),evaluatedWith:app.staticTexts["需要核对：fixture_external_write"]);await fulfillment(of:[vanished],timeout:10)
  let supplement=app.textFields["补充信息"];supplement.tap();supplement.typeText("Continue verified request");app.buttons["assistant.resume"].tap();XCTAssertTrue(app.staticTexts["已收到补充信息"].waitForExistence(timeout:10))
 }

}
