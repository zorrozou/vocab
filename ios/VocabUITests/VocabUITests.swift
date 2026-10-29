import XCTest

/// Run only against the isolated loopback fixture; never touches a production account.
final class VocabUITests: XCTestCase {
    func testGuestPlacementAndFirstStudy() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        let guest = app.buttons["先逛逛（游客模式）"]
        XCTAssertTrue(guest.waitForExistence(timeout: 30), "welcome screen unavailable")
        guest.tap()
        let begin = app.buttons["开始定级"]
        XCTAssertTrue(begin.waitForExistence(timeout: 20), "guest home unavailable")
        begin.tap()
        let progress = app.staticTexts["placement-progress"]
        for question in 1...30 {
            let expected = NSPredicate(format: "label CONTAINS %@", "第 \(question)/30")
            expectation(for: expected, evaluatedWith: progress)
            waitForExpectations(timeout: 30)
            let unknown = app.buttons["不认识"]
            XCTAssertTrue(unknown.waitForExistence(timeout: 30), "placement question unavailable")
            unknown.tap()
        }
        let finish = app.buttons["开始学习"]
        XCTAssertTrue(finish.waitForExistence(timeout: 30), "placement did not finish")
        finish.tap()
        let learn = app.buttons["学会了 →"]
        for _ in 0..<5 {
            if learn.waitForExistence(timeout: 2) { break }
            let choice = app.buttons["quiz-option-0"]
            XCTAssertTrue(choice.waitForExistence(timeout: 30), "probe or study card unavailable")
            choice.tap()
            // Allow the quiz transition to finish before inspecting the next card.
            Thread.sleep(forTimeInterval: 1.5)
        }
        XCTAssertTrue(learn.waitForExistence(timeout: 30), "first study card unavailable")
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "新词 ")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "study progress unavailable")
        let before = header.label
        learn.tap()
        expectation(for: NSPredicate(format: "label != %@", before), evaluatedWith: header)
        waitForExpectations(timeout: 30)
        XCTAssertTrue(app.buttons["退出"].waitForExistence(timeout: 30), "study session unavailable")
        app.buttons["退出"].tap()
        let start = app.buttons["start-today"]
        XCTAssertTrue(start.waitForExistence(timeout: 30), "home unavailable after study")
        let remainingNew = app.descendants(matching: .any)["daily-new-planned"]
        XCTAssertTrue(remainingNew.waitForExistence(timeout: 10), "daily plan unavailable")
        XCTAssertTrue(remainingNew.label.contains("9"), "daily plan did not deduct the studied word: \(remainingNew.label)")
    }

    func testAccountRegistrationAndLogin() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        let username = "ui_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
        let password = "test_password_123"
        let register = app.buttons["注册新账号"]
        XCTAssertTrue(register.waitForExistence(timeout: 30))
        register.tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["注册并登录"].tap()
        let menu = app.buttons["account-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "registration did not reach home")
        menu.tap()
        let sync = app.buttons["立即同步"]
        XCTAssertTrue(sync.waitForExistence(timeout: 20)); sync.tap()
        XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout: 30), "initial sync failed")
        app.buttons["退出登录"].tap()
        let welcome = app.buttons["登录"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 30), "logout did not return to welcome")
        welcome.tap()
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username.uppercased())
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "login did not restore account")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", username)).firstMatch.waitForExistence(timeout: 10))
    }


    private func fixtureRequest(_ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18765" + path)!)
        request.httpMethod = method
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture request failed"])
        }
        return json
    }

    private func remoteCard(_ token: String) async throws -> [String: Any] {
        let body = try await fixtureRequest("/api/v1/me/state", token: token)
        guard let state = body["state"] as? [String: Any], let cards = state["cards"] as? [String: Any],
              let card = cards["apple"] as? [String: Any] else {
            throw NSError(domain: "Fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Remote card missing"])
        }
        return card
    }

    @MainActor func testOfflineReviewReplay() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/offline-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let start = app.buttons["start-today"]
        XCTAssertTrue(start.waitForExistence(timeout: 30), "seeded account failed to load")
        start.tap()
        let option = app.buttons["quiz-option-0"]
        XCTAssertTrue(option.waitForExistence(timeout: 30)); option.tap()
        let remember = app.buttons["记得"]
        XCTAssertTrue(remember.waitForExistence(timeout: 30)); remember.tap()
        let pending = app.buttons["pending-sync-status"]
        XCTAssertTrue(pending.waitForExistence(timeout: 30), "offline review was not retained")
        // Sync is also unavailable: the pending event exists only in the app's local slot.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let remoteBefore = try await remoteCard(token)
        XCTAssertNil(remoteBefore["pendingFsrs"], "fixture unexpectedly stored the offline event")
        let credentialWarning = app.staticTexts["⚠️ 登录凭证未保存，重启后需重新登录"].exists
        app.terminate(); app.launch()
        if !start.waitForExistence(timeout: 8) {
            // Unsigned simulator builds may have no Keychain entitlement. The app must
            // warn before restart, and re-login must recover the original local work.
            XCTAssertTrue(credentialWarning, "session vanished without a credential warning")
            let login = app.buttons["登录"]
            XCTAssertTrue(login.waitForExistence(timeout: 15)); login.tap()
            XCTAssertTrue(user.waitForExistence(timeout: 15)); user.tap(); user.typeText(username)
            XCTAssertTrue(pass.waitForExistence(timeout: 15)); pass.tap(); pass.typeText(password)
            app.buttons["登录"].tap()
        }
        XCTAssertTrue(start.waitForExistence(timeout: 30), "restarted account did not return home")
        XCTAssertTrue(pending.waitForExistence(timeout: 15), "pending review lost on restart")
        let before = try await fixtureRequest("/api/v1/__ui_fixture/fsrs-status")
        XCTAssertGreaterThan(before["failures"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(before["sync_failures"] as? Int ?? 0, 0)
        XCTAssertEqual(before["successes"] as? Int, 0)
        _ = try await fixtureRequest("/api/v1/__ui_fixture/fsrs-online", method: "POST")
        start.tap() // buildQueue retries the persisted event before making a new queue.
        var completed = false
        for _ in 0..<40 {
            let card = try await remoteCard(token)
            if card["pendingFsrs"] == nil, let applied = card["appliedFsrs"] as? [String],
               let history = card["fsrsHistory"] as? [String: Any], let events = history["events"] as? [[String: Any]],
               events.count == 1, let eventID = events[0]["id"] as? String, applied.contains(eventID) {
                XCTAssertEqual(applied.filter { $0 == eventID }.count, 1)
                completed = true; break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertTrue(completed, "replayed event was not synced")
        let after = try await fixtureRequest("/api/v1/__ui_fixture/fsrs-status")
        XCTAssertGreaterThanOrEqual(after["successes"] as? Int ?? 0, 1, "FSRS replay was not called")
    }

    private func addRemoteCard(_ word: String, token: String) async throws {
        let body = try await fixtureRequest("/api/v1/me/state", token: token)
        var state = try XCTUnwrap(body["state"] as? [String: Any])
        var cards = try XCTUnwrap(state["cards"] as? [String: Any])
        cards[word] = ["pos": 10, "stage": 1, "due": "2099-01-01T00:00:00Z"]
        state["cards"] = cards
        _ = try await fixtureRequest("/api/v1/me/state", method: "PUT", token: token, body: state)
    }

    @MainActor func testPrunedIncrementalReadFallsBack() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        func logIn() {
            XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
            let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
            XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
            XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
            app.buttons["登录"].tap()
        }
        app.launch(); logIn()
        XCTAssertTrue(app.buttons["settings-menu"].waitForExistence(timeout: 30))
        try await addRemoteCard("banana", token: token)
        _ = try await fixtureRequest("/api/v1/__ui_fixture/state-changes-prune", method: "POST", body: ["token":token])
        _ = try await fixtureRequest("/api/v1/__ui_fixture/state-get-hold", method: "POST")
        defer { Task { _ = try? await self.fixtureRequest("/api/v1/__ui_fixture/state-get-release", method: "POST") } }
        app.terminate(); app.launch()
        if !app.buttons["settings-menu"].waitForExistence(timeout: 8) { logIn() }
        var attempted = false
        for _ in 0..<150 {
            if (try await fixtureRequest("/api/v1/__ui_fixture/state-get-status")["attempts"] as? Int ?? 0) > 0 { attempted = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(attempted, "expired history did not request a full state")
        _ = try await fixtureRequest("/api/v1/__ui_fixture/state-get-release", method: "POST")
        let count = app.descendants(matching: .any)["learned-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 30))
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '2'"), object: count)
        await fulfillment(of: [updated], timeout: 30)
    }

    @MainActor func testIncrementalReadAcrossLogin() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        func logIn() {
            XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
            let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
            XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
            XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
            app.buttons["登录"].tap()
        }
        app.launch(); logIn()
        XCTAssertTrue(app.buttons["settings-menu"].waitForExistence(timeout: 30))
        try await addRemoteCard("banana", token: token)
        _ = try await fixtureRequest("/api/v1/__ui_fixture/state-get-hold", method: "POST")
        defer { Task { _ = try? await self.fixtureRequest("/api/v1/__ui_fixture/state-get-release", method: "POST") } }
        app.terminate(); app.launch()
        if !app.buttons["settings-menu"].waitForExistence(timeout: 8) { logIn() }
        let count = app.descendants(matching: .any)["learned-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 30))
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '2'"), object: count)
        await fulfillment(of: [updated], timeout: 30)
        let status = try await fixtureRequest("/api/v1/__ui_fixture/state-get-status")
        XCTAssertEqual(status["attempts"] as? Int, 0, "incremental sync unexpectedly fetched the full state")
    }

    @MainActor func testMissingDeltaRecordRecovery() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        XCTAssertTrue(app.buttons["account-menu"].waitForExistence(timeout: 30))
        _ = try await fixtureRequest("/api/v1/__ui_fixture/disk-transition", method: "POST", body: ["state":"arm"])
        var moved = false
        for _ in 0..<100 {
            if try await fixtureRequest("/api/v1/__ui_fixture/disk-status")["state"] as? String == "blocked" { moved = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(moved)
        app.buttons["account-menu"].tap()
        app.buttons["立即同步"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "增量同步记录缺失")).firstMatch.waitForExistence(timeout: 20))
        app.buttons["重新加载服务器进度"].tap()
        let alert = app.alerts["重新加载服务器进度？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 20))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "待同步修改")).firstMatch.exists)
        alert.buttons["重新加载"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "服务器进度已加载")).firstMatch.waitForExistence(timeout: 20))
    }

    @MainActor func testPulledStateRejectsDatabaseRotation() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let learned = app.descendants(matching: .any)["learned-count"]
        XCTAssertTrue(learned.waitForExistence(timeout: 30)); XCTAssertTrue(learned.label.contains("1"))
        _ = try await fixtureRequest("/api/v1/__ui_fixture/reset-sync-generation", method: "POST")
        try await addRemoteCard("banana", token: token)
        app.terminate(); app.launch()
        if !app.buttons["settings-menu"].waitForExistence(timeout: 8) {
            XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 20)); app.buttons["登录"].tap()
            XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
            XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
            app.buttons["登录"].tap()
        }
        let restartedLearned = app.descendants(matching: .any)["learned-count"]
        guard restartedLearned.waitForExistence(timeout: 30) else {
            print("Restarted app accessibility tree: \(app.debugDescription)")
            XCTFail("App did not return to the learning screen")
            return
        }
        XCTAssertTrue(restartedLearned.label.contains("1"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "同步失败")).firstMatch.waitForExistence(timeout: 20))
    }

    @MainActor func testFileBackupAndRestore() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let learned = app.descendants(matching: .any)["learned-count"]
        XCTAssertTrue(learned.waitForExistence(timeout: 30)); XCTAssertTrue(learned.label.contains("1"))
        let settings = app.buttons["settings-menu"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30)); settings.tap()
        let export = app.buttons["导出本机学习进度"]
        for _ in 0..<5 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.waitForExistence(timeout: 10)); export.tap()
        let save = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 45), "Export picker did not appear: \(app.debugDescription)")
        var filename = "vocab-ui-\(UUID().uuidString)"
        let nameField = app.textFields["DOCPicker.filenameTextField"]
        if !nameField.waitForExistence(timeout: 5) {
            let browse = app.buttons.matching(NSPredicate(format: "label == '浏览' OR label == 'Browse'")).firstMatch
            if browse.waitForExistence(timeout: 5) { browse.tap() }
            let local = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '我的 iPhone' OR label CONTAINS '我的iPhone' OR label == 'On My iPhone'")).firstMatch
            if local.waitForExistence(timeout: 5) { local.tap() }
        }
        if nameField.waitForExistence(timeout: 15) {
            nameField.tap()
            nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80) + filename)
        } else {
            // Some simulator runtimes omit the name field after navigating to
            // a destination. The exporter supplies this default prefix.
            filename = "vocab-progress-"
        }
        save.tap()
        XCTAssertTrue(app.buttons["返回"].waitForExistence(timeout: 20))
        app.buttons["返回"].tap()
        try await addRemoteCard("banana", token: token)
        app.buttons["account-menu"].tap()
        app.buttons["重新加载服务器进度"].tap()
        let dialog = app.alerts["重新加载服务器进度？"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 20)); dialog.buttons["重新加载"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "服务器进度已加载")).firstMatch.waitForExistence(timeout: 20))
        app.buttons["返回学习"].tap()
        settings.tap()
        let open = app.buttons["选择备份文件恢复"]
        for _ in 0..<5 where !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        let file = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", filename)).firstMatch
        if !file.waitForExistence(timeout: 5) {
            let browse = app.buttons.matching(NSPredicate(format: "label == '浏览' OR label == 'Browse'")).firstMatch
            if browse.waitForExistence(timeout: 5) { browse.tap() }
            let local = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '我的 iPhone' OR label CONTAINS '我的iPhone' OR label == 'On My iPhone'")).firstMatch
            if local.waitForExistence(timeout: 5) { local.tap() }
        }
        guard file.waitForExistence(timeout: 30) else {
            print("Document import picker accessibility tree: \(app.debugDescription)")
            XCTFail("Exported backup was not found in the document picker")
            return
        }
        file.tap()
        let confirm = app.alerts["恢复学习进度？"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20)); confirm.buttons["恢复"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "恢复完成")).firstMatch.waitForExistence(timeout: 20))
        let body = try await fixtureRequest("/api/v1/me/state", token: token)
        let state = try XCTUnwrap(body["state"] as? [String: Any])
        let cards = try XCTUnwrap(state["cards"] as? [String: Any])
        XCTAssertEqual(Set(cards.keys), Set(["apple"]))
        let list = try await fixtureRequest("/api/v1/me/state/backups", token: token)
        let backups = try XCTUnwrap(list["backups"] as? [[String: Any]])
        let backup = try XCTUnwrap(backups.first(where: { $0["reason"] as? String == "before_restore" }))
        let backupID = try XCTUnwrap(backup["id"] as? Int)
        let saved = try await fixtureRequest("/api/v1/me/state/backups/\(backupID)", token: token)
        let previous = try XCTUnwrap(saved["state"] as? [String: Any])
        let previousCards = try XCTUnwrap(previous["cards"] as? [String: Any])
        XCTAssertEqual(Set(previousCards.keys), Set(["apple", "banana"]))
    }

    @MainActor func testReviewUndoAndExitDuringRequest() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        func login(_ seed: [String: Any]) throws {
            let username = try XCTUnwrap(seed["username"] as? String)
            let password = try XCTUnwrap(seed["password"] as? String)
            XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
            XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
            XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
            app.buttons["登录"].tap()
        }
        func waitForRequest() async throws {
            for _ in 0..<40 {
                let status = try await fixtureRequest("/api/v1/__ui_fixture/fsrs-status")
                if (status["attempts"] as? Int ?? 0) > 0 { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTFail("delayed review did not start")
        }
        let first = try await fixtureRequest("/api/v1/__ui_fixture/undo-case", method: "POST")
        let firstToken = try XCTUnwrap(first["token"] as? String)
        app.launch(); try login(first)
        let start = app.buttons["start-today"]
        XCTAssertTrue(start.waitForExistence(timeout: 30)); start.tap()
        let wrong = app.buttons["quiz-option-1"]
        XCTAssertTrue(wrong.waitForExistence(timeout: 30)); wrong.tap()
        let undo = app.buttons["点错了？撤销这次「忘记」"]
        XCTAssertTrue(undo.waitForExistence(timeout: 30)); try await waitForRequest(); undo.tap()
        let correct = app.buttons["quiz-option-0"]
        XCTAssertTrue(correct.waitForExistence(timeout: 20)); correct.tap()
        let remember = app.buttons["记得"]
        XCTAssertTrue(remember.waitForExistence(timeout: 20)); remember.tap()
        let reviewed = app.descendants(matching: .any)["session-reviewed"]
        XCTAssertTrue(reviewed.waitForExistence(timeout: 30)); XCTAssertTrue(reviewed.label.contains("1"), "undo left an extra reviewed count: \(reviewed.label)")
        app.buttons["返回主页"].tap(); app.buttons["account-menu"].tap()
        let sync = app.buttons["立即同步"]
        XCTAssertTrue(sync.waitForExistence(timeout: 20)); sync.tap()
        XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout: 30))
        let firstResponse = try await fixtureRequest("/api/v1/me/state", token: firstToken)
        let firstState = try XCTUnwrap(firstResponse["state"] as? [String: Any])
        let firstLog = try XCTUnwrap(firstState["log"] as? [[String: Any]])
        XCTAssertEqual(firstLog.filter { $0["kind"] as? String == "review" && $0["word"] as? String == "apple" }.compactMap { $0["rating"] as? Int }, [3])
        app.buttons["退出登录"].tap()
        let second = try await fixtureRequest("/api/v1/__ui_fixture/undo-case", method: "POST")
        let secondToken = try XCTUnwrap(second["token"] as? String)
        try login(second)
        XCTAssertTrue(start.waitForExistence(timeout: 30)); start.tap()
        XCTAssertTrue(wrong.waitForExistence(timeout: 30)); wrong.tap()
        XCTAssertTrue(undo.waitForExistence(timeout: 30)); try await waitForRequest()
        app.buttons["退出"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 20)); app.buttons["account-menu"].tap()
        XCTAssertTrue(sync.waitForExistence(timeout: 20)); sync.tap()
        XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout: 30), "exit left an unfinished undo window")
        let secondResponse = try await fixtureRequest("/api/v1/me/state", token: secondToken)
        let secondState = try XCTUnwrap(secondResponse["state"] as? [String: Any])
        let secondLog = try XCTUnwrap(secondState["log"] as? [[String: Any]])
        XCTAssertEqual(secondLog.filter { $0["kind"] as? String == "review" && $0["word"] as? String == "apple" }.compactMap { $0["rating"] as? Int }, [1])
    }

    @MainActor func testQueuePreparationDoesNotReopenAfterNavigation() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/queue-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let start = app.buttons["start-today"]
        XCTAssertTrue(start.waitForExistence(timeout: 30)); start.tap()
        var attempts = 0
        for _ in 0..<30 {
            let status = try await fixtureRequest("/api/v1/__ui_fixture/queue-status")
            attempts = status["attempts"] as? Int ?? 0
            if attempts > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(attempts, 0, "queue request did not start")
        app.buttons["settings-menu"].tap()
        let reset = app.buttons["重新定级（30 题重测词汇边界）"]
        XCTAssertTrue(reset.waitForExistence(timeout: 20))
        try await Task.sleep(for: .seconds(7))
        XCTAssertTrue(reset.exists, "late queue request replaced settings")
        XCTAssertFalse(app.buttons["退出"].exists, "late queue request opened a study session")
    }

    @MainActor func testOldFsrsResponseCannotModifyReloggedSession() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/fsrs-relogin-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        let login = app.buttons["登录"]
        func loginAccount() {
            XCTAssertTrue(login.waitForExistence(timeout: 30)); login.tap()
            let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
            XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
            XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
            app.buttons["登录"].tap()
        }
        loginAccount()
        let start = app.buttons["start-today"]
        XCTAssertTrue(start.waitForExistence(timeout: 30)); start.tap()
        let answer = app.buttons["quiz-option-0"]
        XCTAssertTrue(answer.waitForExistence(timeout: 30)); answer.tap()
        let remember = app.buttons["记得"]
        XCTAssertTrue(remember.waitForExistence(timeout: 30)); remember.tap()
        var attempts = 0
        for _ in 0..<50 {
            let status = try await fixtureRequest("/api/v1/__ui_fixture/fsrs-status")
            attempts = status["attempts"] as? Int ?? 0
            if attempts > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(attempts, 0, "old session rating did not start")
        app.buttons["退出"].tap(); XCTAssertTrue(start.waitForExistence(timeout: 20))
        app.buttons["account-menu"].tap()
        let switchAccount = app.buttons["切换账号 / 游客模式"]
        XCTAssertTrue(switchAccount.waitForExistence(timeout: 20)); switchAccount.tap()
        loginAccount()
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        let pending = app.buttons["pending-sync-status"]
        XCTAssertTrue(pending.waitForExistence(timeout: 20), "pending event was not restored")
        _ = try await fixtureRequest("/api/v1/__ui_fixture/fsrs-release", method: "POST")
        var completed = 0
        for _ in 0..<50 {
            let status = try await fixtureRequest("/api/v1/__ui_fixture/fsrs-status")
            completed = status["completed"] as? Int ?? 0
            if completed > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(completed, 0, "old response was not delivered")
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(pending.exists, "old session applied a result to the new session")
        start.tap()
        let back = app.buttons["返回主页"]
        XCTAssertTrue(back.waitForExistence(timeout: 30)); back.tap()
        app.buttons["account-menu"].tap()
        XCTAssertTrue(app.buttons["立即同步"].waitForExistence(timeout: 20)); app.buttons["立即同步"].tap()
        XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout: 30))
        let response = try await fixtureRequest("/api/v1/me/state", token: token)
        let state = try XCTUnwrap(response["state"] as? [String: Any])
        let cards = try XCTUnwrap(state["cards"] as? [String: [String: Any]])
        let card = try XCTUnwrap(cards["apple"])
        XCTAssertNil(card["pendingFsrs"])
        XCTAssertEqual((card["appliedFsrs"] as? [String])?.count, 1)
        XCTAssertEqual((state["log"] as? [[String: Any]] ?? []).filter { $0["word"] as? String == "apple" && $0["kind"] as? String == "review" }.count, 1)
    }

    @MainActor func testDiskFailureKeepsUnsavedAccountState() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        let login = app.buttons["登录"]
        func loginAccount() {
            XCTAssertTrue(login.waitForExistence(timeout: 30)); login.tap()
            let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
            XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
            XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
            app.buttons["登录"].tap()
        }
        func waitForDisk(_ expected: String) async throws {
            for _ in 0..<100 {
                let status = try await fixtureRequest("/api/v1/__ui_fixture/disk-status")
                if status["state"] as? String == expected { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTFail("disk watcher did not reach \(expected)")
        }
        loginAccount()
        let learned = app.descendants(matching: .any)["learned-count"]
        XCTAssertTrue(learned.waitForExistence(timeout: 30)); XCTAssertTrue(learned.label.contains("1"))
        _ = try await fixtureRequest("/api/v1/__ui_fixture/state-upload-mode", method: "POST", body: ["mode":"expired-hold"])
        // A clean incremental baseline has nothing to upload. Create a real
        // local edit so the held request exercises the 401 response path.
        app.buttons["settings-menu"].tap()
        let fifteen = app.buttons["setting-new-15"]
        XCTAssertTrue(fifteen.waitForExistence(timeout: 20)); fifteen.tap(); app.buttons["返回"].tap()
        app.buttons["account-menu"].tap()
        let initial = try await fixtureRequest("/api/v1/__ui_fixture/state-upload-status")
        let previous = try XCTUnwrap(initial["attempts"] as? Int)
        XCTAssertTrue(app.buttons["立即同步"].waitForExistence(timeout: 20)); app.buttons["立即同步"].tap()
        var attempts = previous
        for _ in 0..<50 {
            let status = try await fixtureRequest("/api/v1/__ui_fixture/state-upload-status")
            attempts = status["attempts"] as? Int ?? 0
            if attempts > previous { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(attempts, previous, "held sync did not start")
        app.buttons["返回学习"].tap(); app.buttons["settings-menu"].tap()
        _ = try await fixtureRequest("/api/v1/__ui_fixture/disk-transition", method: "POST", body: ["state":"arm"])
        try await waitForDisk("blocked")
        let twenty = app.buttons["setting-new-20"]
        XCTAssertTrue(twenty.waitForExistence(timeout: 20)); twenty.tap()
        XCTAssertEqual(twenty.value as? String, "已选择")
        _ = try await fixtureRequest("/api/v1/__ui_fixture/state-expired-release", method: "POST")
        app.buttons["返回"].tap()
        XCTAssertTrue(app.buttons["本机保存失败，打开设置导出进度"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["同步未完成，请查看详情"].waitForExistence(timeout: 20), "held 401 was not handled")
        XCTAssertTrue(learned.exists, "expired response lost the active account")
        app.buttons["account-menu"].tap()
        let switchAccount = app.buttons["切换账号 / 游客模式"]
        XCTAssertTrue(switchAccount.waitForExistence(timeout: 20)); switchAccount.tap()
        XCTAssertTrue(app.staticTexts["本机保存失败，请先导出进度并释放空间"].waitForExistence(timeout: 20))
        XCTAssertTrue(switchAccount.exists, "failed local save switched accounts")
        let before = try await fixtureRequest("/api/v1/me/state", token: token)
        let beforeState = try XCTUnwrap(before["state"] as? [String: Any])
        XCTAssertNotEqual((beforeState["settings"] as? [String: Any])?["newPerDay"] as? Int, 20)
        _ = try await fixtureRequest("/api/v1/__ui_fixture/disk-transition", method: "POST", body: ["state":"restore"])
        try await waitForDisk("restored")
        switchAccount.tap()
        XCTAssertTrue(login.waitForExistence(timeout: 30), "switch did not resume after disk recovery")
        loginAccount()
        XCTAssertTrue(learned.waitForExistence(timeout: 30)); XCTAssertTrue(learned.label.contains("1"))
        let synced = try await fixtureRequest("/api/v1/me/state", token: token)
        let syncedState = try XCTUnwrap(synced["state"] as? [String: Any])
        XCTAssertEqual((syncedState["settings"] as? [String: Any])?["newPerDay"] as? Int, 20)
    }

    @MainActor func testManualSyncMergeAndOversizeRecovery() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let learned = app.descendants(matching: .any)["learned-count"]
        XCTAssertTrue(learned.waitForExistence(timeout: 30)); XCTAssertTrue(learned.label.contains("1"))
        let response = try await fixtureRequest("/api/v1/me/state", token: token)
        var remote = try XCTUnwrap(response["state"] as? [String: Any])
        var cards = try XCTUnwrap(remote["cards"] as? [String: Any])
        cards["pear"] = ["pos":2, "stage":1, "due":"2099-01-01T00:00:00Z"]
        remote["cards"] = cards
        _ = try await fixtureRequest("/api/v1/me/state", method: "PUT", token: token, body: remote)
        app.buttons["account-menu"].tap()
        let sync = app.buttons["立即同步"]
        XCTAssertTrue(sync.waitForExistence(timeout: 20)); sync.tap()
        XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout: 30))
        app.buttons["返回学习"].tap()
        let merged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "2"), object: learned)
        await fulfillment(of: [merged], timeout: 20)
        _ = try await fixtureRequest("/api/v1/__ui_fixture/state-upload-mode", method: "POST", body: ["mode":"oversize"])
        app.buttons["settings-menu"].tap()
        let twenty = app.buttons["setting-new-20"]
        XCTAssertTrue(twenty.waitForExistence(timeout: 20)); twenty.tap(); app.buttons["返回"].tap()
        app.buttons["account-menu"].tap(); XCTAssertTrue(sync.waitForExistence(timeout: 20)); sync.tap()
        let warning = app.staticTexts["进度超过同步大小限制，本机进度已保留；请先导出进度，再联系管理员处理。"]
        XCTAssertTrue(warning.waitForExistence(timeout: 30), "413 did not explain how to preserve progress")
        let beforeLogoutStatus = try await fixtureRequest("/api/v1/__ui_fixture/state-upload-status")
        let previousAttempts = try XCTUnwrap(beforeLogoutStatus["attempts"] as? Int)
        app.buttons["退出登录"].tap()
        var attemptsAfterLogout = previousAttempts
        for _ in 0..<50 {
            let status = try await fixtureRequest("/api/v1/__ui_fixture/state-upload-status")
            attemptsAfterLogout = status["attempts"] as? Int ?? 0
            if attemptsAfterLogout > previousAttempts { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(attemptsAfterLogout, previousAttempts)
        XCTAssertTrue(sync.exists, "failed upload logged out the account")
        let beforeRetry = try await fixtureRequest("/api/v1/me/state", token: token)
        let stateBefore = try XCTUnwrap(beforeRetry["state"] as? [String: Any])
        XCTAssertNotEqual((stateBefore["settings"] as? [String: Any])?["newPerDay"] as? Int, 20)
        _ = try await fixtureRequest("/api/v1/__ui_fixture/state-upload-mode", method: "POST", body: ["mode":"normal"])
        sync.tap(); XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout: 30))
        let afterRetry = try await fixtureRequest("/api/v1/me/state", token: token)
        let stateAfter = try XCTUnwrap(afterRetry["state"] as? [String: Any])
        XCTAssertEqual((stateAfter["settings"] as? [String: Any])?["newPerDay"] as? Int, 20)
        let deltaStatus = try await fixtureRequest("/api/v1/__ui_fixture/state-upload-status")
        XCTAssertGreaterThan(deltaStatus["delta_successes"] as? Int ?? 0, 0, "iOS did not use the incremental upload endpoint")
        _ = try await fixtureRequest("/api/v1/__ui_fixture/state-upload-mode", method: "POST", body: ["mode":"conflict"])
        app.buttons["返回学习"].tap(); app.buttons["settings-menu"].tap()
        let fifteen = app.buttons["setting-new-15"]
        XCTAssertTrue(fifteen.waitForExistence(timeout: 20)); fifteen.tap(); app.buttons["返回"].tap()
        app.buttons["account-menu"].tap(); XCTAssertTrue(sync.waitForExistence(timeout: 20)); sync.tap()
        XCTAssertTrue(app.staticTexts["事件 401 已过期"].waitForExistence(timeout: 30))
        XCTAssertTrue(sync.exists, "non-401 conflict logged out the account")
        _ = try await fixtureRequest("/api/v1/__ui_fixture/state-upload-mode", method: "POST", body: ["mode":"normal"])
        sync.tap(); XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout: 30))
        let afterConflict = try await fixtureRequest("/api/v1/me/state", token: token)
        var finalState = try XCTUnwrap(afterConflict["state"] as? [String: Any])
        XCTAssertEqual((finalState["settings"] as? [String: Any])?["newPerDay"] as? Int, 15)
        var laterCards = try XCTUnwrap(finalState["cards"] as? [String: Any])
        laterCards["cherry"] = ["pos":3, "stage":1, "due":"2099-01-01T00:00:00Z"]
        finalState["cards"] = laterCards
        _ = try await fixtureRequest("/api/v1/me/state", method: "PUT", token: token, body: finalState)
        _ = try await fixtureRequest("/api/v1/__ui_fixture/state-get-hold", method: "POST")
        sync.tap()
        var attempts = 0
        for _ in 0..<50 {
            let status = try await fixtureRequest("/api/v1/__ui_fixture/state-get-status")
            attempts = status["attempts"] as? Int ?? 0
            if attempts > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(attempts, 0, "manual sync did not start its pull")
        app.buttons["返回学习"].tap(); app.buttons["settings-menu"].tap()
        let settings = app.buttons["setting-new-15"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        _ = try await fixtureRequest("/api/v1/__ui_fixture/state-get-release", method: "POST")
        var completed = 0
        for _ in 0..<50 {
            let status = try await fixtureRequest("/api/v1/__ui_fixture/state-get-status")
            completed = status["completed"] as? Int ?? 0
            if completed > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(completed, 0, "held pull did not finish")
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(settings.exists, "late pull replaced the settings page")
        app.buttons["返回"].tap()
        XCTAssertTrue(learned.waitForExistence(timeout: 20)); XCTAssertTrue(learned.label.contains("2"), "late pull changed state after navigation")
        app.buttons["account-menu"].tap(); XCTAssertTrue(sync.waitForExistence(timeout: 20)); sync.tap()
        XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout: 30))
        app.buttons["返回学习"].tap()
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "3"), object: learned)
        await fulfillment(of: [refreshed], timeout: 20)
    }

    @MainActor func testBackupWarnsMissingScheduler() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/backup-missing-scheduler", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String), password = try XCTUnwrap(seed["password"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let settings = app.buttons["settings-menu"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30)); settings.tap()
        let export = app.buttons["导出本机学习进度"]
        for _ in 0..<5 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.waitForExistence(timeout: 20)); export.tap()
        // On recent simulator runtimes the cancel control is exposed as an
        // accessibility Other rather than a Button.
        let cancel = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'")).firstMatch
        guard cancel.waitForExistence(timeout: 30) else {
            print("Backup export accessibility tree: \(app.debugDescription)")
            XCTFail("Backup export did not open a cancellable document picker")
            return
        }
        cancel.tap()
        let warning = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "备份缺少部分评分所用的参数版本")).firstMatch
        for _ in 0..<5 where !warning.isHittable { app.swipeUp() }
        XCTAssertTrue(warning.waitForExistence(timeout: 20), "successful server response hid the missing scheduler warning")
        let resolution = try await fixtureRequest("/api/v1/__ui_fixture/scheduler-resolve-status")
        XCTAssertGreaterThan(resolution["attempts"] as? Int ?? 0, 0, "oversized scheduler history did not use per-version resolution")
    }

    @MainActor func testStagedDeltaReplayAfterProcessTermination() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/staged-ui-case")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        let login = app.buttons["登录"], user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        func logIn() {
            XCTAssertTrue(login.waitForExistence(timeout: 30)); login.tap()
            XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
            XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
            app.buttons["登录"].tap()
        }
        _ = try await fixtureRequest("/api/v1/__ui_fixture/delta-hold-response", method: "POST")
        app.launch(); logIn()
        var held = false
        for _ in 0..<450 {
            if try await fixtureRequest("/api/v1/__ui_fixture/delta-hold-status")["started"] as? Bool == true { held = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(held, "staged upload did not commit before termination")
        let committed = try await fixtureRequest("/api/v1/me/state", token: token)
        let revision = try XCTUnwrap(committed["state_revision"] as? String)
        let state = try XCTUnwrap(committed["state"] as? [String: Any])
        XCTAssertEqual((state["personalizedWeak"] as? String)?.count, 2100 * 1024)
        XCTAssertEqual((state["cards"] as? [String: Any])?.count, 2101)
        app.terminate()
        _ = try await fixtureRequest("/api/v1/__ui_fixture/delta-release-response", method: "POST")
        app.launch()
        let home = app.buttons["settings-menu"]
        if !home.waitForExistence(timeout: 8) { logIn() }
        XCTAssertTrue(home.waitForExistence(timeout: 45))
        app.buttons["account-menu"].tap()
        let sync = app.buttons["立即同步"]
        XCTAssertTrue(sync.waitForExistence(timeout: 20)); sync.tap()
        XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout: 60))
        let after = try await fixtureRequest("/api/v1/me/state", token: token)
        XCTAssertEqual(after["state_revision"] as? String, revision, "replayed staged batch changed the revision")
        let status = try await fixtureRequest("/api/v1/__ui_fixture/state-upload-status")
        XCTAssertGreaterThanOrEqual(status["stage_successes"] as? Int ?? 0, 2)
    }

    @MainActor func testExperimentalLargeFirstLogin() async throws {
        continueAfterFailure=false
        let seed=try await fixtureRequest("/api/v1/__ui_fixture/staged-ui-case")
        let username=try XCTUnwrap(seed["username"] as? String),password=try XCTUnwrap(seed["password"] as? String),token=try XCTUnwrap(seed["token"] as? String)
        let before=try await fixtureRequest("/api/v1/me/state/snapshots?representation=stored",method:"POST",token:token,body:[:])
        XCTAssertGreaterThan(before["byte_length"] as? Int ?? 0,8*1024*1024)
        let app=XCUIApplication();app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765";app.launch()
        let login=app.buttons["登录"],user=app.textFields["auth-username"],pass=app.secureTextFields["auth-password"]
        XCTAssertTrue(login.waitForExistence(timeout:30));login.tap()
        XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout:20));pass.tap();pass.typeText(password);app.buttons["登录"].tap()
        XCTAssertTrue(app.buttons["settings-menu"].waitForExistence(timeout:90))
        app.buttons["account-menu"].tap();let sync=app.buttons["立即同步"]
        XCTAssertTrue(sync.waitForExistence(timeout:20));sync.tap()
        XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout:90))
        let after=try await fixtureRequest("/api/v1/me/state/snapshots?representation=stored",method:"POST",token:token,body:[:])
        XCTAssertEqual(after["state_revision"] as? String,before["state_revision"] as? String)
        XCTAssertEqual(after["sha256"] as? String,before["sha256"] as? String)
        app.buttons["返回学习"].tap(); app.buttons["settings-menu"].tap()
        let recoveryExport=app.buttons["导出大状态恢复记录"]
        for _ in 0..<6 where !recoveryExport.isHittable { app.swipeUp() }
        XCTAssertTrue(recoveryExport.waitForExistence(timeout:20)); recoveryExport.tap()
        let message=app.staticTexts["large-restore-export-message"]
        XCTAssertTrue(message.waitForExistence(timeout:20)); XCTAssertEqual(message.label,"当前没有可导出的大状态恢复记录。")
        let resume=app.buttons["继续未完成的恢复或整理"]
        for _ in 0..<3 where !resume.isHittable { app.swipeDown() }
        XCTAssertTrue(resume.waitForExistence(timeout:20));resume.tap()
        let noPending=app.staticTexts["large-restore-export-message"]
        let noPendingPredicate=NSPredicate(format:"label CONTAINS %@", "当前没有未完成的大状态恢复")
        await fulfillment(of:[XCTNSPredicateExpectation(predicate:noPendingPredicate,object:noPending)],timeout:20)
    }

    @MainActor func testExperimentalLargeRestoreFromFile() async throws {
        try await runExperimentalLargeRestoreFromFile(interrupt:false)
    }
    @MainActor func testExperimentalLargeRestoreInterrupted() async throws {
        try await runExperimentalLargeRestoreFromFile(interrupt:true)
    }
    @MainActor func testExperimentalLargeRestoreCancelInterrupted() async throws {
        try await runExperimentalLargeRestoreFromFile(interrupt:false,cancel:true)
    }
    @MainActor func testExperimentalLargeCheckpointInterrupted() async throws {
        continueAfterFailure=false
        let seed=try await fixtureRequest("/api/v1/__ui_fixture/staged-ui-case")
        let username=try XCTUnwrap(seed["username"] as? String),password=try XCTUnwrap(seed["password"] as? String)
        let token=try XCTUnwrap(seed["token"] as? String)
        let app=XCUIApplication();app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765";app.launch()
        let settings=app.buttons["settings-menu"],user=app.textFields["auth-username"],pass=app.secureTextFields["auth-password"]
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30));app.buttons["登录"].tap()
        XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout:20));pass.tap();pass.typeText(password);app.buttons["登录"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout:90));settings.tap()
        let checkpoint=app.buttons["整理已同步的历史"]
        for _ in 0..<7 where !checkpoint.isHittable { app.swipeUp() }
        XCTAssertTrue(checkpoint.waitForExistence(timeout:30));checkpoint.tap()
        let confirm=app.alerts["整理已同步的历史？"]
        XCTAssertTrue(confirm.waitForExistence(timeout:30))
        _ = try await fixtureRequest("/api/v1/__ui_fixture/delta-hold-response",method:"POST")
        confirm.buttons["整理"].tap()
        var committed=false
        for _ in 0..<1500 {
            if try await fixtureRequest("/api/v1/__ui_fixture/delta-hold-status")["started"] as? Bool == true { committed=true;break }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertTrue(committed,"checkpoint did not commit before termination")
        let head=try await fixtureRequest("/api/v1/me/state/snapshots?representation=stored",method:"POST",token:token,body:[:])
        let revision=try XCTUnwrap(head["state_revision"] as? String)
        app.terminate();_ = try await fixtureRequest("/api/v1/__ui_fixture/delta-release-response",method:"POST");app.launch()
        if !settings.waitForExistence(timeout:12) {
            XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30));app.buttons["登录"].tap()
            XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(username)
            XCTAssertTrue(pass.waitForExistence(timeout:20));pass.tap();pass.typeText(password);app.buttons["登录"].tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout:90));settings.tap()
        let resume=app.buttons["继续未完成的恢复或整理"]
        for _ in 0..<7 where !resume.isHittable { app.swipeUp() }
        XCTAssertTrue(resume.waitForExistence(timeout:20));resume.tap()
        let message=app.staticTexts["large-restore-export-message"]
        await fulfillment(of:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"label CONTAINS %@", "恢复完成"),object:message)],timeout:180)
        let after=try await fixtureRequest("/api/v1/me/state/snapshots?representation=stored",method:"POST",token:token,body:[:])
        XCTAssertEqual(after["state_revision"] as? String,revision,"checkpoint was committed twice")
    }
    @MainActor func testExperimentalLargeCheckpointCancelInterrupted() async throws {
        continueAfterFailure=false
        let seed=try await fixtureRequest("/api/v1/__ui_fixture/staged-ui-case")
        let username=try XCTUnwrap(seed["username"] as? String),password=try XCTUnwrap(seed["password"] as? String)
        let token=try XCTUnwrap(seed["token"] as? String)
        let app=XCUIApplication();app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765";app.launch()
        let settings=app.buttons["settings-menu"],user=app.textFields["auth-username"],pass=app.secureTextFields["auth-password"]
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30));app.buttons["登录"].tap()
        XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout:20));pass.tap();pass.typeText(password);app.buttons["登录"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout:90));settings.tap()
        let checkpoint=app.buttons["整理已同步的历史"]
        for _ in 0..<7 where !checkpoint.isHittable { app.swipeUp() }
        XCTAssertTrue(checkpoint.waitForExistence(timeout:30));checkpoint.tap()
        let confirm=app.alerts["整理已同步的历史？"];XCTAssertTrue(confirm.waitForExistence(timeout:30))
        _ = try await fixtureRequest("/api/v1/__ui_fixture/checkpoint-write-failure",method:"POST",body:["enabled":true])
        confirm.buttons["整理"].tap()
        let failed=app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@", "injected checkpoint failure")).firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout:120),"checkpoint failure was not visible")
        _ = try await fixtureRequest("/api/v1/__ui_fixture/checkpoint-write-failure",method:"POST",body:["enabled":false])
        _ = try await fixtureRequest("/api/v1/__ui_fixture/delta-hold-response",method:"POST")
        let cancel=app.buttons["取消未提交的历史整理"]
        for _ in 0..<7 where !cancel.isHittable { app.swipeUp() }
        XCTAssertTrue(cancel.waitForExistence(timeout:20));cancel.tap()
        let cancelAlert=app.alerts["取消未提交的历史整理？"];XCTAssertTrue(cancelAlert.waitForExistence(timeout:20));cancelAlert.buttons["确认取消"].tap()
        var committed=false
        for _ in 0..<1500 {
            if try await fixtureRequest("/api/v1/__ui_fixture/delta-hold-status")["started"] as? Bool == true { committed=true;break }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertTrue(committed,"cancel did not reach server before termination")
        let head=try await fixtureRequest("/api/v1/me/state/snapshots?representation=stored",method:"POST",token:token,body:[:])
        let revision=try XCTUnwrap(head["state_revision"] as? String)
        app.terminate();_ = try await fixtureRequest("/api/v1/__ui_fixture/delta-release-response",method:"POST");app.launch()
        if !settings.waitForExistence(timeout:12) {
            XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30));app.buttons["登录"].tap()
            XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(username)
            XCTAssertTrue(pass.waitForExistence(timeout:20));pass.tap();pass.typeText(password);app.buttons["登录"].tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout:90));settings.tap()
        for _ in 0..<7 where !cancel.isHittable { app.swipeUp() }
        XCTAssertTrue(cancel.waitForExistence(timeout:20));cancel.tap()
        XCTAssertTrue(cancelAlert.waitForExistence(timeout:20));cancelAlert.buttons["确认取消"].tap()
        let message=app.staticTexts["large-restore-export-message"]
        await fulfillment(of:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"label CONTAINS %@", "整理已取消"),object:message)],timeout:180)
        let after=try await fixtureRequest("/api/v1/me/state/snapshots?representation=stored",method:"POST",token:token,body:[:])
        XCTAssertEqual(after["state_revision"] as? String,revision,"cancellation advanced the revision twice")
        app.buttons["返回"].tap();app.buttons["account-menu"].tap()
        let sync=app.buttons["立即同步"];XCTAssertTrue(sync.waitForExistence(timeout:20));sync.tap()
        XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout:120),"cancelled checkpoint baseline did not resynchronize")
    }
    @MainActor private func runExperimentalLargeRestoreFromFile(interrupt: Bool, cancel: Bool = false) async throws {
        continueAfterFailure=false
        let seed=try await fixtureRequest("/api/v1/__ui_fixture/staged-ui-case")
        let username=try XCTUnwrap(seed["username"] as? String),password=try XCTUnwrap(seed["password"] as? String)
        let token=try XCTUnwrap(seed["token"] as? String)
        let app=XCUIApplication();app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765";app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30));app.buttons["登录"].tap()
        let user=app.textFields["auth-username"],pass=app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout:20));pass.tap();pass.typeText(password);app.buttons["登录"].tap()
        let settings=app.buttons["settings-menu"];XCTAssertTrue(settings.waitForExistence(timeout:90));settings.tap()
        let export=app.buttons["导出本机学习进度"]
        for _ in 0..<6 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.waitForExistence(timeout:20));export.tap()
        let save=app.buttons["DOCPicker.actionButton"];XCTAssertTrue(save.waitForExistence(timeout:60))
        var filename="vocab-large-\(UUID().uuidString)"
        let nameField=app.textFields["DOCPicker.filenameTextField"]
        if !nameField.waitForExistence(timeout:5) {
            let browse=app.buttons.matching(NSPredicate(format:"label == '浏览' OR label == 'Browse'")).firstMatch
            if browse.waitForExistence(timeout:5) { browse.tap() }
            let local=app.staticTexts.matching(NSPredicate(format:"label CONTAINS '我的 iPhone' OR label CONTAINS '我的iPhone' OR label == 'On My iPhone'")).firstMatch
            if local.waitForExistence(timeout:5) { local.tap() }
        }
        if nameField.waitForExistence(timeout:15) { nameField.tap();nameField.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:80)+filename) }
        else { filename="vocab-progress-" }
        save.tap()
        let fifteen=app.buttons["setting-new-15"],twenty=app.buttons["setting-new-20"]
        for _ in 0..<7 where !fifteen.isHittable { app.swipeDown() }
        XCTAssertTrue(fifteen.waitForExistence(timeout:20));XCTAssertTrue(twenty.exists)
        if fifteen.value as? String == "已选择" { twenty.tap() } else { fifteen.tap() }
        app.buttons["返回"].tap();app.buttons["account-menu"].tap()
        let sync=app.buttons["立即同步"];XCTAssertTrue(sync.waitForExistence(timeout:20));sync.tap()
        XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout:120))
        app.buttons["返回学习"].tap();settings.tap()
        let open=app.buttons["选择备份文件恢复"]
        for _ in 0..<7 where !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.waitForExistence(timeout:20));open.tap()
        let file=app.cells.matching(NSPredicate(format:"identifier BEGINSWITH %@",filename)).firstMatch
        if !file.waitForExistence(timeout:5) {
            let browse=app.buttons.matching(NSPredicate(format:"label == '浏览' OR label == 'Browse'")).firstMatch
            if browse.waitForExistence(timeout:5) { browse.tap() }
            let local=app.staticTexts.matching(NSPredicate(format:"label CONTAINS '我的 iPhone' OR label CONTAINS '我的iPhone' OR label == 'On My iPhone'")).firstMatch
            if local.waitForExistence(timeout:5) { local.tap() }
        }
        guard file.waitForExistence(timeout:30) else { XCTFail("large backup not found in document picker");return }
        file.tap()
        let confirm=app.alerts["恢复学习进度？"]
        XCTAssertTrue(confirm.waitForExistence(timeout:120))
        if interrupt { _ = try await fixtureRequest("/api/v1/__ui_fixture/delta-hold-response",method:"POST") }
        if cancel { _ = try await fixtureRequest("/api/v1/__ui_fixture/large-restore-write-failure",method:"POST",body:["enabled":true]) }
        confirm.buttons["恢复"].tap()
        if cancel {
            let failed=app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@", "injected large restore failure")).firstMatch
            XCTAssertTrue(failed.waitForExistence(timeout:180),"restore failure was not visible")
            _ = try await fixtureRequest("/api/v1/__ui_fixture/large-restore-write-failure",method:"POST",body:["enabled":false])
            _ = try await fixtureRequest("/api/v1/__ui_fixture/delta-hold-response",method:"POST")
            let cancelButton=app.buttons["取消未提交的备份恢复"]
            for _ in 0..<7 where !cancelButton.isHittable { app.swipeUp() }
            XCTAssertTrue(cancelButton.waitForExistence(timeout:20));cancelButton.tap()
            let alert=app.alerts["取消未提交的备份恢复？"];XCTAssertTrue(alert.waitForExistence(timeout:20));alert.buttons["确认取消"].tap()
            var confirmed=false
            for _ in 0..<1500 {
                if try await fixtureRequest("/api/v1/__ui_fixture/delta-hold-status")["started"] as? Bool == true { confirmed=true;break }
                try await Task.sleep(for:.milliseconds(100))
            }
            XCTAssertTrue(confirmed,"restore cancellation did not reach server")
            let head=try await fixtureRequest("/api/v1/me/state/snapshots?representation=stored",method:"POST",token:token,body:[:])
            let revision=try XCTUnwrap(head["state_revision"] as? String)
            app.terminate();_ = try await fixtureRequest("/api/v1/__ui_fixture/delta-release-response",method:"POST");app.launch()
            if !settings.waitForExistence(timeout:12) {
                XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30));app.buttons["登录"].tap()
                XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(username)
                XCTAssertTrue(pass.waitForExistence(timeout:20));pass.tap();pass.typeText(password);app.buttons["登录"].tap()
            }
            XCTAssertTrue(settings.waitForExistence(timeout:90));settings.tap()
            for _ in 0..<7 where !cancelButton.isHittable { app.swipeUp() }
            XCTAssertTrue(cancelButton.waitForExistence(timeout:20));cancelButton.tap()
            XCTAssertTrue(alert.waitForExistence(timeout:20));alert.buttons["确认取消"].tap()
            let message=app.staticTexts["large-restore-export-message"]
            await fulfillment(of:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"label CONTAINS %@", "恢复已取消"),object:message)],timeout:180)
            let after=try await fixtureRequest("/api/v1/me/state/snapshots?representation=stored",method:"POST",token:token,body:[:])
            XCTAssertEqual(after["state_revision"] as? String,revision,"restore cancellation advanced the revision twice")
            app.buttons["返回"].tap();app.buttons["account-menu"].tap()
            let sync=app.buttons["立即同步"];XCTAssertTrue(sync.waitForExistence(timeout:20));sync.tap()
            XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout:120),"cancelled restore baseline did not resynchronize")
        } else if interrupt {
            var committed=false
            for _ in 0..<1500 {
                if try await fixtureRequest("/api/v1/__ui_fixture/delta-hold-status")["started"] as? Bool == true { committed=true;break }
                try await Task.sleep(for:.milliseconds(100))
            }
            XCTAssertTrue(committed,"restore did not commit before termination")
            let committedHead=try await fixtureRequest("/api/v1/me/state/snapshots?representation=stored",method:"POST",token:token,body:[:])
            let revision=try XCTUnwrap(committedHead["state_revision"] as? String)
            app.terminate()
            _ = try await fixtureRequest("/api/v1/__ui_fixture/delta-release-response",method:"POST")
            app.launch()
            if !settings.waitForExistence(timeout:12) {
                XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30));app.buttons["登录"].tap()
                XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(username)
                XCTAssertTrue(pass.waitForExistence(timeout:20));pass.tap();pass.typeText(password);app.buttons["登录"].tap()
            }
            XCTAssertTrue(settings.waitForExistence(timeout:90));settings.tap()
            let resume=app.buttons["继续未完成的恢复或整理"]
            for _ in 0..<7 where !resume.isHittable { app.swipeUp() }
            XCTAssertTrue(resume.waitForExistence(timeout:20));resume.tap()
            let message=app.staticTexts["large-restore-export-message"]
            let completed=NSPredicate(format:"label CONTAINS %@", "恢复完成")
            await fulfillment(of:[XCTNSPredicateExpectation(predicate:completed,object:message)],timeout:180)
            let after=try await fixtureRequest("/api/v1/me/state/snapshots?representation=stored",method:"POST",token:token,body:[:])
            XCTAssertEqual(after["state_revision"] as? String,revision,"restore was committed twice")
        } else {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","恢复完成")).firstMatch.waitForExistence(timeout:180))
        }
    }

    @MainActor func testExperimentalLargeRestoreResume() async throws {
        continueAfterFailure=false
        let seed=try await fixtureRequest("/api/v1/__ui_fixture/staged-ui-case")
        let username=try XCTUnwrap(seed["username"] as? String),password=try XCTUnwrap(seed["password"] as? String)
        let app=XCUIApplication();app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765";app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30));app.buttons["登录"].tap()
        let user=app.textFields["auth-username"],pass=app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout:20));pass.tap();pass.typeText(password);app.buttons["登录"].tap()
        let settings=app.buttons["settings-menu"]
        XCTAssertTrue(settings.waitForExistence(timeout:90));settings.tap()
        let resume=app.buttons["继续未完成的恢复或整理"]
        for _ in 0..<7 where !resume.isHittable { app.swipeUp() }
        XCTAssertTrue(resume.waitForExistence(timeout:20));resume.tap()
        let message=app.staticTexts["large-restore-export-message"]
        let completed=NSPredicate(format:"label CONTAINS %@", "恢复完成")
        await fulfillment(of:[XCTNSPredicateExpectation(predicate:completed,object:message)],timeout:180)
    }

    @MainActor func testExperimentalLargeRestoreLocalConflict() async throws {
        continueAfterFailure=false
        let seed=try await fixtureRequest("/api/v1/__ui_fixture/staged-ui-case")
        let username=try XCTUnwrap(seed["username"] as? String),password=try XCTUnwrap(seed["password"] as? String)
        let app=XCUIApplication();app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765";app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30));app.buttons["登录"].tap()
        let user=app.textFields["auth-username"],pass=app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout:20));pass.tap();pass.typeText(password);app.buttons["登录"].tap()
        let settings=app.buttons["settings-menu"];XCTAssertTrue(settings.waitForExistence(timeout:90));settings.tap()
        let fifteen=app.buttons["setting-new-15"],twenty=app.buttons["setting-new-20"]
        XCTAssertTrue(fifteen.waitForExistence(timeout:20));XCTAssertTrue(twenty.exists)
        if fifteen.value as? String == "已选择" { twenty.tap() } else { fifteen.tap() }
        let resume=app.buttons["继续未完成的恢复或整理"]
        for _ in 0..<7 where !resume.isHittable { app.swipeUp() }
        XCTAssertTrue(resume.waitForExistence(timeout:20));resume.tap()
        let message=app.staticTexts["large-restore-export-message"]
        let blocked=NSPredicate(format:"label CONTAINS %@", "本机进度已变化")
        await fulfillment(of:[XCTNSPredicateExpectation(predicate:blocked,object:message)],timeout:180)
    }

    @MainActor func testExperimentalLargeReplayAfterProcessTermination() async throws {
        continueAfterFailure = false
        let seed=try await fixtureRequest("/api/v1/__ui_fixture/staged-ui-case")
        let username=try XCTUnwrap(seed["username"] as? String), password=try XCTUnwrap(seed["password"] as? String), token=try XCTUnwrap(seed["token"] as? String)
        let app=XCUIApplication();app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765"
        func logIn() {
            let login=app.buttons["登录"], user=app.textFields["auth-username"], pass=app.secureTextFields["auth-password"]
            XCTAssertTrue(login.waitForExistence(timeout:30));login.tap()
            XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(username)
            XCTAssertTrue(pass.waitForExistence(timeout:20));pass.tap();pass.typeText(password);app.buttons["登录"].tap()
        }
        _ = try await fixtureRequest("/api/v1/__ui_fixture/delta-hold-response",method:"POST")
        app.launch();logIn()
        var held=false
        for _ in 0..<900 {
            if try await fixtureRequest("/api/v1/__ui_fixture/delta-hold-status")["started"] as? Bool == true { held=true;break }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertTrue(held,"large staged upload did not commit")
        let before=try await fixtureRequest("/api/v1/me/state/snapshots?representation=stored",method:"POST",token:token,body:[:])
        let revision=try XCTUnwrap(before["state_revision"] as? String)
        XCTAssertGreaterThan(before["byte_length"] as? Int ?? 0,8*1024*1024)
        app.terminate();_ = try await fixtureRequest("/api/v1/__ui_fixture/delta-release-response",method:"POST")
        app.launch();let home=app.buttons["settings-menu"]
        if !home.waitForExistence(timeout:8) { logIn() }
        XCTAssertTrue(home.waitForExistence(timeout:60));app.buttons["account-menu"].tap()
        let sync=app.buttons["立即同步"];XCTAssertTrue(sync.waitForExistence(timeout:20));sync.tap()
        XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout:90))
        let after=try await fixtureRequest("/api/v1/me/state/snapshots?representation=stored",method:"POST",token:token,body:[:])
        XCTAssertEqual(after["state_revision"] as? String,revision,"large replay changed revision")
        XCTAssertEqual(after["sha256"] as? String,before["sha256"] as? String)
    }

    @MainActor func testDeltaReplayAfterProcessTermination() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        let login = app.buttons["登录"], user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        func logIn() {
            XCTAssertTrue(login.waitForExistence(timeout: 30)); login.tap()
            XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
            XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
            app.buttons["登录"].tap()
        }
        app.launch(); logIn()
        let home = app.buttons["settings-menu"]
        XCTAssertTrue(home.waitForExistence(timeout: 30)); home.tap()
        let twenty = app.buttons["setting-new-20"]
        XCTAssertTrue(twenty.waitForExistence(timeout: 20))
        _ = try await fixtureRequest("/api/v1/__ui_fixture/delta-hold-response", method: "POST")
        twenty.tap()
        var held = false
        for _ in 0..<150 {
            let status = try await fixtureRequest("/api/v1/__ui_fixture/delta-hold-status")
            if status["started"] as? Bool == true { held = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(held, "incremental upload did not commit before termination")
        let committed = try await fixtureRequest("/api/v1/me/state", token: token)
        let committedRevision = try XCTUnwrap(committed["state_revision"] as? String)
        let state = try XCTUnwrap(committed["state"] as? [String: Any])
        XCTAssertEqual((state["settings"] as? [String: Any])?["newPerDay"] as? Int, 20)
        app.terminate()
        _ = try await fixtureRequest("/api/v1/__ui_fixture/delta-release-response", method: "POST")
        app.launch()
        if !home.waitForExistence(timeout: 8) { logIn() }
        XCTAssertTrue(home.waitForExistence(timeout: 30))
        app.buttons["account-menu"].tap()
        let sync = app.buttons["立即同步"]
        XCTAssertTrue(sync.waitForExistence(timeout: 20)); sync.tap()
        XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout: 30))
        let after = try await fixtureRequest("/api/v1/me/state", token: token)
        XCTAssertEqual(after["state_revision"] as? String, committedRevision, "replaying a committed batch changed the revision")
        let status = try await fixtureRequest("/api/v1/__ui_fixture/state-upload-status")
        XCTAssertGreaterThanOrEqual(status["delta_attempts"] as? Int ?? 0, 2)
    }

    @MainActor func testMissingMeaningRetryAndDefer() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/meaning-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let start = app.buttons["start-today"]
        XCTAssertTrue(start.waitForExistence(timeout: 30)); start.tap()
        let retry = app.buttons["重新加载词义"], next = app.buttons["学会了 →"], weak = app.buttons["不熟悉"]
        XCTAssertTrue(retry.waitForExistence(timeout: 30)); XCTAssertFalse(next.isEnabled); XCTAssertFalse(weak.isEnabled)
        XCTAssertFalse(app.staticTexts["wrong meaning"].exists)
        _ = try await fixtureRequest("/api/v1/__ui_fixture/meaning-mode", method: "POST", body: ["mode":"wrong"])
        retry.tap(); try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(retry.waitForExistence(timeout: 20)); XCTAssertFalse(next.isEnabled)
        XCTAssertFalse(app.staticTexts["wrong meaning"].exists)
        _ = try await fixtureRequest("/api/v1/__ui_fixture/meaning-mode", method: "POST", body: ["mode":"empty"])
        retry.tap()
        XCTAssertTrue(app.staticTexts["词义暂不可用，请重试或稍后再学。"].waitForExistence(timeout: 20))
        XCTAssertFalse(next.isEnabled)
        _ = try await fixtureRequest("/api/v1/__ui_fixture/meaning-mode", method: "POST", body: ["mode":"normal"])
        retry.tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: next)
        await fulfillment(of: [ready], timeout: 20)
        XCTAssertTrue(app.staticTexts["pear"].exists)
        app.buttons["退出"].tap()
        _ = try await fixtureRequest("/api/v1/__ui_fixture/meaning-mode", method: "POST", body: ["mode":"offline"])
        XCTAssertTrue(start.waitForExistence(timeout: 20)); start.tap()
        let later = app.buttons["稍后再学"]
        XCTAssertTrue(later.waitForExistence(timeout: 20)); later.tap()
        XCTAssertTrue(app.buttons["返回主页"].waitForExistence(timeout: 20)); app.buttons["返回主页"].tap()
        app.buttons["account-menu"].tap()
        XCTAssertTrue(app.buttons["立即同步"].waitForExistence(timeout: 20)); app.buttons["立即同步"].tap()
        XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout: 30))
        let response = try await fixtureRequest("/api/v1/me/state", token: token)
        let state = try XCTUnwrap(response["state"] as? [String: Any])
        XCTAssertTrue((state["pendingNew"] as? [[String: Any]] ?? []).contains { $0["word"] as? String == "pear" })
        XCTAssertNil((state["cards"] as? [String: Any])?["pear"])
        XCTAssertFalse((state["log"] as? [[String: Any]] ?? []).contains { $0["word"] as? String == "pear" && $0["kind"] as? String == "learn" })
    }

    @MainActor func testAcceptanceResponseDoesNotCrossAccounts() async throws {
        continueAfterFailure = false
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date())
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/acceptance-switch-case", method: "POST", body: ["day":day])
        let old = try XCTUnwrap(seed["old"] as? [String: Any])
        let new = try XCTUnwrap(seed["new"] as? [String: Any])
        let oldName = try XCTUnwrap(old["username"] as? String)
        let newName = try XCTUnwrap(new["username"] as? String)
        let password = try XCTUnwrap(old["password"] as? String)
        let newToken = try XCTUnwrap(new["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        let login = app.buttons["登录"]
        func loginAccount(_ username: String) {
            XCTAssertTrue(login.waitForExistence(timeout: 30)); login.tap()
            let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
            XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
            XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
            app.buttons["登录"].tap()
        }
        loginAccount(oldName)
        XCTAssertTrue(app.buttons["start-today"].waitForExistence(timeout: 30)); app.buttons["start-today"].tap()
        let option = app.buttons["quiz-option-0"]
        XCTAssertTrue(option.waitForExistence(timeout: 30)); option.tap()
        var attempts = 0
        for _ in 0..<50 {
            let status = try await fixtureRequest("/api/v1/__ui_fixture/fsrs-status")
            attempts = status["attempts"] as? Int ?? 0
            if attempts > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(attempts, 0, "acceptance review did not start")
        let back = app.buttons["返回主页"]
        XCTAssertTrue(back.waitForExistence(timeout: 20)); back.tap()
        XCTAssertTrue(app.buttons["account-menu"].waitForExistence(timeout: 20)); app.buttons["account-menu"].tap()
        XCTAssertTrue(app.buttons["退出登录"].waitForExistence(timeout: 20)); app.buttons["退出登录"].tap()
        XCTAssertTrue(login.waitForExistence(timeout: 30)); loginAccount(newName)
        let learned = app.descendants(matching: .any)["learned-count"]
        XCTAssertTrue(learned.waitForExistence(timeout: 30))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "2"), object: learned)
        await fulfillment(of: [loaded], timeout: 30)
        _ = try await fixtureRequest("/api/v1/__ui_fixture/fsrs-release", method: "POST")
        var completed = 0
        for _ in 0..<50 {
            let status = try await fixtureRequest("/api/v1/__ui_fixture/fsrs-status")
            completed = status["completed"] as? Int ?? 0
            if completed > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(completed, 0, "held review did not complete")
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(app.buttons["start-today"].exists, "old acceptance replaced new account home")
        let response = try await fixtureRequest("/api/v1/me/state", token: newToken)
        let state = try XCTUnwrap(response["state"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(state["cards"] as? [String: Any]).keys), Set(["banana", "cherry"]))
        XCTAssertFalse((state["quizCompleted"] as? [String] ?? []).contains("apple"))
        XCTAssertFalse((state["log"] as? [[String: Any]] ?? []).contains { $0["word"] as? String == "apple" })
        let renewed = try await fixtureRequest("/api/v1/auth/login", method: "POST", body: ["username":oldName, "password":password])
        let oldToken = try XCTUnwrap(renewed["token"] as? String)
        let oldResponse = try await fixtureRequest("/api/v1/me/state", token: oldToken)
        let oldState = try XCTUnwrap(oldResponse["state"] as? [String: Any])
        XCTAssertTrue((oldState["quizCompleted"] as? [String] ?? []).contains("apple"), "old acceptance progress did not sync")
        XCTAssertEqual((oldState["log"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "review" && $0["word"] as? String == "apple" }.count, 1)
    }

    @MainActor func testQueueUsesFinalPartialVocabularyPage() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/queue-end-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let expected = try XCTUnwrap(seed["expected"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        XCTAssertTrue(app.buttons["start-today"].waitForExistence(timeout: 30)); app.buttons["start-today"].tap()
        XCTAssertTrue(app.buttons["学会了 →"].waitForExistence(timeout: 30), "final partial batch was rejected")
        XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "新词 1/1")).firstMatch.exists)
    }

    @MainActor func testQueuePaginationRetriesAfterFailure() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/queue-pages-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let expected = try XCTUnwrap(seed["expected"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let start = app.buttons["start-today"]
        XCTAssertTrue(start.waitForExistence(timeout: 30)); start.tap()
        let retry = app.buttons["重新加载"]
        XCTAssertTrue(retry.waitForExistence(timeout: 30), "partial page failure did not remain on home")
        XCTAssertTrue(app.staticTexts["任务加载失败，请检查网络后重试"].exists)
        let response = try await fixtureRequest("/api/v1/me/state", token: token)
        let state = try XCTUnwrap(response["state"] as? [String: Any])
        XCTAssertEqual(state["pointer"] as? Int, 1)
        XCTAssertEqual((state["cards"] as? [String: Any])?.count, 6)
        _ = try await fixtureRequest("/api/v1/__ui_fixture/queue-pages-online", method: "POST")
        retry.tap()
        XCTAssertTrue(app.buttons["学会了 →"].waitForExistence(timeout: 30), "retry failed to reach the next unseen word")
        XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 10), "wrong word after skipping known vocabulary")
    }

    @MainActor func testQueuePreparationDoesNotCrossAccounts() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/queue-switch-case", method: "POST")
        let old = try XCTUnwrap(seed["old"] as? [String: Any])
        let new = try XCTUnwrap(seed["new"] as? [String: Any])
        let oldName = try XCTUnwrap(old["username"] as? String)
        let newName = try XCTUnwrap(new["username"] as? String)
        let password = try XCTUnwrap(old["password"] as? String)
        let newToken = try XCTUnwrap(new["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        let login = app.buttons["登录"]
        func loginAccount(_ username: String) {
            XCTAssertTrue(login.waitForExistence(timeout: 30)); login.tap()
            let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
            XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
            XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
            app.buttons["登录"].tap()
        }
        loginAccount(oldName)
        let start = app.buttons["start-today"]
        XCTAssertTrue(start.waitForExistence(timeout: 30)); start.tap()
        var attempts = 0
        for _ in 0..<50 {
            let status = try await fixtureRequest("/api/v1/__ui_fixture/queue-status")
            attempts = status["attempts"] as? Int ?? 0
            if attempts > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(attempts, 0, "old account request did not start")
        app.buttons["account-menu"].tap()
        XCTAssertTrue(app.buttons["退出登录"].waitForExistence(timeout: 20)); app.buttons["退出登录"].tap()
        XCTAssertTrue(login.waitForExistence(timeout: 30)); loginAccount(newName)
        let learned = app.descendants(matching: .any)["learned-count"]
        XCTAssertTrue(learned.waitForExistence(timeout: 30))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "2"), object: learned)
        await fulfillment(of: [loaded], timeout: 30)
        _ = try await fixtureRequest("/api/v1/__ui_fixture/queue-release", method: "POST")
        var completed = 0
        for _ in 0..<50 {
            let status = try await fixtureRequest("/api/v1/__ui_fixture/queue-status")
            completed = status["completed"] as? Int ?? 0
            if completed > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(completed, 0, "old account response was not released")
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(start.exists, "old account request opened a session on the new account")
        XCTAssertTrue(learned.label.contains("2"), "old queue changed the new account's cards")
        let response = try await fixtureRequest("/api/v1/me/state", token: newToken)
        let state = try XCTUnwrap(response["state"] as? [String: Any])
        let cards = try XCTUnwrap(state["cards"] as? [String: Any])
        XCTAssertEqual(Set(cards.keys), Set(["banana", "cherry"]))
    }

    @MainActor func testDailyCapacityAndDoneScreen() async throws {
        continueAfterFailure = false
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/budget-case", method: "POST", body: ["day":formatter.string(from: Date())])
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        XCTAssertTrue(app.staticTexts["2 / 3"].waitForExistence(timeout: 30))
        let newPlan = app.descendants(matching: .any)["daily-new-planned"]
        XCTAssertTrue(newPlan.waitForExistence(timeout: 10)); XCTAssertTrue(newPlan.label.contains("0"))
        app.buttons["start-today"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "复习 1/1")).firstMatch.waitForExistence(timeout: 30))
        let option = app.buttons["quiz-option-0"]
        XCTAssertTrue(option.waitForExistence(timeout: 30)); option.tap()
        let remember = app.buttons["记得"]
        XCTAssertTrue(remember.waitForExistence(timeout: 30)); remember.tap()
        let limit = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "今日已达上限，还有 1 词到期")).firstMatch
        XCTAssertTrue(limit.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "继续复习")).firstMatch.exists)
        app.buttons["返回主页"].tap()
        XCTAssertTrue(app.staticTexts["3 / 3"].waitForExistence(timeout: 20))
        let response = try await fixtureRequest("/api/v1/me/state", token: token)
        let state = try XCTUnwrap(response["state"] as? [String: Any])
        let cards = try XCTUnwrap(state["cards"] as? [String: Any])
        XCTAssertNotNil(cards["pear"])
    }

    @MainActor func testLegacyDateOnlyCardIsReviewable() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let response = try await fixtureRequest("/api/v1/me/state", token: token)
        var state = try XCTUnwrap(response["state"] as? [String: Any])
        var cards = try XCTUnwrap(state["cards"] as? [String: Any])
        var apple = try XCTUnwrap(cards["apple"] as? [String: Any])
        apple["due"] = "2020-01-01"; cards["apple"] = apple; state["cards"] = cards
        state["settings"] = ["newPerDay":0, "dailyCap":1]
        _ = try await fixtureRequest("/api/v1/me/state", method: "PUT", token: token, body: state)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        XCTAssertTrue(app.staticTexts["0 / 1"].waitForExistence(timeout: 30), "legacy card missing from today's plan")
        app.buttons["start-today"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "复习 1/1")).firstMatch.waitForExistence(timeout: 30))
    }

    @MainActor func testForecastShowsOverdueLegacyCard() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String), password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let response = try await fixtureRequest("/api/v1/me/state", token: token)
        var state = try XCTUnwrap(response["state"] as? [String: Any])
        var cards = try XCTUnwrap(state["cards"] as? [String: Any])
        var apple = try XCTUnwrap(cards["apple"] as? [String: Any])
        apple["due"] = "2020-01-01"; cards["apple"] = apple; state["cards"] = cards
        _ = try await fixtureRequest("/api/v1/me/state", method: "PUT", token: token, body: state)
        let app = XCUIApplication(); app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"; app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let stats = app.buttons["stats-menu"]; XCTAssertTrue(stats.waitForExistence(timeout: 30)); stats.tap()
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "forecast-")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20)); XCTAssertTrue(first.label.contains("1词"), "forecast: \(first.label)")
    }

    @MainActor func testRetentionUsesActualReviewTime() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String), password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let response = try await fixtureRequest("/api/v1/me/state", token: token)
        var state = try XCTUnwrap(response["state"] as? [String: Any])
        var cards = try XCTUnwrap(state["cards"] as? [String: Any])
        var apple = try XCTUnwrap(cards["apple"] as? [String: Any])
        let last = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20 * 86400))
        apple["fsrs"] = ["state":2, "stability":10.0, "difficulty":5.0, "lastReview":last]
        cards["apple"] = apple
        cards["banana"] = ["pos":2, "stage":1, "fsrs":["state":2, "stability":10.0, "difficulty":5.0]]
        state["cards"] = cards
        let day = DateFormatter(); day.locale = Locale(identifier:"en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        state["log"] = [["d":day.string(from: Date()), "word":"apple", "rating":3, "kind":"exposure"]]
        _ = try await fixtureRequest("/api/v1/me/state", method:"PUT", token:token, body:state)
        let app = XCUIApplication(); app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"; app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let stats = app.buttons["stats-menu"]; XCTAssertTrue(stats.waitForExistence(timeout: 30)); stats.tap()
        let bucket = app.descendants(matching:.any)["retention-bin-2"]
        XCTAssertTrue(bucket.waitForExistence(timeout: 20)); XCTAssertTrue(bucket.label.contains("1词"), "bucket: \(bucket.label)")
        let note = app.descendants(matching:.any)["retention-summary"]
        XCTAssertTrue(note.waitForExistence(timeout: 10)); XCTAssertTrue(note.label.contains("1 词缺少可用信息"), "note: \(note.label)")
    }

    @MainActor func testLegacySlotConfirmationAndRestore() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/interop-case")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let learned = app.descendants(matching: .any)["learned-count"]
        XCTAssertTrue(learned.waitForExistence(timeout: 30)); XCTAssertTrue(learned.label.contains("1"))
        app.buttons["settings-menu"].tap()
        let check = app.buttons["检查并恢复旧存档 1"]
        for _ in 0..<6 where !check.isHittable { app.swipeUp() }
        XCTAssertTrue(check.waitForExistence(timeout: 20)); check.tap()
        let confirm = app.alerts["恢复学习进度？"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20))
        XCTAssertTrue(confirm.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "pear")).firstMatch.exists, "preview did not identify legacy content")
        confirm.buttons["取消"].tap()
        let cancelled = try await fixtureRequest("/api/v1/me/state", token: token)
        let cancelledState = try XCTUnwrap(cancelled["state"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(cancelledState["cards"] as? [String: Any]).keys), Set(["apple"]))
        check.tap(); XCTAssertTrue(confirm.waitForExistence(timeout: 20)); confirm.buttons["恢复"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "恢复完成")).firstMatch.waitForExistence(timeout: 30))
        let result = try await fixtureRequest("/api/v1/me/state", token: token)
        let state = try XCTUnwrap(result["state"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(state["cards"] as? [String: Any]).keys), Set(["pear"]))
        let list = try await fixtureRequest("/api/v1/me/state/backups", token: token)
        let backups = try XCTUnwrap(list["backups"] as? [[String: Any]])
        let before = try XCTUnwrap(backups.first(where: { $0["reason"] as? String == "before_restore" }))
        let id = try XCTUnwrap(before["id"] as? Int)
        let saved = try await fixtureRequest("/api/v1/me/state/backups/\(id)", token: token)
        let savedState = try XCTUnwrap(saved["state"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(savedState["cards"] as? [String: Any]).keys), Set(["apple"]))
    }

    @MainActor func testReusedAccountIdentityIsolation() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        let login = app.buttons["登录"]
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        func loginAccount() {
            XCTAssertTrue(login.waitForExistence(timeout: 30)); login.tap()
            XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
            XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
            app.buttons["登录"].tap()
        }
        loginAccount()
        let learned = app.descendants(matching: .any)["learned-count"]
        XCTAssertTrue(learned.waitForExistence(timeout: 30)); XCTAssertTrue(learned.label.contains("1"))
        app.buttons["account-menu"].tap()
        XCTAssertTrue(app.buttons["退出登录"].waitForExistence(timeout: 20)); app.buttons["退出登录"].tap()
        XCTAssertTrue(login.waitForExistence(timeout: 30))
        let replacement = try await fixtureRequest("/api/v1/__ui_fixture/replace-account", method: "POST", body: ["token":token])
        XCTAssertNotEqual(replacement["oldAccountId"] as? String, replacement["newAccountId"] as? String)
        loginAccount()
        XCTAssertTrue(learned.waitForExistence(timeout: 30)); XCTAssertTrue(learned.label.contains("2"), "replacement loaded old account state: \(learned.label)")
        let newToken = try XCTUnwrap(replacement["token"] as? String)
        let response = try await fixtureRequest("/api/v1/me/state", token: newToken)
        let state = try XCTUnwrap(response["state"] as? [String: Any])
        let cards = try XCTUnwrap(state["cards"] as? [String: Any])
        XCTAssertEqual(Set(cards.keys), Set(["banana", "cherry"]))
    }

    @MainActor func testPersonalSentenceRejection() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/personal-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let initial = try await fixtureRequest("/api/v1/me/state", token: token)
        let stale = try XCTUnwrap(initial["state"] as? [String: Any])
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let start = app.buttons["start-today"]
        XCTAssertTrue(start.waitForExistence(timeout: 30)); start.tap()
        let option = app.buttons["quiz-option-0"]
        XCTAssertTrue(option.waitForExistence(timeout: 30)); option.tap()
        let sentence = app.staticTexts["An old sentence."]
        XCTAssertTrue(sentence.waitForExistence(timeout: 30))
        let replace = app.buttons["swap-personal-apple"]
        XCTAssertTrue(replace.waitForExistence(timeout: 10)); replace.tap()
        var recorded = false
        for _ in 0..<40 {
            let current = try await fixtureRequest("/api/v1/me/state", token: token)
            let state = try XCTUnwrap(current["state"] as? [String: Any])
            let rejected = (state["rejectedPersonalized"] as? [String: [String]])?["apple"] ?? []
            if rejected.contains("An old sentence.") { recorded = true; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertTrue(recorded, "rejection did not sync while generation was unavailable")
        _ = try await fixtureRequest("/api/v1/me/state", method: "PUT", token: token, body: stale)
        let result = try await fixtureRequest("/api/v1/me/state", token: token)
        let state = try XCTUnwrap(result["state"] as? [String: Any])
        let rejected = try XCTUnwrap(state["rejectedPersonalized"] as? [String: [String]])
        XCTAssertTrue(rejected["apple"]?.contains("An old sentence.") == true)
        XCTAssertNil((state["personalized"] as? [String: Any])?["apple"])
        _ = try await fixtureRequest("/api/v1/__ui_fixture/personal-online", method: "POST")
        let fresh = app.staticTexts["Apple is on the table."]
        XCTAssertTrue(fresh.waitForExistence(timeout: 35), "queued replacement did not recover")
        var recovered = false
        for _ in 0..<30 {
            let current = try await fixtureRequest("/api/v1/me/state", token: token)
            let latest = try XCTUnwrap(current["state"] as? [String: Any])
            let sentences = latest["personalized"] as? [String: [String: Any]]
            if sentences?["apple"]?["text"] as? String == "Apple is on the table." { recovered = true; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertTrue(recovered, "replacement was not synced after recovery")
        XCTAssertTrue(app.buttons["退出"].waitForExistence(timeout: 10)); app.buttons["退出"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 20))
    }

    @MainActor func testReplacementPlacementResume() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        func loginIfNeeded() {
            let login = app.buttons["登录"]
            if login.waitForExistence(timeout: 10) {
                login.tap()
                let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
                XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
                XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
                app.buttons["登录"].tap()
            }
        }
        app.launch(); loginIfNeeded()
        let learned = app.descendants(matching: .any)["learned-count"]
        XCTAssertTrue(learned.waitForExistence(timeout: 30)); XCTAssertTrue(learned.label.contains("1"))
        app.buttons["settings-menu"].tap()
        let reset = app.buttons["重新定级（30 题重测词汇边界）"]
        XCTAssertTrue(reset.waitForExistence(timeout: 20)); reset.tap()
        let confirm = app.alerts["重新定级？"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20)); confirm.buttons["开始重测"].tap()
        let progress = app.staticTexts["placement-progress"]
        func answer(_ index: Int) {
            expectation(for: NSPredicate(format: "label CONTAINS %@", "第 \(index)/30"), evaluatedWith: progress)
            waitForExpectations(timeout: 30)
            let unknown = app.buttons["不认识"]
            XCTAssertTrue(unknown.waitForExistence(timeout: 30)); unknown.tap()
        }
        for index in 1...3 { answer(index) }
        expectation(for: NSPredicate(format: "label CONTAINS %@", "第 4/30"), evaluatedWith: progress)
        waitForExpectations(timeout: 30)
        app.buttons["退出"].tap()
        XCTAssertTrue(app.buttons["继续定级"].waitForExistence(timeout: 20))
        app.terminate(); app.launch(); loginIfNeeded()
        let resume = app.buttons["继续定级"]
        XCTAssertTrue(resume.waitForExistence(timeout: 30)); resume.tap()
        for index in 4...30 { answer(index) }
        let finish = app.buttons["开始学习"]
        XCTAssertTrue(finish.waitForExistence(timeout: 30))
        let summary = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "发词位置")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        let label = summary.label
        let regex = try NSRegularExpression(pattern: "：([0-9]+)/([0-9]+)")
        let matches = regex.matches(in: label, range: NSRange(label.startIndex..., in: label))
        XCTAssertEqual(matches.count, 6)
        let scores = matches.map { match -> (Int, Int) in
            let correct = Int(String(label[Range(match.range(at: 1), in: label)!]))!
            let total = Int(String(label[Range(match.range(at: 2), in: label)!]))!
            return (correct, total)
        }
        XCTAssertEqual(scores.reduce(0) { $0 + $1.0 }, 0)
        XCTAssertEqual(scores.reduce(0) { $0 + $1.1 }, 30)
        app.buttons["返回首页"].tap()
        XCTAssertTrue(learned.waitForExistence(timeout: 30)); XCTAssertTrue(learned.label.contains("1"))
        app.buttons["account-menu"].tap()
        XCTAssertTrue(app.buttons["立即同步"].waitForExistence(timeout: 20)); app.buttons["立即同步"].tap()
        XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout: 30))
        let response = try await fixtureRequest("/api/v1/me/state", token: token)
        let state = try XCTUnwrap(response["state"] as? [String: Any])
        let cards = try XCTUnwrap(state["cards"] as? [String: Any])
        XCTAssertNotNil(cards["apple"])
        XCTAssertEqual(state["probeCount"] as? Int, 30)
        XCTAssertEqual(state["calibrated"] as? Bool, true)
        XCTAssertNotNil(state["placementVersion"] as? [String: Any])
    }

    @MainActor func testWebLargeReloadSettingsSync() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/interop-case")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let before = try await fixtureRequest("/api/v1/me/state/snapshots?representation=stored", method:"POST", token:token, body:[:])
        XCTAssertGreaterThan(before["byte_length"] as? Int ?? 0, 8 * 1024 * 1024)
        XCTAssertEqual(before["restore_epoch"] as? Int, 3)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        XCTAssertTrue(app.buttons["settings-menu"].waitForExistence(timeout: 90)); app.buttons["settings-menu"].tap()
        let cap = app.buttons["setting-cap-30"], twenty = app.buttons["setting-new-20"]
        XCTAssertTrue(cap.waitForExistence(timeout: 20)); XCTAssertEqual(cap.value as? String, "已选择")
        XCTAssertTrue(twenty.waitForExistence(timeout: 20)); twenty.tap(); XCTAssertEqual(twenty.value as? String, "已选择")
        app.buttons["返回"].tap(); app.buttons["account-menu"].tap()
        XCTAssertTrue(app.buttons["立即同步"].waitForExistence(timeout: 20)); app.buttons["立即同步"].tap()
        XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout: 90))
        let after = try await fixtureRequest("/api/v1/me/state/snapshots?representation=stored", method:"POST", token:token, body:[:])
        XCTAssertGreaterThan(after["byte_length"] as? Int ?? 0, 8 * 1024 * 1024)
        XCTAssertEqual(after["restore_epoch"] as? Int, 3)
        XCTAssertNotEqual(after["state_revision"] as? String, before["state_revision"] as? String)
    }

    @MainActor func testWebRestoredSettingsSync() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/interop-case")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let learned = app.descendants(matching: .any)["learned-count"]
        XCTAssertTrue(learned.waitForExistence(timeout: 30)); XCTAssertTrue(learned.label.contains("1"))
        let initial = try await fixtureRequest("/api/v1/me/state", token: token)
        let state = try XCTUnwrap(initial["state"] as? [String: Any])
        let settings = try XCTUnwrap(state["settings"] as? [String: Any])
        XCTAssertEqual(state["restoreEpoch"] as? Int, 1)
        XCTAssertEqual(settings["dailyCap"] as? Int, 30)
        XCTAssertTrue(app.buttons["settings-menu"].waitForExistence(timeout: 20)); app.buttons["settings-menu"].tap()
        let twenty = app.buttons["setting-new-20"]
        XCTAssertTrue(twenty.waitForExistence(timeout: 20)); twenty.tap(); XCTAssertEqual(twenty.value as? String, "已选择")
        app.buttons["返回"].tap(); app.buttons["account-menu"].tap()
        XCTAssertTrue(app.buttons["立即同步"].waitForExistence(timeout: 20)); app.buttons["立即同步"].tap()
        var synced = false
        for _ in 0..<100 {
            let latest = try await fixtureRequest("/api/v1/me/state", token: token)
            let current = latest["state"] as? [String: Any]
            let values = current?["settings"] as? [String: Any]
            if values?["newPerDay"] as? Int == 20 && current?["restoreEpoch"] as? Int == 1 { synced = true; break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(synced, "iOS setting did not reach the restored server state")
    }

    @MainActor func testWebSettingsAndHistoryCheckpoint() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/interop-case")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let learned = app.descendants(matching: .any)["learned-count"]
        XCTAssertTrue(learned.waitForExistence(timeout: 30)); XCTAssertTrue(learned.label.contains("1"))
        let initial = try await fixtureRequest("/api/v1/me/state", token: token)
        let initialState = try XCTUnwrap(initial["state"] as? [String: Any])
        let initialSettings = try XCTUnwrap(initialState["settings"] as? [String: Any])
        XCTAssertEqual(initialSettings["dailyCap"] as? Int, 30)
        let settings = app.buttons["settings-menu"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20)); settings.tap()
        let cap = app.buttons["setting-cap-30"]
        XCTAssertTrue(cap.waitForExistence(timeout: 20)); XCTAssertEqual(cap.value as? String, "已选择")
        let newWords = app.buttons["setting-new-20"]
        newWords.tap(); XCTAssertEqual(newWords.value as? String, "已选择")
        let checkpoint = app.buttons["整理已同步的历史"]
        for _ in 0..<5 where !checkpoint.isHittable { app.swipeUp() }
        XCTAssertTrue(checkpoint.waitForExistence(timeout: 10)); checkpoint.tap()
        let confirm = app.alerts["整理已同步的历史？"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20)); confirm.buttons["整理"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "整理完成")).firstMatch.waitForExistence(timeout: 30))
        let result = try await fixtureRequest("/api/v1/me/state", token: token)
        let state = try XCTUnwrap(result["state"] as? [String: Any])
        let values = try XCTUnwrap(state["settings"] as? [String: Any])
        XCTAssertEqual(values["newPerDay"] as? Int, 20)
        XCTAssertEqual(values["dailyCap"] as? Int, 30)
        XCTAssertEqual(state["restoreEpoch"] as? Int, 1)
        let list = try await fixtureRequest("/api/v1/me/state/backups", token: token)
        let backups = try XCTUnwrap(list["backups"] as? [[String: Any]])
        XCTAssertTrue(backups.contains { $0["reason"] as? String == "before_checkpoint" })
    }

    @MainActor func testReloadPreviewDoesNotCrossRelogin() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        func loginAccount() {
            let login = app.buttons["登录"]
            XCTAssertTrue(login.waitForExistence(timeout: 30)); login.tap()
            let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
            XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
            XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
            app.buttons["登录"].tap()
        }
        loginAccount()
        let menu = app.buttons["account-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30)); menu.tap()
        _ = try await fixtureRequest("/api/v1/__ui_fixture/state-get-hold-once", method: "POST")
        let reload = app.buttons["重新加载服务器进度"]
        XCTAssertTrue(reload.waitForExistence(timeout: 20)); reload.tap()
        var attempts = 0
        for _ in 0..<50 {
            attempts = try await fixtureRequest("/api/v1/__ui_fixture/state-get-status")["attempts"] as? Int ?? 0
            if attempts > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(attempts, 0)
        let switchAccount = app.buttons["切换账号 / 游客模式"]
        XCTAssertTrue(switchAccount.waitForExistence(timeout: 20)); switchAccount.tap()
        loginAccount()
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        _ = try await fixtureRequest("/api/v1/__ui_fixture/state-get-release", method: "POST")
        var completed = 0
        for _ in 0..<50 {
            completed = try await fixtureRequest("/api/v1/__ui_fixture/state-get-status")["completed"] as? Int ?? 0
            if completed > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(completed, 0)
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(app.alerts["重新加载服务器进度？"].exists, "old session opened a reload confirmation")
        XCTAssertTrue(menu.exists)
    }

    @MainActor func testServerReloadConflictAndBackup() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let learned = app.descendants(matching: .any)["learned-count"]
        XCTAssertTrue(learned.waitForExistence(timeout: 30)); XCTAssertTrue(learned.label.contains("1"))
        try await addRemoteCard("banana", token: token)
        let menu = app.buttons["account-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
        let reload = app.buttons["重新加载服务器进度"]
        XCTAssertTrue(reload.waitForExistence(timeout: 20)); reload.tap()
        let dialog = app.alerts["重新加载服务器进度？"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 20))
        try await addRemoteCard("cherry", token: token)
        dialog.buttons["重新加载"].tap()
        let conflict = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "服务器进度已变化")).firstMatch
        XCTAssertTrue(conflict.waitForExistence(timeout: 20), "stale preview was not rejected")
        reload.tap(); XCTAssertTrue(dialog.waitForExistence(timeout: 20)); dialog.buttons["重新加载"].tap()
        let success = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "服务器进度已加载")).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 20), "latest server state was not loaded")
        app.buttons["返回学习"].tap()
        XCTAssertTrue(learned.waitForExistence(timeout: 20)); XCTAssertTrue(learned.label.contains("3"))
    }
    @MainActor func testReminderDeniedIsVisible() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        XCTAssertTrue(app.buttons["settings-menu"].waitForExistence(timeout: 30)); app.buttons["settings-menu"].tap()
        let toggle = app.switches["setting-reminder-enabled"]
        for _ in 0..<8 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 20)); toggle.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "不允许"])).firstMatch
        XCTAssertTrue(deny.waitForExistence(timeout: 20), "Notification permission prompt did not appear")
        deny.tap()
        let warning = app.staticTexts["系统通知权限未开启，请在系统设置中允许词航发送通知。"]
        XCTAssertTrue(warning.waitForExistence(timeout: 20), "Denied notification permission was not reported")
    }
}
