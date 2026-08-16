import XCTest

final class ChatRoomV2ScrollRegressionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testConsecutivePrependsStayStable() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2",
            "-fixture", "textPrependStress",
            "-chatRoomV2AutoPrependStress", "5"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))

        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))

        let completed = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "prepends=5", "prepends=5")
        expectation(for: completed, evaluatedWith: diagnostics)
        waitForExpectations(timeout: 20)

        let singleRestorePerPrepend = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "restores=5", "restores=5")
        XCTAssertTrue(singleRestorePerPrepend.evaluate(with: diagnostics))

        let diagnosticText = diagnostics.value as? String ?? diagnostics.label
        XCTAssertLessThanOrEqual(driftValue(in: diagnosticText), 1.0)
    }

    @MainActor
    func testMixedRichContentPrependStaysStable() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2",
            "-fixture", "mixedRichPrepend"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["v2-mixed-997-image-0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["v2-mixed-998-table-0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["v2-mixed-999-audio-0"].waitForExistence(timeout: 10))
        XCTAssertTrue(collection.cells["chatRoomV2.message.v2-mixed-1000"].waitForExistence(timeout: 10))

        let top = collection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let bottom = collection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        for _ in 0..<18 {
            let diagnosticText = diagnostics.value as? String ?? diagnostics.label
            if diagnosticText.contains("prepends=1") {
                break
            }
            top.press(forDuration: 0.01, thenDragTo: bottom)
        }

        let completed = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "prepends=1", "prepends=1")
        expectation(for: completed, evaluatedWith: diagnostics)
        waitForExpectations(timeout: 10)

        let diagnosticText = diagnostics.value as? String ?? diagnostics.label
        XCTAssertTrue(diagnosticText.contains("restores=1"))
        XCTAssertTrue(diagnosticText.contains("reloads=0"))
        XCTAssertLessThanOrEqual(driftValue(in: diagnosticText), 1.0)
    }

    @MainActor
    func testConsecutiveImagesPrependStaysStable() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2",
            "-fixture", "consecutiveImagesPrepend"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["v2-images-1000-image-0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["v2-images-999-image-0"].waitForExistence(timeout: 10))

        let top = collection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let bottom = collection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        for _ in 0..<22 {
            let diagnosticText = diagnostics.value as? String ?? diagnostics.label
            if diagnosticText.contains("prepends=1") {
                break
            }
            top.press(forDuration: 0.01, thenDragTo: bottom)
        }

        let completed = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "prepends=1", "prepends=1")
        expectation(for: completed, evaluatedWith: diagnostics)
        waitForExpectations(timeout: 10)

        let diagnosticText = diagnostics.value as? String ?? diagnostics.label
        XCTAssertTrue(diagnosticText.contains("restores=1"))
        XCTAssertTrue(diagnosticText.contains("reloads=0"))
        XCTAssertLessThanOrEqual(driftValue(in: diagnosticText), 1.0)
    }

    @MainActor
    func testRapidScrollingDoesNotBlankTextFixture() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2",
            "-fixture", "textBenchmark"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))

        let top = collection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let bottom = collection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        for _ in 0..<5 {
            bottom.press(forDuration: 0.01, thenDragTo: top)
        }
        assertVisibleTextMessagesAreRendered(in: collection)
        for _ in 0..<5 {
            top.press(forDuration: 0.01, thenDragTo: bottom)
        }
        assertVisibleTextMessagesAreRendered(in: collection)

        XCTAssertTrue(app.staticTexts["chatRoomV2.diagnostics"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testRapidScrollingCollectsHitchAndDecelerationMetrics() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2",
            "-fixture", "textBenchmark"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))
        assertVisibleTextMessagesAreRendered(in: collection)

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(
            metrics: [
                XCTOSSignpostMetric.scrollingAndDecelerationMetric,
                XCTHitchMetric(application: app)
            ],
            options: options
        ) {
            collection.swipeDown(velocity: .fast)
            collection.swipeUp(velocity: .fast)
        }

        assertVisibleTextMessagesAreRendered(in: collection)
    }

    @MainActor
    func testRichMediaFixtureRendersNativeBlocks() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2",
            "-fixture", "richMedia"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))

        XCTAssertTrue(app.textViews["chatRoomV2.text.v2-rich-markdown-text-0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["v2-rich-markdown-table-0.r0c0"].exists)
        XCTAssertTrue(app.staticTexts["v2-rich-markdown-table-0.r1c1"].exists)
        XCTAssertTrue(app.staticTexts["v2-rich-markdown-code-0.language"].exists)
        XCTAssertTrue(app.staticTexts["v2-rich-markdown-code-0.content"].exists)
        XCTAssertTrue(app.staticTexts["v2-rich-markdown-code-1.language"].exists)
        XCTAssertTrue(app.staticTexts["v2-rich-markdown-code-1.content"].exists)
        XCTAssertTrue(app.buttons["v2-rich-image-image-0"].exists)
        XCTAssertTrue(app.buttons["v2-rich-audio-audio-0"].exists)
        XCTAssertTrue(app.otherElements["chatRoomV2.avatar.Fixture Bot"].exists)
        XCTAssertTrue(app.staticTexts["chatRoomV2.sender.Fixture Bot"].exists)
        XCTAssertTrue(app.staticTexts["chatRoomV2.status"].exists)

        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.exists)
        XCTAssertTrue(diagnosticText(for: diagnostics).contains("messages=3"))
    }

    @MainActor
    func testFailedLocalMessageKeepsSlotWhenRemoteRefreshAppends() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2StatusStability"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))

        let failed = collection.cells["chatRoomV2.message.failed-local"]
        let pending = collection.cells["chatRoomV2.message.pending-local"]
        XCTAssertTrue(failed.waitForExistence(timeout: 10))
        XCTAssertTrue(pending.waitForExistence(timeout: 10))
        XCTAssertLessThan(failed.frame.minY, pending.frame.minY)

        let remoteRefresh = collection.cells["chatRoomV2.message.remote-101"]
        XCTAssertTrue(remoteRefresh.waitForExistence(timeout: 10))
        XCTAssertLessThan(failed.frame.minY, remoteRefresh.frame.minY)
        XCTAssertLessThan(pending.frame.minY, remoteRefresh.frame.minY)
    }

    @MainActor
    func testImageBlockOpensPreviewWithoutRelayout() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2ImagePreview"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))

        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        let beforeText = diagnosticText(for: diagnostics)
        XCTAssertTrue(beforeText.contains("messages=1"))
        let imageCell = app.cells["chatRoomV2.message.v2-live-image-message"]
        XCTAssertTrue(imageCell.waitForExistence(timeout: 10))
        let beforeFrame = imageCell.frame

        let image = app.buttons["v2-live-image-message-image-0"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        image.tap()

        XCTAssertTrue(app.buttons["chat.imagePreview.save"].waitForExistence(timeout: 10))

        XCTAssertEqual(diagnosticText(for: diagnostics), beforeText)
        XCTAssertEqual(imageCell.frame, beforeFrame)
    }

    @MainActor
    func testSameIDUpdateRendersUpdatedBlockInPlace() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2",
            "-fixture", "richMedia",
            "-chatRoomV2AutoSameIDUpdate"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells["chatRoomV2.message.v2-rich-markdown"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews["chatRoomV2.text.v2-rich-markdown-text-debug-update"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSameIDUpdateNearBottomKeepsNewestMessagePinned() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2",
            "-fixture", "textPrependStress",
            "-chatRoomV2ManualSameIDUpdate",
            "-chatRoomV2DisableHistoryLoading"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))

        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        XCTAssertTrue(diagnosticText(for: diagnostics).contains("updates=0"))

        let newest = app.cells["chatRoomV2.message.v2-message-1000"]
        XCTAssertTrue(newest.waitForExistence(timeout: 10))
        XCTAssertTrue(newest.frame.intersects(collection.frame))
        let bottomDistanceBefore = collection.frame.maxY - newest.frame.maxY

        let trigger = app.buttons["chatRoomV2.triggerSameIDUpdate"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 10))
        trigger.tap()
        waitForDiagnostic("updates=1", in: diagnostics, timeout: 10)

        XCTAssertTrue(newest.exists)
        XCTAssertTrue(newest.frame.intersects(collection.frame))
        let bottomDistanceAfter = collection.frame.maxY - newest.frame.maxY
        XCTAssertLessThanOrEqual(abs(bottomDistanceAfter - bottomDistanceBefore), 1.5)
    }

    @MainActor
    func testSameIDUpdateAwayFromBottomPreservesVisibleAnchor() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2",
            "-fixture", "textPrependStress",
            "-chatRoomV2ManualSameIDUpdate",
            "-chatRoomV2DisableHistoryLoading"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))

        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        XCTAssertTrue(diagnosticText(for: diagnostics).contains("updates=0"))

        collection.swipeDown(velocity: .fast)
        collection.swipeDown(velocity: .fast)

        let newest = app.cells["chatRoomV2.message.v2-message-1000"]
        XCTAssertFalse(newest.exists && newest.frame.intersects(collection.frame))

        let visibleCells = visibleMessageCells(in: collection)
            .filter { $0.identifier != "chatRoomV2.message.v2-message-941" }
        guard let anchor = visibleCells.first else {
            XCTFail("Expected a stable visible message away from the bottom")
            return
        }
        let anchorIdentifier = anchor.identifier
        let anchorMinYBefore = anchor.frame.minY
        let restoresBefore = diagnosticCount(named: "restores", in: diagnosticText(for: diagnostics))

        let trigger = app.buttons["chatRoomV2.triggerSameIDUpdate"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 10))
        trigger.tap()
        waitForDiagnostic("updates=1", in: diagnostics, timeout: 12)

        let anchorAfter = app.cells[anchorIdentifier]
        XCTAssertTrue(anchorAfter.exists)
        XCTAssertTrue(anchorAfter.frame.intersects(collection.frame))
        XCTAssertLessThanOrEqual(abs(anchorAfter.frame.minY - anchorMinYBefore), 1.5)
        let restoresAfter = diagnosticCount(named: "restores", in: diagnosticText(for: diagnostics))
        XCTAssertEqual(restoresAfter, restoresBefore + 1)
    }

    @MainActor
    func testWindowReplacementPublishesConcreteNewWindowIDs() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2",
            "-fixture", "textPrependStress",
            "-chatRoomV2AutoWindowReplace"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))

        let newestReplacement = app.cells["chatRoomV2.message.v2-message-2000"]
        XCTAssertTrue(newestReplacement.waitForExistence(timeout: 10))
        XCTAssertTrue(newestReplacement.label.contains("#2000"))
        XCTAssertFalse(app.cells["chatRoomV2.message.v2-message-1000"].exists)
        assertVisibleTextMessagesAreRendered(in: collection)

        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.exists)
        let diagnosticText = diagnosticText(for: diagnostics)
        XCTAssertTrue(diagnosticText.contains("messages=60"))
    }

    @MainActor
    func testRapidSnapshotBurstUsesSerializedDiffs() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2",
            "-fixture", "textPrependStress",
            "-chatRoomV2AutoRapidSnapshotBurst"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))

        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))

        let completed = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "messages=63", "messages=63")
        expectation(for: completed, evaluatedWith: diagnostics)
        waitForExpectations(timeout: 10)

        let diagnosticText = diagnosticText(for: diagnostics)
        XCTAssertTrue(diagnosticText.contains("appends=2"))
        XCTAssertTrue(diagnosticText.contains("prepends=1"))
        XCTAssertTrue(diagnosticText.contains("restores=1"))
        XCTAssertLessThanOrEqual(driftValue(in: diagnosticText), 1.0)
        XCTAssertTrue(app.cells["chatRoomV2.message.v2-burst-1002"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testLiveBridgePrependUsesSnapshotRestore() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2LiveBridge"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))

        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))

        let completed = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "messages=90", "messages=90")
        expectation(for: completed, evaluatedWith: diagnostics)
        waitForExpectations(timeout: 10)

        let diagnosticText = diagnosticText(for: diagnostics)
        XCTAssertTrue(diagnosticText.contains("prepends=1"))
        XCTAssertTrue(diagnosticText.contains("restores=1"))
        XCTAssertLessThanOrEqual(driftValue(in: diagnosticText), 1.0)
    }

    @MainActor
    func testKeyboardInsetDoesNotOverlapHistoryPrepend() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2",
            "-fixture", "textPrependStress",
            "-chatRoomV2AutoPrependStress", "1",
            "-chatRoomV2AutoKeyboardDuringPrepend"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))

        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))

        let completed = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "prepends=1", "prepends=1")
        expectation(for: completed, evaluatedWith: diagnostics)
        waitForExpectations(timeout: 10)

        let diagnosticText = diagnosticText(for: diagnostics)
        XCTAssertTrue(diagnosticText.contains("restores=1"))
        XCTAssertTrue(diagnosticText.contains("keyboardOverlap=0"))
        XCTAssertLessThanOrEqual(driftValue(in: diagnosticText), 1.0)
    }

    @MainActor
    func testKeyboardShowHideKeepsV2ListStable() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2",
            "-fixture", "textPrependStress",
            "-chatRoomV2AutoKeyboardShowHide"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))

        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))

        let completed = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "keyboardRestores=2", "keyboardRestores=2")
        expectation(for: completed, evaluatedWith: diagnostics)
        waitForExpectations(timeout: 10)

        let diagnosticText = diagnostics.value as? String ?? diagnostics.label
        XCTAssertTrue(diagnosticText.contains("messages=60"))
        XCTAssertTrue(diagnosticText.contains("prepends=0"))
        XCTAssertTrue(diagnosticText.contains("restores=0"))
        XCTAssertTrue(diagnosticText.contains("reloads=0"))
        XCTAssertTrue(diagnosticText.contains("keyboardOverlap=0"))
        XCTAssertTrue(diagnosticText.contains("keyboardRestores=2"))
    }

    private func assertVisibleTextMessagesAreRendered(
        in collection: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let visibleCells = visibleMessageCells(in: collection)

        XCTAssertFalse(visibleCells.isEmpty, "Expected at least one visible message cell", file: file, line: line)
        for cell in visibleCells {
            let textViews = cell.descendants(matching: .textView)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "chatRoomV2.text."))
                .allElementsBoundByIndex
                .filter { textView in
                    textView.exists
                        && !textView.frame.isEmpty
                        && textView.frame.intersects(cell.frame)
                        && textView.frame.intersects(collection.frame)
                }
            XCTAssertFalse(
                textViews.isEmpty,
                "Visible message \(cell.identifier) has no visible text view",
                file: file,
                line: line
            )
            for textView in textViews {
                let renderedText = (textView.value as? String ?? textView.label)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertFalse(
                    renderedText.isEmpty,
                    "Visible text view \(textView.identifier) rendered empty",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func visibleMessageCells(in collection: XCUIElement) -> [XCUIElement] {
        collection.cells
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "chatRoomV2.message."))
            .allElementsBoundByIndex
            .filter { cell in
                cell.exists && !cell.frame.isEmpty && cell.frame.intersects(collection.frame)
            }
    }

    private func waitForDiagnostic(
        _ text: String,
        in diagnostics: XCUIElement,
        timeout: TimeInterval
    ) {
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        expectation(for: predicate, evaluatedWith: diagnostics)
        waitForExpectations(timeout: timeout)
    }

    private func diagnosticText(for diagnostics: XCUIElement) -> String {
        diagnostics.value as? String ?? diagnostics.label
    }

    private func driftValue(in diagnosticText: String) -> Double {
        metricValue("drift", in: diagnosticText)
    }

    private func metricValue(_ name: String, in diagnosticText: String) -> Double {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let range = diagnosticText.range(of: "\(escapedName)=([0-9]+(?:\\.[0-9]+)?)", options: .regularExpression) else {
            XCTFail("Missing \(name) diagnostic in: \(diagnosticText)")
            return .greatestFiniteMagnitude
        }
        let matched = String(diagnosticText[range])
        return Double(matched.replacingOccurrences(of: "\(name)=", with: "")) ?? .greatestFiniteMagnitude
    }

    private func diagnosticCount(named name: String, in diagnosticText: String) -> Int {
        guard let range = diagnosticText.range(of: #"\b\#(name)=([0-9]+)"#, options: .regularExpression) else {
            XCTFail("Missing \(name) diagnostic in: \(diagnosticText)")
            return .min
        }
        return Int(diagnosticText[range].split(separator: "=").last ?? "") ?? .min
    }
}
