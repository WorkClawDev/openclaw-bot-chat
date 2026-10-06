import XCTest

final class ChatRoomV2ScrollRegressionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // Geometry assertions cannot establish physical frame pacing. Keep this
    // measurement separate from simulator acceptance; inspect the recorded
    // hitch/animation metrics before claiming the smoothness requirement passes.
    @MainActor
    func testPhysicalMixedContentScrollPerformance() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Frame pacing acceptance requires a physical iPhone")
#else
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "chatRoomV2", "-fixture", "mixedRichPrepend", "-chatRoomV2DecodedImages", "-settings.languageMode", "english"]
        app.launch()
        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 15))
        let image = app.buttons["v2-mixed-997-image-0"]
        for _ in 0..<8 where !image.isHittable { collection.swipeDown() }
        XCTAssertTrue(image.isHittable)
        let loaded = NSPredicate(format: "value == %@", imageLoadedValue)
        expectation(for: loaded, evaluatedWith: image)
        waitForExpectations(timeout: 15)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            for _ in 0..<3 { collection.swipeDown(velocity: .fast) }
            for _ in 0..<3 { collection.swipeUp(velocity: .fast) }
        }
        XCTAssertGreaterThan(collection.cells.count, 0)
        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.exists)
        let value = diagnostics.value as? String ?? diagnostics.label
        XCTAssertTrue(value.contains("reloads=0"))
        XCTAssertLessThanOrEqual(driftValue(in: value), 1.0)
#endif
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

        let noUnexpectedReloads = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "reloads=0", "reloads=0")
        XCTAssertTrue(noUnexpectedReloads.evaluate(with: diagnostics))

        let singleRestorePerPrepend = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "restores=5", "restores=5")
        XCTAssertTrue(singleRestorePerPrepend.evaluate(with: diagnostics))

        let diagnosticText = diagnostics.value as? String ?? diagnostics.label
        XCTAssertLessThanOrEqual(driftValue(in: diagnosticText), 1.0)
    }

    @MainActor
    func testMixedRichContentPrependStaysStable() throws {
        try assertMixedRichContentPrepend(decodedImages: false)
    }

    @MainActor
    func testDecodedImagesKeepMixedHistoryStable() throws {
        try assertMixedRichContentPrepend(decodedImages: true)
    }

    private var imageLoadedValue: String { "Image loaded" }

    @MainActor
    private func assertMixedRichContentPrepend(decodedImages: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2",
            "-fixture", "mixedRichPrepend",
            "-settings.languageMode", "english"
        ]
        if decodedImages { app.launchArguments.append("-chatRoomV2DecodedImages") }
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))
        // UICollectionView's accessibility frame may include offscreen content.
        // Keep the drag within the actual application viewport on compact phones.
        print("V5_SCROLL_VIEWPORT collection=\(collection.frame) app=\(app.frame)")
        let viewport = collection.frame.intersection(app.frame)
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.80))
        // A compact screen cannot display all four rich rows at the same time.
        // Verify each block while scrolling toward history instead of assuming a tall viewport.
        for element in [
            collection.cells["chatRoomV2.message.v2-mixed-1000"],
            app.buttons["v2-mixed-999-audio-0"],
            app.otherElements["v2-mixed-998-table-0"],
            app.buttons["v2-mixed-997-image-0"]
        ] {
            for _ in 0..<6 where !element.exists || !element.frame.intersects(viewport) {
                top.press(forDuration: 0.01, thenDragTo: bottom)
            }
            XCTAssertTrue(element.exists && !element.frame.isEmpty && element.frame.intersects(viewport),
                          "Rich content must be visible in the viewport on every screen size")
        }
        print("V5_SCROLL_REACHABLE collection=\(collection.frame) viewport=\(viewport)")
        if decodedImages {
            let image = app.buttons["v2-mixed-997-image-0"]
            let frame = image.frame
            expectation(for: NSPredicate(format: "value == %@", imageLoadedValue), evaluatedWith: image)
            waitForExpectations(timeout: 15)
            XCTAssertEqual(image.frame.minY, frame.minY, accuracy: 1)
            XCTAssertEqual(image.frame.height, frame.height, accuracy: 1)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "V5-decoded-image-mixed-history"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        for _ in 0..<36 {
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
        print("V5_SCROLL_HISTORY \(diagnosticText)")
        XCTAssertTrue(diagnosticText.contains("restores=1"))
        XCTAssertTrue(diagnosticText.contains("reloads=0"))
        XCTAssertLessThanOrEqual(driftValue(in: diagnosticText), 1.0)
        if decodedImages {
            for _ in 0..<3 {
                collection.swipeUp(velocity: .fast)
                collection.swipeDown(velocity: .fast)
            }
            XCTAssertGreaterThan(collection.cells.count, 0)
            let afterReuse = diagnostics.value as? String ?? diagnostics.label
            XCTAssertTrue(afterReuse.contains("reloads=0"))
            XCTAssertLessThanOrEqual(driftValue(in: afterReuse), 1)
        }
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
        for _ in 0..<5 {
            top.press(forDuration: 0.01, thenDragTo: bottom)
        }

        XCTAssertTrue(app.staticTexts["chatRoomV2.diagnostics"].waitForExistence(timeout: 10))
        XCTAssertTrue(collection.cells.count > 0)
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

        XCTAssertTrue(app.otherElements["v2-rich-markdown-text-0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["v2-rich-markdown-table-0"].exists)
        XCTAssertTrue(app.staticTexts["v2-rich-markdown-table-0.r0c0"].exists)
        XCTAssertTrue(app.staticTexts["v2-rich-markdown-table-0.r1c1"].exists)
        XCTAssertTrue(app.otherElements["v2-rich-markdown-code-0"].exists)
        XCTAssertTrue(app.staticTexts["v2-rich-markdown-code-0.language"].exists)
        XCTAssertTrue(app.staticTexts["v2-rich-markdown-code-0.content"].exists)
        XCTAssertTrue(app.otherElements["v2-rich-markdown-code-1"].exists)
        XCTAssertTrue(app.staticTexts["v2-rich-markdown-code-1.language"].exists)
        XCTAssertTrue(app.staticTexts["v2-rich-markdown-code-1.content"].exists)
        XCTAssertTrue(app.buttons["v2-rich-image-image-0"].exists)
        XCTAssertTrue(app.buttons["v2-rich-audio-audio-0"].exists)
        XCTAssertFalse(app.otherElements["chatRoomV2.avatar.Fixture Bot"].exists)
        XCTAssertTrue(app.staticTexts["chatRoomV2.sender.Fixture Bot"].exists)
        XCTAssertTrue(app.staticTexts["chatRoomV2.status"].exists)

        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.exists)
        let diagnosticText = diagnostics.value as? String ?? diagnostics.label
        XCTAssertTrue(diagnosticText.contains("reloads=0"))
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
        let beforeText = diagnostics.value as? String ?? diagnostics.label
        XCTAssertTrue(beforeText.contains("messages=1"))
        XCTAssertTrue(beforeText.contains("reloads=0"))

        let image = app.buttons["v2-live-image-message-image-0"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        image.tap()

        XCTAssertTrue(app.buttons["chat.imagePreview.save"].waitForExistence(timeout: 10))

        let afterText = diagnostics.value as? String ?? diagnostics.label
        XCTAssertTrue(afterText.contains("reloads=0"))
    }

    @MainActor
    func testSameIDUpdateDoesNotReloadData() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2",
            "-fixture", "richMedia",
            "-chatRoomV2AutoSameIDUpdate"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["v2-rich-markdown-text-debug-update"].waitForExistence(timeout: 10))

        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.exists)
        let diagnosticText = diagnostics.value as? String ?? diagnostics.label
        XCTAssertTrue(diagnosticText.contains("reloads=0"))
    }

    @MainActor
    func testWindowReplacementDoesNotReloadData() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "chatRoomV2",
            "-fixture", "textPrependStress",
            "-chatRoomV2AutoWindowReplace"
        ]
        app.launch()

        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))
        XCTAssertTrue(collection.cells.count > 0)

        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        XCTAssertTrue(diagnostics.exists)
        let diagnosticText = diagnostics.value as? String ?? diagnostics.label
        XCTAssertTrue(diagnosticText.contains("messages=60"))
        XCTAssertTrue(diagnosticText.contains("reloads=0"))
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

        let diagnosticText = diagnostics.value as? String ?? diagnostics.label
        XCTAssertTrue(diagnosticText.contains("reloads=0"))
        XCTAssertTrue(diagnosticText.contains("appends=2"))
        XCTAssertTrue(diagnosticText.contains("prepends=1"))
        XCTAssertTrue(diagnosticText.contains("restores=1"))
        XCTAssertLessThanOrEqual(driftValue(in: diagnosticText), 1.0)
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

        let diagnosticText = diagnostics.value as? String ?? diagnostics.label
        XCTAssertTrue(diagnosticText.contains("prepends=1"))
        XCTAssertTrue(diagnosticText.contains("restores=1"))
        XCTAssertTrue(diagnosticText.contains("reloads=0"))
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

        let diagnosticText = diagnostics.value as? String ?? diagnostics.label
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

    private func driftValue(in diagnosticText: String) -> Double {
        metricValue("drift", in: diagnosticText)
    }

    @MainActor
    func testCompactPreferenceUpdatesVisibleChatWithoutMovingAnchor() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "chatRoomV2", "-fixture", "mixedRichPrepend",
                               "-chatRoomV2DensityControl", "-chatRoomV2DecodedImages"]
        app.launch()
        let toggle = app.switches["fixture.compact.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let collection = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(collection.waitForExistence(timeout: 10))
        if toggle.value as? String == "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -25, dy: 0)).tap() }
        defer { if toggle.exists && toggle.value as? String == "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -25, dy: 0)).tap() } }
        // Read older content so the expected anchor is not clamped by the bottom edge.
        collection.swipeDown()
        let viewport = CGRect(x: app.frame.minX, y: toggle.frame.maxY,
                              width: app.frame.width, height: app.frame.maxY - toggle.frame.maxY)
        let visible = collection.cells.allElementsBoundByIndex.filter {
            $0.frame.intersects(viewport) && !$0.frame.isEmpty
        }.sorted { $0.frame.minY < $1.frame.minY }
        let anchorID = try XCTUnwrap(visible.first).identifier
        let anchor = collection.cells[anchorID]
        let before = anchor.frame
        XCTAssertGreaterThan(before.height, 10)
        let beforeShot = XCTAttachment(screenshot: app.screenshot())
        beforeShot.name = "V5-comfortable-mixed-messages"
        beforeShot.lifetime = .keepAlways
        add(beforeShot)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -25, dy: 0)).tap()
        let afterShot = XCTAttachment(screenshot: app.screenshot())
        afterShot.name = "V5-density-after-toggle"
        afterShot.lifetime = .keepAlways
        add(afterShot)
        XCTAssertEqual(toggle.value as? String, "1")
        let applied = expectation(for: NSPredicate(format: "value CONTAINS %@", "density=compact"),
                                  evaluatedWith: app.staticTexts["chatRoomV2.diagnostics"])
        wait(for: [applied], timeout: 10)
        let shrunk = expectation(for: NSPredicate { _, _ in
            anchor.frame.height < before.height - 3
        }, evaluatedWith: anchor)
        wait(for: [shrunk], timeout: 10)
        XCTAssertEqual(anchor.frame.minY, before.minY, accuracy: 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "V5-compact-mixed-messages"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -25, dy: 0)).tap()
        let restored = expectation(for: NSPredicate { _, _ in
            abs(anchor.frame.height - before.height) <= 1
        }, evaluatedWith: anchor)
        wait(for: [restored], timeout: 10)
        XCTAssertEqual(anchor.frame.minY, before.minY, accuracy: 1)
        let diagnostics = app.staticTexts["chatRoomV2.diagnostics"]
        let text = diagnostics.value as? String ?? diagnostics.label
        XCTAssertTrue(text.contains("reloads=0"), text)
        XCTAssertTrue(text.contains("messages=36"), text)
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

}
