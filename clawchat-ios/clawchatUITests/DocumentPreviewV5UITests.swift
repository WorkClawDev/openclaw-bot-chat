import XCTest
import Vision

final class DocumentPreviewV5UITests: XCTestCase {
    @MainActor func testPDFWordAndSpreadsheetBodiesAreVisible() async throws {
        continueAfterFailure = false
        for (kind, marker) in [("pdf", "V5 PDF BODY VERIFIED"), ("docx", "V5 WORD BODY VERIFIED"), ("xlsx", "V5 SHEET BODY VERIFIED")] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTestMode", "chatFilesV5", "-uiTestAuthenticated", "-uiTestFileKind", kind, "-settings.languageMode", "english"]
            app.launch()
            let file = app.buttons["v5-file-file-0"]
            XCTAssertTrue(file.waitForExistence(timeout: 15))
            let before = file.frame
            file.tap()
            XCTAssertTrue(app.buttons["chat.file.share"].waitForExistence(timeout: 15))
            var bodyVisible = false
            for _ in 0..<12 {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(data: XCUIScreen.main.screenshot().pngRepresentation).perform([request])
                let recognized = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
                if recognized.contains(marker) { bodyVisible = true; break }
                try await Task.sleep(for: .seconds(1))
            }
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "V5-\(kind)-body-preview"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTAssertTrue(bodyVisible, "The rendered document body must be readable, not just its filename or share button")
            app.buttons["Done"].tap()
            XCTAssertTrue(file.waitForExistence(timeout: 5))
            XCTAssertEqual(file.frame.minY, before.minY, accuracy: 1)
            app.terminate()
        }
    }
}
