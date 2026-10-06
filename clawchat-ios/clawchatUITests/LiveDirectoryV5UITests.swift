import XCTest
import UIKit

final class LiveDirectoryV5UITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testBotKeyCreationAndRevocationThroughRealUI() async throws {
        let account = try await register()
        let (created, status) = try await request(account, path: "/api/v1/bots", method: "POST", body: ["name": "V5 Key Acceptance"])
        XCTAssertEqual(status, 201)
        let botID = try XCTUnwrap((created as? [String: Any])?["id"] as? String).lowercased()
        cleanup(account, path: "/api/v1/bots/" + botID)
        let app = login(account)
        openBotChat(app, botID: botID)
        app.buttons["Bot settings"].tap()
        let scroll = app.scrollViews["bot.settings.scroll"]
        XCTAssertTrue(app.staticTexts["Enabled"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["online"].exists, "An enabled but unused bot must not claim runtime presence")
        let newKey = app.buttons["bot.keys.create"]
        reveal(newKey, scroll: scroll, app: app)
        newKey.tap()
        app.alerts["New key"].buttons["Cancel"].tap()
        let (before, _) = try await request(account, path: "/api/v1/bots/\(botID)/keys")
        XCTAssertEqual((before as? [[String: Any]])?.count, 0)

        newKey.tap()
        app.alerts["New key"].textFields.firstMatch.typeText("iOS acceptance")
        app.alerts["New key"].buttons["Generate"].tap()
        let generated = app.alerts["Key generated"]
        XCTAssertTrue(generated.waitForExistence(timeout: 15), "The server creation response must decode and reveal the one-time key")
        // Read in memory only. Never attach a screenshot with the plaintext key
        // or print the secret/returned broker credentials to test logs.
        let text = generated.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        let range = try XCTUnwrap(text.range(of: "ocbk_[A-Za-z0-9_-]+", options: .regularExpression))
        let key = String(text[range])
        UIPasteboard.general.string = "V5 empty key clipboard"
        defer { UIPasteboard.general.items = [] }
        generated.buttons["Copy and close"].tap()
        absent(generated)
        // Compare in memory as a Boolean: XCTAssertEqual would print the secret
        // in a failing assertion. Never attach the generated-key alert.
        // Cross-app clipboard access can synchronously wait for iOS approval.
        // Keep the runner's UI thread free to answer that real system prompt.
        let clipboardRead = ClipboardComparison()
        Task.detached { clipboardRead.finish(UIPasteboard.general.string == key) }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let runner = XCUIApplication(bundleIdentifier: "site.changer.clawchatUITests.xctrunner")
        let allowLabel = NSPredicate(format: "label IN %@", ["Allow Paste", "允许粘贴"])
        let deadline = Date().addingTimeInterval(30)
        while clipboardRead.result == nil && Date() < deadline {
            // The clipboard permission may appear after the first snapshot;
            // depending on iOS it is exposed by SpringBoard or the requesting
            // test runner. Keep polling while the background read is pending.
            for surface in [springboard, runner, app] {
                let allowPaste = surface.buttons.matching(allowLabel).firstMatch
                if allowPaste.exists { allowPaste.tap(); break }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let matches = try XCTUnwrap(clipboardRead.result, "System clipboard read must finish after handling paste permission")
        XCTAssertTrue(matches, "Copy and close must put the exact one-time key on the system clipboard")
        let (rows, listStatus) = try await request(account, path: "/api/v1/bots/\(botID)/keys")
        XCTAssertEqual(listStatus, 200)
        let keys = try XCTUnwrap(rows as? [[String: Any]])
        XCTAssertEqual(keys.count, 1)
        let record = try XCTUnwrap(keys.first)
        let keyID = try XCTUnwrap(record["id"] as? String).lowercased()
        XCTAssertEqual(record["name"] as? String, "iOS acceptance")
        XCTAssertEqual(record["is_active"] as? Bool, true)
        XCTAssertNil(record["key"], "Listing must never return the one-time secret")
        let activeStatus = try await botBootstrapStatus(base: account.base, key: key)
        XCTAssertEqual(activeStatus, 200)
        attach("V5-live-key-active")

        let revoke = app.buttons["bot.key.revoke." + keyID]
        reveal(revoke, scroll: scroll, app: app)
        revoke.tap()
        let state = app.staticTexts["bot.key.state." + keyID]
        let revoked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Revoked"), object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [revoked], timeout: 15), .completed)
        XCTAssertFalse(revoke.exists)
        let (after, afterStatus) = try await request(account, path: "/api/v1/bots/\(botID)/keys")
        XCTAssertEqual(afterStatus, 200)
        let stored = try XCTUnwrap((after as? [[String: Any]])?.first { $0["id"] as? String == keyID })
        XCTAssertEqual(stored["is_active"] as? Bool, false)
        let revokedStatus = try await botBootstrapStatus(base: account.base, key: key)
        XCTAssertEqual(revokedStatus, 401)
        attach("V5-live-key-revoked")
        app.navigationBars.buttons["Back"].tap()
        app.buttons["Bot settings"].tap()
        reveal(state, scroll: scroll, app: app)
        XCTAssertEqual(state.label, "Revoked")
        XCTAssertFalse(revoke.exists)
        XCTAssertFalse(app.alerts["Key generated"].exists)
    }

    private final class ClipboardComparison: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        var result: Bool? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func finish(_ matches: Bool) {
            lock.lock(); defer { lock.unlock() }
            value = matches
        }
    }

    private func botBootstrapStatus(base: String, key: String) async throws -> Int {
        var request = URLRequest(url: try XCTUnwrap(URL(string: base + "/api/v1/bot-runtime/bootstrap")))
        request.setValue(key, forHTTPHeaderField: "X-Bot-Key")
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    @MainActor func testManualBotBindingRejectsInvalidForeignAndReusedCodes() async throws {
        let account = try await register()
        let (created, status) = try await request(account, path: "/api/v1/bots", method: "POST", body: ["name": "V5 Binding Acceptance"])
        XCTAssertEqual(status, 201)
        let botID = try XCTUnwrap((created as? [String: Any])?["id"] as? String).lowercased()
        cleanup(account, path: "/api/v1/bots/" + botID)
        let (binding, bindingStatus) = try await request(account, path: "/api/v1/bots/\(botID)/bindings", method: "POST")
        XCTAssertEqual(bindingStatus, 201)
        let token = try XCTUnwrap((binding as? [String: Any])?["token"] as? String)
        let app = login(account)

        openBindingScanner(in: app)
        XCTAssertFalse(app.buttons["bot.binding.submit"].isEnabled)
        enterBinding("not a binding code", in: app)
        XCTAssertTrue(app.staticTexts["This QR content is not recognized."].waitForExistence(timeout: 5))
        attach("V5-live-binding-invalid")
        app.navigationBars.buttons["Cancel"].tap()
        openBindingScanner(in: app)
        enterBinding("https://other.example.invalid/openclaw/bind?token=" + token, in: app)
        let failure = app.alerts["Add failed"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertTrue(failure.staticTexts["This QR code belongs to another server. Switch the server on the login screen first."].exists)
        attach("V5-live-binding-foreign-server")
        failure.buttons["OK"].tap()
        let (_, unusedStatus) = try await request(account, path: "/api/v1/bot-bindings/preview?token=" + token)
        XCTAssertEqual(unusedStatus, 200, "A foreign QR must not consume the token on the authenticated server")

        openBindingScanner(in: app)
        enterBinding(account.base + "/openclaw/bind?token=" + token, in: app)
        let success = app.alerts["Bot added"]
        XCTAssertTrue(success.waitForExistence(timeout: 15))
        XCTAssertTrue(success.staticTexts["Added \"V5 Binding Acceptance\". You can use it from Contacts or Chats."].exists)
        success.buttons["OK"].tap()
        let (_, usedStatus) = try await request(account, path: "/api/v1/bot-bindings/preview?token=" + token)
        XCTAssertEqual(usedStatus, 400, "Successful UI binding must consume its one-time token")
        XCTAssertEqual(app.buttons.matching(identifier: "home.bot." + botID).count, 1)
        attach("V5-live-binding-success")

        openBindingScanner(in: app)
        enterBinding(account.base + "/openclaw/bind?token=" + token, in: app)
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        XCTAssertTrue(failure.staticTexts["binding token already used"].exists)
        attach("V5-live-binding-reused")
        failure.buttons["OK"].tap()
        let quick = app.buttons["home.bot." + botID]
        XCTAssertTrue(quick.isHittable)
        quick.tap()
        XCTAssertTrue(app.buttons["Bot settings"].waitForExistence(timeout: 10))
    }

    @MainActor private func openBindingScanner(in app: XCUIApplication) {
        app.buttons["home.add"].tap()
        app.buttons["Scan to add bot"].tap()
        XCTAssertTrue(app.buttons["bot.binding.submit"].waitForExistence(timeout: 10))
    }

    @MainActor private func enterBinding(_ value: String, in app: XCUIApplication) {
        let field = app.descendants(matching: .any).matching(identifier: "bot.binding.manual").firstMatch
        replace(field, with: value, app: app)
        let done = app.buttons["bot.binding.keyboard.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        if value == "not a binding code" { attach("V5-live-binding-keyboard") }
        done.tap()
        absent(app.keyboards.firstMatch)
        let submit = app.buttons["bot.binding.submit"]
        let scroll = app.scrollViews.containing(.button, identifier: "bot.binding.submit").firstMatch
        reveal(submit, scroll: scroll, app: app)
        submit.tap()
    }

    @MainActor func testBotCreateRenameAndDeleteThroughRealUI() async throws {
        let account = try await register()
        let app = login(account)
        let name = "V5 Bot " + String(UUID().uuidString.prefix(6))
        app.buttons["home.add"].tap()
        app.buttons["Create bot"].tap()
        XCTAssertTrue(app.navigationBars["Create bot"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Create"].isEnabled)
        replace(app.textFields["Bot name"], with: name, app: app)
        replace(app.textFields["Description"], with: "Created through the iOS interface", app: app)
        app.buttons["Create"].tap()
        absent(app.navigationBars["Create bot"])
        let (rows, status) = try await request(account, path: "/api/v1/bots")
        XCTAssertEqual(status, 200)
        let bot = try XCTUnwrap((rows as? [[String: Any]])?.first { $0["name"] as? String == name })
        let botID = try XCTUnwrap(bot["id"] as? String).lowercased()
        cleanup(account, path: "/api/v1/bots/" + botID)
        XCTAssertEqual(bot["description"] as? String, "Created through the iOS interface")
        let quick = app.buttons["home.bot." + botID]
        XCTAssertTrue(quick.waitForExistence(timeout: 15))
        attach("V5-live-bot-created")
        quick.tap()
        XCTAssertTrue(app.buttons["Bot settings"].waitForExistence(timeout: 15))
        app.buttons["Bot settings"].tap()
        XCTAssertTrue(app.navigationBars["Bot settings"].waitForExistence(timeout: 10))
        app.buttons["Edit"].tap()
        let updatedName = name + " Updated"
        let field = app.textFields["Bot name"]
        reveal(field, scroll: app.scrollViews["bot.settings.scroll"], app: app)
        replace(field, with: updatedName, app: app)
        reveal(app.buttons["Save"], scroll: app.scrollViews["bot.settings.scroll"], app: app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 15))
        let (saved, savedStatus) = try await request(account, path: "/api/v1/bots/" + botID)
        XCTAssertEqual(savedStatus, 200)
        XCTAssertEqual((saved as? [String: Any])?["name"] as? String, updatedName)
        app.navigationBars.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts[updatedName].waitForExistence(timeout: 10), "The current chat title must update immediately")
        attach("V5-live-bot-renamed-chat")
        app.buttons["chat.back"].tap()
        XCTAssertTrue(app.buttons["home.account"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[updatedName].waitForExistence(timeout: 15), "Home must refresh without waiting for its TTL")
        quick.tap()
        app.buttons["Bot settings"].tap()
        let delete = app.buttons["Delete bot"]
        reveal(delete, scroll: app.scrollViews["bot.settings.scroll"], app: app)
        delete.tap()
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["home.account"].waitForExistence(timeout: 15), "Deleting the bot must also leave its obsolete chat")
        absent(quick)
        let (_, deletedStatus) = try await request(account, path: "/api/v1/bots/" + botID)
        XCTAssertEqual(deletedStatus, 404)
        attach("V5-live-bot-deleted")
    }

    @MainActor func testGroupCreateRenameAddBotAndRemoveMemberThroughRealUI() async throws {
        let account = try await register()
        let member = try await register(base: account.base)
        let botName = "V5 Group Helper"
        let (botData, botStatus) = try await request(account, path: "/api/v1/bots", method: "POST", body: ["name": botName])
        XCTAssertEqual(botStatus, 201)
        let botID = try XCTUnwrap((botData as? [String: Any])?["id"] as? String).lowercased()
        cleanup(account, path: "/api/v1/bots/" + botID)
        let app = login(account)
        let name = "V5 Group " + String(UUID().uuidString.prefix(6))
        app.buttons["home.add"].tap()
        app.buttons["Create group"].tap()
        XCTAssertTrue(app.navigationBars["Create group"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Create"].isEnabled)
        replace(app.textFields["Group name"], with: name, app: app)
        replace(app.textFields["Description"], with: "Created through the iOS interface", app: app)
        app.buttons["Create"].tap()
        absent(app.navigationBars["Create group"])
        let (rows, status) = try await request(account, path: "/api/v1/groups")
        XCTAssertEqual(status, 200)
        let group = try XCTUnwrap((rows as? [[String: Any]])?.first { $0["name"] as? String == name })
        let groupID = try XCTUnwrap(group["id"] as? String).lowercased()
        cleanup(account, path: "/api/v1/groups/" + groupID)
        let (_, memberStatus) = try await request(account, path: "/api/v1/groups/\(groupID)/members", method: "POST", body: ["user_id": member.userID])
        XCTAssertEqual(memberStatus, 200)
        app.buttons["home.account"].tap()
        app.buttons["home.menu.contacts"].tap()
        app.segmentedControls.buttons["Groups"].tap()
        let row = app.buttons["contacts.group." + groupID]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.buttons["Group settings"].waitForExistence(timeout: 10))
        app.buttons["Group settings"].tap()
        let title = app.navigationBars["Group settings"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertLessThan(title.frame.height, 60)
        let updatedName = name + " Updated"
        let field = app.textFields["group.name"]
        replace(field, with: "   ", app: app)
        XCTAssertFalse(app.buttons["group.save"].isEnabled)
        replace(field, with: updatedName, app: app)
        app.buttons["group.save"].tap()
        XCTAssertTrue(app.staticTexts["Group name saved"].waitForExistence(timeout: 15))
        absent(app.keyboards.firstMatch)
        let (saved, savedStatus) = try await request(account, path: "/api/v1/groups/" + groupID)
        XCTAssertEqual(savedStatus, 200)
        XCTAssertEqual((saved as? [String: Any])?["name"] as? String, updatedName)
        XCTAssertFalse(app.buttons["group.remove." + account.userID.lowercased()].exists, "Owner removal must not be offered")
        XCTAssertFalse(app.buttons["group.leave"].exists, "Owner cannot abandon the group")
        let remove = app.buttons["group.remove." + member.userID.lowercased()]
        reveal(remove, scroll: app.scrollViews["group.settings.scroll"], app: app)
        remove.tap()
        absent(remove)
        let add = app.buttons["group.add." + botID]
        reveal(add, scroll: app.scrollViews["group.settings.scroll"], app: app)
        add.tap()
        XCTAssertTrue(app.staticTexts["Joined"].waitForExistence(timeout: 15))
        absent(add)
        let (membersData, membersStatus) = try await request(account, path: "/api/v1/groups/\(groupID)/members")
        XCTAssertEqual(membersStatus, 200)
        let membership = try XCTUnwrap(membersData as? [String: Any])
        let users = try XCTUnwrap(membership["users"] as? [[String: Any]])
        let bots = try XCTUnwrap(membership["bots"] as? [[String: Any]])
        XCTAssertFalse(users.contains { ($0["user_id"] as? String)?.lowercased() == member.userID.lowercased() })
        XCTAssertTrue(bots.contains { ($0["bot_id"] as? String)?.lowercased() == botID })
        attach("V5-live-group-members-saved")
        app.buttons["group.done"].tap()
        XCTAssertTrue(app.staticTexts[updatedName].waitForExistence(timeout: 10))
        attach("V5-live-group-renamed-chat")
        app.buttons["chat.back"].tap()
        XCTAssertTrue(app.staticTexts[updatedName].waitForExistence(timeout: 15), "Contacts must show the saved name immediately")
        app.buttons["home.utility.close"].tap()
        XCTAssertTrue(app.buttons["home.account"].waitForExistence(timeout: 10))
    }

    @MainActor func testMemberPermissionsAndLeaveCancelConfirmPersistThroughRelaunch() async throws {
        let owner = try await register()
        let member = try await register(base: owner.base)
        let peer = try await register(base: owner.base)
        let originalName = "V5 Leave Acceptance"
        let (data, createStatus) = try await request(owner, path: "/api/v1/groups", method: "POST", body: ["name": originalName])
        XCTAssertEqual(createStatus, 201)
        let groupID = try XCTUnwrap((data as? [String: Any])?["id"] as? String).lowercased()
        cleanup(owner, path: "/api/v1/groups/" + groupID)
        for user in [member, peer] {
            let (_, status) = try await request(owner, path: "/api/v1/groups/\(groupID)/members", method: "POST", body: ["user_id": user.userID])
            XCTAssertEqual(status, 200)
        }
        let app = login(member)
        openGroupSettings(app, groupID: groupID)
        XCTAssertTrue(app.staticTexts["group.name.readonly"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.textFields["group.name"].exists)
        XCTAssertFalse(app.buttons["group.save"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "group.remove.")).firstMatch.exists)
        XCTAssertFalse(app.textFields["Search bots"].exists)
        let (_, renameStatus) = try await request(member, path: "/api/v1/groups/" + groupID, method: "PUT", body: ["name": "Not allowed"])
        XCTAssertEqual(renameStatus, 403)
        let (_, removeStatus) = try await request(member, path: "/api/v1/groups/\(groupID)/members/" + peer.userID, method: "DELETE")
        XCTAssertEqual(removeStatus, 403)
        let (_, ownerLeaveStatus) = try await request(owner, path: "/api/v1/groups/\(groupID)/members/" + owner.userID, method: "DELETE")
        XCTAssertEqual(ownerLeaveStatus, 400)
        let leave = app.buttons["group.leave"]
        reveal(leave, scroll: app.scrollViews["group.settings.scroll"], app: app)
        attach("V5-live-group-member-permissions")
        leave.tap()
        XCTAssertTrue(app.alerts["Leave this group?"].buttons["Cancel"].waitForExistence(timeout: 5))
        attach("V5-live-group-leave-confirmation")
        app.alerts["Leave this group?"].buttons["Cancel"].tap()
        XCTAssertTrue(leave.waitForExistence(timeout: 5))
        var (membership, status) = try await request(owner, path: "/api/v1/groups/\(groupID)/members")
        XCTAssertEqual(status, 200)
        XCTAssertTrue(try groupUsers(membership).contains { ($0["user_id"] as? String)?.lowercased() == member.userID.lowercased() })
        leave.tap()
        let confirm = app.alerts["Leave this group?"].buttons["Leave group"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        absent(app.navigationBars["Group settings"])
        if UIDevice.current.userInterfaceIdiom == .pad {
            absent(app.collectionViews["chatRoomV2.collectionView"])
            absent(app.buttons["ipad.group." + groupID])
            XCTAssertTrue(app.staticTexts["No groups yet"].waitForExistence(timeout: 15))
        } else {
            XCTAssertTrue(app.segmentedControls.buttons["Groups"].waitForExistence(timeout: 15), "Leaving must close the obsolete chat, not leave a sendable room")
            absent(app.buttons["contacts.group." + groupID])
        }
        (membership, status) = try await request(owner, path: "/api/v1/groups/\(groupID)/members")
        XCTAssertEqual(status, 200)
        let remaining = try groupUsers(membership)
        XCTAssertFalse(remaining.contains { ($0["user_id"] as? String)?.lowercased() == member.userID.lowercased() })
        XCTAssertTrue(remaining.contains { ($0["user_id"] as? String)?.lowercased() == owner.userID.lowercased() })
        let (_, historyStatus) = try await request(member, path: "/api/v1/messages?conversation_id=chat/group/" + groupID + "&limit=1")
        XCTAssertEqual(historyStatus, 403)
        let (bootstrap, bootstrapStatus) = try await request(member, path: "/api/v1/realtime/bootstrap")
        XCTAssertEqual(bootstrapStatus, 200)
        let subscriptions = try XCTUnwrap((bootstrap as? [String: Any])?["subscriptions"] as? [[String: Any]])
        XCTAssertFalse(subscriptions.contains { $0["topic"] as? String == "chat/group/" + groupID })
        attach("V5-live-group-left")
        app.terminate()
        let relaunched = login(member)
        if UIDevice.current.userInterfaceIdiom == .pad {
            relaunched.buttons["ipad.section.groups"].tap()
        } else {
            relaunched.buttons["home.account"].tap()
            relaunched.buttons["home.menu.contacts"].tap()
            relaunched.segmentedControls.buttons["Groups"].tap()
        }
        XCTAssertTrue(relaunched.staticTexts["No groups yet"].waitForExistence(timeout: 15))
        XCTAssertFalse(relaunched.buttons["contacts.group." + groupID].exists)
        XCTAssertFalse(relaunched.buttons["ipad.group." + groupID].exists)
        attach("V5-live-group-left-relaunch")
    }

    @MainActor func testAdminCanManageMembersButCannotRenameOrRemoveOwner() async throws {
        let owner = try await register()
        let admin = try await register(base: owner.base)
        let member = try await register(base: owner.base)
        let (data, status) = try await request(owner, path: "/api/v1/groups", method: "POST", body: ["name": "V5 Admin Acceptance"])
        XCTAssertEqual(status, 201)
        let groupID = try XCTUnwrap((data as? [String: Any])?["id"] as? String).lowercased()
        cleanup(owner, path: "/api/v1/groups/" + groupID)
        for (user, role) in [(admin, "admin"), (member, "member")] {
            let (_, addStatus) = try await request(owner, path: "/api/v1/groups/\(groupID)/members", method: "POST", body: ["user_id": user.userID, "role": role])
            XCTAssertEqual(addStatus, 200)
        }
        let (botData, botStatus) = try await request(admin, path: "/api/v1/bots", method: "POST", body: ["name": "V5 Admin Helper"])
        XCTAssertEqual(botStatus, 201)
        let botID = try XCTUnwrap((botData as? [String: Any])?["id"] as? String).lowercased()
        cleanup(admin, path: "/api/v1/bots/" + botID)
        let app = login(admin)
        openGroupSettings(app, groupID: groupID)
        XCTAssertTrue(app.staticTexts["group.name.readonly"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["group.save"].exists)
        XCTAssertFalse(app.buttons["group.remove." + owner.userID.lowercased()].exists)
        XCTAssertFalse(app.buttons["group.remove." + admin.userID.lowercased()].exists)
        let remove = app.buttons["group.remove." + member.userID.lowercased()]
        reveal(remove, scroll: app.scrollViews["group.settings.scroll"], app: app)
        remove.tap()
        absent(remove)
        let add = app.buttons["group.add." + botID]
        reveal(add, scroll: app.scrollViews["group.settings.scroll"], app: app)
        add.tap()
        XCTAssertTrue(app.staticTexts["Joined"].waitForExistence(timeout: 15))
        let (membership, membershipStatus) = try await request(owner, path: "/api/v1/groups/\(groupID)/members")
        XCTAssertEqual(membershipStatus, 200)
        XCTAssertFalse(try groupUsers(membership).contains { ($0["user_id"] as? String)?.lowercased() == member.userID.lowercased() })
        let bots = try XCTUnwrap((membership as? [String: Any])?["bots"] as? [[String: Any]])
        XCTAssertTrue(bots.contains { ($0["bot_id"] as? String)?.lowercased() == botID })
        XCTAssertTrue(app.buttons["group.leave"].exists)
        attach("V5-live-group-admin-permissions")
    }

    @MainActor func testAccountSwitchKeepsBotsGroupsAndMessageHistorySeparate() async throws {
        let a = try await register()
        let b = try await register(base: a.base)
        var botIDs: [String] = [], groupIDs: [String] = []
        for (account, name) in [(a, "V5 Account A"), (b, "V5 Account B")] {
            let (bot, botStatus) = try await request(account, path: "/api/v1/bots", method: "POST", body: ["name": name])
            XCTAssertEqual(botStatus, 201)
            let botID = try XCTUnwrap((bot as? [String: Any])?["id"] as? String).lowercased()
            botIDs.append(botID); cleanup(account, path: "/api/v1/bots/" + botID)
            let (group, groupStatus) = try await request(account, path: "/api/v1/groups", method: "POST", body: ["name": name + " private group"])
            XCTAssertEqual(groupStatus, 201)
            let groupID = try XCTUnwrap((group as? [String: Any])?["id"] as? String).lowercased()
            groupIDs.append(groupID); cleanup(account, path: "/api/v1/groups/" + groupID)
        }
        let app = login(a)
        let markerA = "Account A private " + UUID().uuidString.prefix(8)
        let markerB = "Account B private " + UUID().uuidString.prefix(8)
        try await verifyAccountChat(app, account: a, botID: botIDs[0], marker: markerA, sending: true)
        verifyGroups(app, own: groupIDs[0], other: groupIDs[1])
        logOut(app)
        // Intentionally reuse the running application: no reset, reinstall or
        // launch flags may clear the caches between these identities.
        signIn(b, app: app)
        verifyBotDirectory(app, own: botIDs[1], other: botIDs[0])
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", markerA)).firstMatch.exists)
        verifyGroups(app, own: groupIDs[1], other: groupIDs[0])
        try await verifyAccountChat(app, account: b, botID: botIDs[1], marker: markerB, sending: true)
        attach("V5-live-account-B-isolated")
        logOut(app)
        signIn(a, app: app)
        verifyBotDirectory(app, own: botIDs[0], other: botIDs[1])
        verifyGroups(app, own: groupIDs[0], other: groupIDs[1])
        try await verifyAccountChat(app, account: a, botID: botIDs[0], marker: markerA, sending: false)
        attach("V5-live-account-A-restored")
        // Preserve authentication and disk cache across a real process restart.
        app.terminate()
        app.launchArguments = ["-settings.languageMode", "english", "-openclawApiBaseURL", a.base]
        app.launch()
        let home = UIDevice.current.userInterfaceIdiom == .pad ? "ipad.section.home" : "home.account"
        XCTAssertTrue(app.buttons[home].waitForExistence(timeout: 20))
        verifyBotDirectory(app, own: botIDs[0], other: botIDs[1])
        try await verifyAccountChat(app, account: a, botID: botIDs[0], marker: markerA, sending: false)
        attach("V5-live-account-A-cold-restored")
    }

    @MainActor private func verifyAccountChat(_ app: XCUIApplication, account: Account, botID: String, marker: String, sending: Bool) async throws {
        openBotChat(app, botID: botID)
        let messages = app.collectionViews["chatRoomV2.collectionView"]
        XCTAssertTrue(messages.waitForExistence(timeout: 15))
        if sending {
            let input = app.descendants(matching: .any)["chat.composer.input"].firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 15)); input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10)); input.typeText(marker)
            let send = app.buttons["chat.send"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed); send.tap()
        }
        XCTAssertTrue(messages.cells.containing(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch.waitForExistence(timeout: 15))
        let otherPrefix = marker.contains("Account A") ? "Account B private" : "Account A private"
        XCTAssertFalse(messages.cells.containing(NSPredicate(format: "label CONTAINS %@", otherPrefix)).firstMatch.exists)
        let conversation = "chat/dm/user/\(account.userID.lowercased())/bot/\(botID)"
        var persisted = false
        for _ in 0..<30 {
            let (history, status) = try await request(account, path: "/api/v1/messages?conversation_id=" + conversation + "&limit=20")
            XCTAssertEqual(status, 200)
            if let rows = history as? [[String: Any]], rows.contains(where: { ($0["content"] as? [String: Any])?["body"] as? String == marker }) {
                persisted = true; break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(persisted, "The broker message must persist in the actual account's server history")
        app.buttons["chat.back"].tap()
    }

    @MainActor private func verifyBotDirectory(_ app: XCUIApplication, own: String, other: String) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(app.buttons["ipad.section.home"].isSelected, "Login must reset the previous account's selected section")
            XCTAssertFalse(app.collectionViews["chatRoomV2.collectionView"].exists)
            app.buttons["ipad.section.bots"].tap()
        }
        let prefix = UIDevice.current.userInterfaceIdiom == .pad ? "ipad.bot." : "home.bot."
        XCTAssertTrue(app.buttons[prefix + own].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons[prefix + other].exists)
        XCTAssertFalse(app.staticTexts["暂无消息"].exists)
    }

    @MainActor private func openBotChat(_ app: XCUIApplication, botID: String) {
        if UIDevice.current.userInterfaceIdiom == .pad { app.buttons["ipad.section.bots"].tap() }
        let prefix = UIDevice.current.userInterfaceIdiom == .pad ? "ipad.bot." : "home.bot."
        let row = app.buttons[prefix + botID]
        XCTAssertTrue(row.waitForExistence(timeout: 20)); row.tap()
        if UIDevice.current.userInterfaceIdiom == .pad {
            let start = app.buttons["ipad.entity.start-chat"]
            XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        }
    }

    @MainActor private func verifyGroups(_ app: XCUIApplication, own: String, other: String) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            app.buttons["ipad.section.groups"].tap()
            let row = app.buttons["ipad.group." + own]
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["ipad.group." + other].exists)
            XCTAssertTrue(row.staticTexts["No messages yet"].exists || row.label.contains("No messages yet"))
            XCTAssertFalse(app.staticTexts["暂无消息"].exists)
            row.tap()
            XCTAssertTrue(app.staticTexts["1 member"].firstMatch.waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["bots online"].exists)
            XCTAssertFalse(app.staticTexts["Bot presence"].exists)
            XCTAssertFalse(app.staticTexts["MQTT topic"].exists)
            attach("V5-live-account-group-English")
            app.buttons["ipad.section.home"].tap()
            return
        }
        app.buttons["home.account"].tap(); app.buttons["home.menu.contacts"].tap()
        app.segmentedControls.buttons["Groups"].tap()
        XCTAssertTrue(app.buttons["contacts.group." + own].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["contacts.group." + other].exists)
        app.buttons["home.utility.close"].tap()
    }

    @MainActor private func logOut(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            app.buttons["ipad.section.settings"].tap()
        } else {
            app.buttons["home.account"].tap(); app.buttons["home.menu.settings"].tap()
        }
        let logout = app.buttons["settings.logout-button"]
        reveal(logout, scroll: app.scrollViews.containing(.button, identifier: "settings.logout-button").firstMatch, app: app)
        logout.tap()
        XCTAssertTrue(app.textFields["Email or username"].waitForExistence(timeout: 15))
    }

    private func groupUsers(_ value: Any?) throws -> [[String: Any]] {
        try XCTUnwrap((value as? [String: Any])?["users"] as? [[String: Any]])
    }

    @MainActor private func openGroupSettings(_ app: XCUIApplication, groupID: String) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            app.buttons["ipad.section.groups"].tap()
            let row = app.buttons["ipad.group." + groupID]
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.tap()
            let start = app.buttons["ipad.entity.start-chat"]
            XCTAssertTrue(start.waitForExistence(timeout: 10))
            start.tap()
        } else {
        app.buttons["home.account"].tap()
        app.buttons["home.menu.contacts"].tap()
        app.segmentedControls.buttons["Groups"].tap()
        let row = app.buttons["contacts.group." + groupID]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        }
        XCTAssertTrue(app.buttons["Group settings"].waitForExistence(timeout: 10))
        app.buttons["Group settings"].tap()
    }

    private struct Account {
        let base: String
        let username: String
        let password: String
        let token: String
        let userID: String
    }

    @MainActor private func register(base: String? = nil) async throws -> Account {
        let endpoint = base ?? ProcessInfo.processInfo.environment["V5_TEST_BASE_URL"]
        try XCTSkipIf(endpoint == nil, "Requires the isolated local integration services")
        let endpointValue = try XCTUnwrap(endpoint)
        try XCTSkipUnless(["localhost", "127.0.0.1"].contains(URL(string: endpointValue)?.host ?? ""))
        let username = "v5directory" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let password = UUID().uuidString + "aA7!"
        let placeholder = Account(base: endpointValue, username: username, password: password, token: "", userID: "")
        let (data, status) = try await request(placeholder, path: "/api/v1/auth/register", method: "POST", body: ["username": username, "email": username + "@v5.invalid", "password": password])
        XCTAssertTrue((200...299).contains(status))
        let registration = try XCTUnwrap(data as? [String: Any])
        let tokens = try XCTUnwrap(registration["tokens"] as? [String: Any])
        let user = try XCTUnwrap(registration["user"] as? [String: Any])
        return Account(base: endpointValue, username: username, password: password, token: try XCTUnwrap(tokens["access_token"] as? String), userID: try XCTUnwrap(user["id"] as? String))
    }

    @MainActor private func login(_ account: Account) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetState", "-settings.languageMode", "english", "-settings.appearanceMode", "light", "-openclawApiBaseURL", account.base]
        app.launch()
        signIn(account, app: app)
        return app
    }

    @MainActor private func signIn(_ account: Account, app: XCUIApplication) {
        XCTAssertTrue(app.textFields["Email or username"].waitForExistence(timeout: 15))
        replace(app.textFields["Email or username"], with: account.username, app: app)
        replace(app.secureTextFields["Password"], with: account.password, app: app)
        app.buttons["Login"].tap()
        let home = UIDevice.current.userInterfaceIdiom == .pad ? "ipad.section.home" : "home.account"
        XCTAssertTrue(app.buttons[home].waitForExistence(timeout: 20))
    }

    @MainActor private func replace(_ field: XCUIElement, with text: String, app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let value = field.value as? String ?? ""
        if !value.isEmpty && value != field.placeholderValue { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
        field.typeText(text)
    }

    @MainActor private func reveal(_ element: XCUIElement, scroll: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 {
            let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
            if element.exists && element.isHittable && element.frame.maxY < keyboardTop && element.frame.minY > scroll.frame.minY { return }
            if element.exists && element.frame.minY < scroll.frame.minY { scroll.swipeDown() } else { scroll.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func absent(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
    }

    @MainActor private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name + (UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""); shot.lifetime = .keepAlways; add(shot)
    }

    private func cleanup(_ account: Account, path: String) {
        addTeardownBlock {
            let (_, status) = try await self.request(account, path: path, method: "DELETE")
            XCTAssertTrue([200, 204, 404].contains(status), "Disposable resource cleanup must complete")
        }
    }

    private func request(_ account: Account, path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> (Any?, Int) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: account.base + path)))
        request.httpMethod = method; request.timeoutInterval = 20
        if !account.token.isEmpty { request.setValue("Bearer " + account.token, forHTTPHeaderField: "Authorization") }
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"], (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
