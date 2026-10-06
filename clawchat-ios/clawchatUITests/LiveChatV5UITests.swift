import XCTest
import ImageIO
import CryptoKit

/// Opt-in integration tests. Disposable credentials enter only through the local test runner environment.
final class LiveChatV5UITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testRealBrokerDisconnectPreservesDraftAndRecovers() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["V5_TEST_NETWORK_CONTROL"] != "1", "Requires the coordinated isolated-broker stop/start runner")
        let app = XCUIApplication()
        try login(app: app, env: env, baseURL: XCTUnwrap(env["V5_TEST_BASE_URL"]), botID: XCTUnwrap(env["V5_TEST_BOT_ID"]))
        let ready = "V5 reconnect ready \(UUID().uuidString.prefix(8))"
        send(ready, app: app)
        expectReply(ready, app: app)
        let draft = "V5 preserved draft \(UUID().uuidString.prefix(8))"
        let input = app.descendants(matching: .any)["chat.composer.input"].firstMatch
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        input.typeText(draft)
        let sendButton = app.buttons["chat.send"]
        XCTAssertTrue(sendButton.isEnabled)
        print("V5_NETWORK_STOP_BROKER")
        let disconnected = expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: sendButton)
        wait(for: [disconnected], timeout: 45)
        XCTAssertEqual(input.value as? String, draft)
        attach(app, name: "V5-live-disconnected-draft")
        print("V5_NETWORK_START_BROKER")
        let connected = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: sendButton)
        wait(for: [connected], timeout: 90)
        XCTAssertEqual(input.value as? String, draft)
        sendButton.tap()
        expectReply(draft, app: app)
        attach(app, name: "V5-live-reconnected-echo")
    }

    @MainActor func testRealPhotoPickerUploadEchoAndHistory() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["V5_TEST_USERNAME"] == nil, "Requires the opt-in local integration environment and a seeded simulator photo")
        let app = XCUIApplication()
        let baseURL = try XCTUnwrap(env["V5_TEST_BASE_URL"])
        let botID = try XCTUnwrap(env["V5_TEST_BOT_ID"])
        try login(app: app, env: env, baseURL: baseURL, botID: botID)
        var lastMarker = ""
        for original in [false, true] {
            let marker = "V5 photo \(original ? "original" : "compressed") \(UUID().uuidString.prefix(8))"
            lastMarker = marker
            let input = app.descendants(matching: .any)["chat.composer.input"].firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 15))
            input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
            input.typeText(marker)
            app.buttons["chat.attachments"].tap()
            app.buttons["Photo"].tap()
            let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
            XCTAssertTrue(photo.waitForExistence(timeout: 30))
            XCTAssertFalse(photo.frame.isEmpty)
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.images["chat.photo.preview"].waitForExistence(timeout: 20))
            app.buttons["chat.photo.quality"].tap()
            app.buttons["chat.photo.quality.\(original ? "Original" : "Compressed")"].tap()
            app.buttons["chat.photo.send"].tap()
            expectReply(marker, app: app)
            try await assertPersistedMedia(marker: marker, kind: "image", env: env)
            XCTAssertFalse(app.alerts.firstMatch.exists)
            let reply = app.collectionViews["chatRoomV2.collectionView"].cells.matching(NSPredicate(format: "label CONTAINS %@", "Echo: \(marker)")).firstMatch
            let image = reply.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH %@", "-image-0")).firstMatch
            XCTAssertTrue(image.waitForExistence(timeout: 15))
            image.tap()
            XCTAssertTrue(app.buttons["chat.imagePreview.close"].waitForExistence(timeout: 10))
            attach(app, name: "V5-live-photo-\(original ? "original" : "compressed")")
            app.buttons["chat.imagePreview.close"].tap()
        }
        app.terminate()
        app.launchArguments = ["-settings.languageMode", "english", "-openclawApiBaseURL", baseURL]
        app.launch()
        XCTAssertTrue(app.buttons["home.bot.\(botID)"].waitForExistence(timeout: 20))
        app.buttons["home.bot.\(botID)"].tap()
        expectReply(lastMarker, app: app)
        attach(app, name: "V5-live-photo-history")
    }

    @MainActor func testImageQualityPreferenceControlsRealUploadedBytes() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["V5_TEST_PHOTO_SOURCE_PATH"] == nil, "Requires a newly seeded 4096×3072 PNG on the dedicated simulator")
        let source = try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(env["V5_TEST_PHOTO_SOURCE_PATH"])))
        let app = XCUIApplication()
        let base = try XCTUnwrap(env["V5_TEST_BASE_URL"])
        let bot = try XCTUnwrap(env["V5_TEST_BOT_ID"])
        try login(app: app, env: env, baseURL: base, botID: bot)
        var lengths: [String: Int] = [:]
        let cases = [("Compressed", "Compressed"), ("Balanced", "Balanced"), ("Original", "Original"), ("Balanced", "Compressed")]
        for (index, entry) in cases.enumerated() {
            let (preference, sending) = entry
            app.buttons["chat.back"].tap()
            app.buttons["home.account"].tap()
            app.buttons["home.menu.settings"].tap()
            let quality = app.buttons["settings.imageQuality"]
            XCTAssertTrue(quality.waitForExistence(timeout: 15))
            for _ in 0..<8 where !quality.isHittable { app.scrollViews.firstMatch.swipeUp() }
            quality.tap()
            app.buttons[preference].tap()
            XCTAssertEqual(quality.value as? String, preference)
            if index == 1 { attach(app, name: "V5-image-quality-settings-balanced") }
            app.buttons["home.utility.close"].tap()
            app.buttons["home.bot.\(bot)"].tap()
            let marker = "V5 quality \(preference)-\(sending)-\(UUID().uuidString.prefix(8))"
            let input = app.descendants(matching: .any)["chat.composer.input"].firstMatch
            input.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10)); input.typeText(marker)
            openPhotoPreview(app)
            let menu = app.buttons["chat.photo.quality"]
            XCTAssertEqual(menu.value as? String, preference, "Preview must inherit the persisted Settings choice")
            if sending != preference {
                menu.tap(); app.buttons["chat.photo.quality.\(sending)"].tap()
                XCTAssertEqual(menu.value as? String, sending)
            }
            attach(app, name: "V5-image-quality-preview-\(index)-\(sending)")
            app.buttons["chat.photo.send"].tap()
            expectReply(marker, app: app)
            let content = try await assertPersistedMedia(marker: marker, kind: "image", env: env)
            let meta = try XCTUnwrap(content["meta"] as? [String: Any])
            let asset = try XCTUnwrap(meta["asset"] as? [String: Any])
            let download = try XCTUnwrap(URL(string: XCTUnwrap(content["url"] as? String)))
            let (bytes, response) = try await URLSession.shared.data(from: download)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(content["size"] as? Int, bytes.count)
            XCTAssertEqual(asset["size"] as? Int, bytes.count)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            // The existing asset API exposes an optional digest. Downloaded bytes are authoritative.
            if let recordedDigest = asset["sha256"] as? String { XCTAssertEqual(recordedDigest, digest) }
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
            let expectedWidth = sending == "Compressed" ? 2000 : sending == "Balanced" ? 3000 : 4096
            let expectedHeight = sending == "Compressed" ? 1500 : sending == "Balanced" ? 2250 : 3072
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, expectedWidth)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, expectedHeight)
            XCTAssertEqual(meta["width"] as? Int, expectedWidth)
            XCTAssertEqual(meta["height"] as? Int, expectedHeight)
            XCTAssertEqual(asset["mime_type"] as? String, sending == "Original" ? "image/png" : "image/jpeg")
            if sending == "Original" { XCTAssertEqual(bytes, source, "Original must preserve the exact transferred PNG") }
            if index < 3 { lengths[sending] = bytes.count }
            print("V5_IMAGE_QUALITY_READBACK mode=\(sending) pixels=\(expectedWidth)x\(expectedHeight) bytes=\(bytes.count) preference=\(preference) sha256=\(digest)")
        }
        XCTAssertLessThan(try XCTUnwrap(lengths["Compressed"]), try XCTUnwrap(lengths["Balanced"]))
        XCTAssertEqual(try XCTUnwrap(lengths["Original"]), source.count)
        // A per-image override must not overwrite Settings, including after a cold launch.
        app.terminate()
        app.launchArguments = ["-settings.languageMode", "english", "-openclawApiBaseURL", base]
        app.launch()
        XCTAssertTrue(app.buttons["home.bot.\(bot)"].waitForExistence(timeout: 20))
        app.buttons["home.bot.\(bot)"].tap()
        openPhotoPreview(app)
        XCTAssertEqual(app.buttons["chat.photo.quality"].value as? String, "Balanced")
        attach(app, name: "V5-image-quality-cold-restored-balanced")
        app.buttons["chat.photo.cancel"].tap()
    }

    @MainActor private func openPhotoPreview(_ app: XCUIApplication) {
        app.buttons["chat.attachments"].tap(); app.buttons["Photo"].tap()
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 30))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.images["chat.photo.preview"].waitForExistence(timeout: 20))
    }

    @MainActor func testRealLoginDirectGroupEchoAndSessionRestore() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["V5_TEST_USERNAME"] == nil, "Requires the opt-in local integration environment")
        let username = try XCTUnwrap(env["V5_TEST_USERNAME"], "Use the isolated local acceptance runner")
        let password = try XCTUnwrap(env["V5_TEST_PASSWORD"])
        let botID = try XCTUnwrap(env["V5_TEST_BOT_ID"])
        let groupID = try XCTUnwrap(env["V5_TEST_GROUP_ID"])
        let baseURL = try XCTUnwrap(env["V5_TEST_BASE_URL"])
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetState", "-openclawApiBaseURL", baseURL]
        app.launch()
        let usernameField = app.textFields["Email or username"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 15))
        usernameField.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 15) { usernameField.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15))
        usernameField.typeText(username)
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText(password)
        app.buttons["Login"].tap()
        let bot = app.buttons["home.bot.\(botID)"]
        XCTAssertTrue(bot.waitForExistence(timeout: 20))
        bot.tap()
        let marker = "V5 live \(UUID().uuidString.prefix(8))"
        send(marker, app: app)
        expectReply(marker, app: app)
        attach(app, name: "V5-live-direct-echo")

        // Opt-in expiry acceptance: the local server can use a short credential TTL.
        // Keep the conversation open beyond that TTL, then require a real broker reply.
        if let rawWait = env["V5_TEST_RENEWAL_WAIT_SECONDS"], let seconds = Int(rawWait), (1...330).contains(seconds) {
            try await Task.sleep(for: .seconds(seconds))
            let renewedMarker = "V5 renewed \(UUID().uuidString.prefix(8))"
            send(renewedMarker, app: app)
            expectReply(renewedMarker, app: app)
            attach(app, name: "V5-live-after-credential-expiry")
        }

        app.terminate()
        app.launchArguments = ["-openclawApiBaseURL", baseURL]
        app.launch()
        XCTAssertTrue(app.buttons["home.search"].waitForExistence(timeout: 20))
        app.buttons["home.bot.\(botID)"].tap()
        expectReply(marker, app: app)
        app.buttons["chat.back"].tap()
        app.buttons["home.account"].tap()
        app.buttons["home.menu.contacts"].tap()
        app.buttons["Groups"].tap()
        let group = app.buttons["contacts.group.\(groupID)"]
        XCTAssertTrue(group.waitForExistence(timeout: 15))
        group.tap()
        let groupMarker = "V5 group \(UUID().uuidString.prefix(8))"
        send(groupMarker, app: app)
        expectReply(groupMarker, app: app)
        attach(app, name: "V5-live-group-echo")
    }

    @MainActor func testRealFilePickerUploadEchoAndPreview() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["V5_TEST_USERNAME"] == nil, "Requires the opt-in local integration environment and V5-attachment.txt in simulator Files")
        let app = XCUIApplication()
        let baseURL = try XCTUnwrap(env["V5_TEST_BASE_URL"])
        let botID = try XCTUnwrap(env["V5_TEST_BOT_ID"])
        try login(app: app, env: env, baseURL: baseURL, botID: botID)
        let marker = "V5 file \(UUID().uuidString.prefix(8))"
        let input = app.descendants(matching: .any)["chat.composer.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        input.typeText(marker)
        app.buttons["chat.attachments"].tap()
        app.buttons["chat.file.attach"].tap()
        let file = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "V5-attachment,")).firstMatch
        if !file.waitForExistence(timeout: 5) {
            let browse = app.tabBars["DOC.browsingModeTabBar"].buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
            XCTAssertTrue(browse.waitForExistence(timeout: 20))
            browse.tap()
            // Files can restore the local folder directly when Browse is selected.
            if !file.waitForExistence(timeout: 5) {
                let local = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "On My iPhone", "我的iPhone")).firstMatch
                XCTAssertTrue(local.waitForExistence(timeout: 15))
                local.tap()
            }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        file.tap()
        expectReply(marker, app: app)
        try await assertPersistedMedia(marker: marker, kind: "file", env: env)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let sent = app.collectionViews["chatRoomV2.collectionView"].cells.matching(NSPredicate(format: "label == %@", marker)).firstMatch
        let attachment = sent.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", "-file-0")).firstMatch
        XCTAssertTrue(attachment.waitForExistence(timeout: 10))
        attachment.tap()
        XCTAssertTrue(app.buttons["chat.file.share"].waitForExistence(timeout: 20))
        let text = app.textViews["chat.file.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue((text.value as? String)?.contains("ClawChat V5 attachment acceptance") == true)
        attach(app, name: "V5-live-file-upload-preview")
        app.buttons["Done"].tap()
        XCTAssertTrue(attachment.waitForExistence(timeout: 5))
    }

    @discardableResult
    @MainActor private func assertPersistedMedia(marker: String, kind: String, env: [String: String]) async throws -> [String: Any] {
        let base = try XCTUnwrap(env["V5_TEST_BASE_URL"])
        let bot = try XCTUnwrap(env["V5_TEST_BOT_ID"])
        var login = URLRequest(url: try XCTUnwrap(URL(string: base + "/api/v1/auth/login")))
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONSerialization.data(withJSONObject: ["username": try XCTUnwrap(env["V5_TEST_USERNAME"]), "password": try XCTUnwrap(env["V5_TEST_PASSWORD"])])
        let authData = try await requestData(login)
        let auth = try XCTUnwrap(authData as? [String: Any])
        let tokens = try XCTUnwrap(auth["tokens"] as? [String: Any])
        let token = try XCTUnwrap(tokens["access_token"] as? String)
        let user = try XCTUnwrap(auth["user"] as? [String: Any])
        let userID = try XCTUnwrap(user["id"] as? String)
        var history = URLRequest(url: try XCTUnwrap(URL(string: base + "/api/v1/messages/chat/dm/user/\(userID)/bot/\(bot)?limit=50")))
        history.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for _ in 0..<20 {
            let historyData = try await requestData(history)
            let messages = try XCTUnwrap(historyData as? [[String: Any]])
            let sent = messages.first { ($0["content"] as? [String: Any])?["body"] as? String == marker }
            let reply = messages.first { ($0["content"] as? [String: Any])?["body"] as? String == "Echo: \(marker)" }
            if let sent, let reply {
                XCTAssertGreaterThan(try XCTUnwrap(reply["seq"] as? Int), try XCTUnwrap(sent["seq"] as? Int))
                let sentContent = try XCTUnwrap(sent["content"] as? [String: Any])
                let replyContent = try XCTUnwrap(reply["content"] as? [String: Any])
                XCTAssertEqual(sentContent["type"] as? String, kind)
                XCTAssertEqual(replyContent["type"] as? String, kind == "file" ? "text" : kind)
                if kind == "image" {
                    let sourceAsset = (sentContent["meta"] as? [String: Any])?["asset"] as? [String: Any]
                    let replyAsset = (replyContent["meta"] as? [String: Any])?["asset"] as? [String: Any]
                    XCTAssertNotEqual(try XCTUnwrap(sourceAsset?["id"] as? String), try XCTUnwrap(replyAsset?["id"] as? String))
                }
                return sentContent
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("The server must persist both the uploaded media and the valid bot reply; local cache is insufficient")
        return [:]
    }

    @MainActor private func requestData(_ request: URLRequest) async throws -> Any {
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(envelope["data"])
    }

    @MainActor private func login(app: XCUIApplication, env: [String: String], baseURL: String, botID: String) throws {
        app.launchArguments = ["-uiTestResetState", "-settings.languageMode", "english", "-openclawApiBaseURL", baseURL]
        app.launch()
        let username = app.textFields["Email or username"]
        XCTAssertTrue(username.waitForExistence(timeout: 15))
        username.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15))
        username.typeText(try XCTUnwrap(env["V5_TEST_USERNAME"]))
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText(try XCTUnwrap(env["V5_TEST_PASSWORD"]))
        app.buttons["Login"].tap()
        XCTAssertTrue(app.buttons["home.bot.\(botID)"].waitForExistence(timeout: 20))
        app.buttons["home.bot.\(botID)"].tap()
    }

    @MainActor private func send(_ message: String, app: XCUIApplication) {
        let input = app.descendants(matching: .any)["chat.composer.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        input.typeText(message)
        let send = app.buttons["chat.send"]
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        wait(for: [ready], timeout: 20)
        send.tap()
    }

    @MainActor private func expectReply(_ message: String, app: XCUIApplication) {
        let reply = app.collectionViews["chatRoomV2.collectionView"].cells.matching(NSPredicate(format: "label CONTAINS %@", "Echo: \(message)")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 25), "Real broker echo must arrive and persist")
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
