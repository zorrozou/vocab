import XCTest

/// Run only against the isolated loopback fixture; never touches a production account.
final class VocabUITests: XCTestCase {
    private func capture(_ label:String,app:XCUIApplication) {
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name=label;shot.lifetime = .keepAlways;add(shot)
    }
    private func lightBackground(_ app:XCUIApplication) -> Bool {
        let image=app.screenshot().image
        guard let cg=image.cgImage,
              let pixel=cg.cropping(to:CGRect(x:2,y:cg.height/2,width:1,height:1)) else {return false}
        var rgba=[UInt8](repeating:0,count:4)
        rgba.withUnsafeMutableBytes { buffer in
            let ctx=CGContext(data:buffer.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,
                              space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(pixel,in:CGRect(x:0,y:0,width:1,height:1))
        }
        return rgba[1]>150
    }
    private func expectLight(_ expected:Bool, app:XCUIApplication,timeout:TimeInterval=8) {
        let ready=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.lightBackground(app)==expected },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:timeout),.completed)
    }

    private func vocabularyApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-coach.classic.interface.v1", "YES"]
        return app
    }

    private func credentialWarningVisible(_ app: XCUIApplication) -> Bool {
        // Unsigned simulator builds can reject Keychain writes. Compact home
        // pages keep secondary notices in the top bar's More sheet.
        if app.buttons["credential-status"].exists { return true }
        let more = app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","更多（")).firstMatch
        guard more.exists else { return false }
        more.tap()
        let visible = app.buttons["credential-status"].waitForExistence(timeout:3)
        app.buttons["关闭"].tap()
        return visible
    }

    private func onScreen(_ element: XCUIElement, app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let frame = element.frame
        return !frame.isEmpty && app.frame.insetBy(dx: -1, dy: -1).contains(frame)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<32 {
            if onScreen(element, app: app) { return }
            let next = app.buttons["page-next"]
            guard next.exists && next.isEnabled && next.isHittable else { break }
            next.tap()
        }
        if !onScreen(element, app: app) {
            capture("unreachable-control", app: app)
            XCTFail("Control unavailable without scrolling: \(element.identifier) at \(element.frame), viewport \(app.frame)", file: file, line: line)
        }
    }

    private func selectSection(_ name: String, in app: XCUIApplication) {
        if ["词义","答案","例句","跟读"].contains(name) {
            if app.buttons["返回学习"].exists {app.buttons["返回学习"].tap()}
            if app.staticTexts["study-word"].waitForExistence(timeout:10) {
                if name=="跟读" {app.buttons["study-shadow"].tap()}
                return
            }
        }
        if app.buttons["section-menu"].waitForExistence(timeout: 0.5) {
            app.buttons["section-menu"].tap()
            let target = app.buttons[name].firstMatch
            reveal(target, in: app)
            target.tap()
        } else {
            let target = app.segmentedControls.buttons[name].firstMatch
            XCTAssertTrue(target.waitForExistence(timeout: 5))
            target.tap()
        }
    }

    @MainActor func testSingleScreenNavigation() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launchArguments += ["-vocab_guest", "NO"]
        app.launch()
        let guest = app.buttons["先逛逛（游客模式）"]
        XCTAssertTrue(guest.waitForExistence(timeout: 15)); reveal(guest, in: app); guest.tap()
        let classroom = app.buttons["home-section-0"]
        XCTAssertTrue(classroom.waitForExistence(timeout: 15))
        for i in [2,3,1,0] { let choice=app.buttons["home-section-\(i)"]; reveal(choice, in: app); choice.tap() }
        let bank = app.buttons["coach-bank"]
        XCTAssertTrue(bank.waitForExistence(timeout: 20)); reveal(bank, in: app); capture("compact-classroom",app:app); bank.tap()
        let transcript = app.buttons["coach-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 20));reveal(transcript,in:app);transcript.tap()
        let answer = app.buttons.matching(NSPredicate(format:"label CONTAINS %@", "去答题")).firstMatch
        reveal(answer,in:app); answer.tap()
        let choice = app.buttons["coach-option-0"]
        reveal(choice,in:app);choice.tap()
        let next = app.buttons["coach-next"];XCTAssertTrue(next.waitForExistence(timeout:15))
        selectSection("例解",in:app)
        let clue=app.buttons.matching(NSPredicate(format:"label CONTAINS %@", "请 AI 再讲一句")).firstMatch
        reveal(clue,in:app);selectSection("反馈",in:app);reveal(next,in:app)
        app.buttons["coach-pause"].tap()
        app.buttons["settings-menu"].tap()
        for name in ["外观与声音","复习提醒","定级与校验","离线与数据维护","导出与恢复","每日计划"] {
            selectSection(name,in:app)
            if name=="离线与数据维护" {reveal(app.buttons["下载／更新整库离线包"],in:app)}
        }
        reveal(app.buttons["setting-cap-100"],in:app);app.buttons["返回"].tap()
        app.buttons["stats-menu"].tap();selectSection("复习预测",in:app);selectSection("保持率",in:app)
        reveal(app.buttons["返回"],in:app);app.buttons["返回"].tap()
        app.buttons["home-section-1"].tap();let start=app.buttons["开始定级"];reveal(start,in:app);start.tap()
        let first=app.buttons["quiz-option-0"];XCTAssertTrue(first.waitForExistence(timeout:30))
        reveal(first,in:app);reveal(app.buttons["quiz-option-3"],in:app);capture("compact-placement",app:app)
        app.buttons["不认识"].tap();XCTAssertTrue(app.staticTexts["placement-progress"].label.contains("2/30"))
    }

    @MainActor func testSingleScreenKeyboardAndLargeText() async throws {
        continueAfterFailure = false
        let app=XCUIApplication()
        app.launchArguments=["-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityL"]
        app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765"
        app.launchArguments += ["-vocab_guest", "NO"]
        app.launch()
        let register=app.buttons["注册新账号"];reveal(register,in:app);register.tap()
        let name=app.textFields["auth-username"]; reveal(name,in:app);name.tap();name.typeText("screen_")
        let pass=app.secureTextFields["auth-password"];reveal(pass,in:app);pass.tap();pass.typeText("test_password_123")
        let submit=app.buttons["注册并登录"];reveal(submit,in:app)
        if app.keyboards.firstMatch.exists {XCTAssertLessThanOrEqual(submit.frame.maxY,app.keyboards.firstMatch.frame.minY+1)}
        capture("compact-keyboard",app:app)
        let back=app.buttons["返回"];reveal(back,in:app);back.tap()
        let guest=app.buttons["先逛逛（游客模式）"];reveal(guest,in:app);guest.tap()
        app.buttons["settings-menu"].tap();selectSection("离线与数据维护",in:app)
        let health=app.buttons["实际学习效果与存档健康"]; reveal(health,in:app);health.tap()
        reveal(app.buttons["关闭"],in:app);app.buttons["关闭"].tap()
    }

    @MainActor func testSingleScreenLongExample() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/personal-case", method: "POST")
        let token = try XCTUnwrap(seed["token"] as? String)
        let sentence = (1...25).map { "Line \($0). We can share an apple and read the next part together." }.joined(separator: "\n")
        let response = try await fixtureRequest("/api/v1/me/state", token: token)
        var state = try XCTUnwrap(response["state"] as? [String: Any])
        state["personalized"] = ["apple": ["text": sentence, "zh": "长例句验收"]]
        _ = try await fixtureRequest("/api/v1/me/state", method: "PUT", token: token, body: state)
        let app = vocabularyApp()
        app.launchArguments += ["-vocab_guest","NO"]
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        user.tap(); user.typeText(try XCTUnwrap(seed["username"] as? String))
        pass.tap(); pass.typeText(try XCTUnwrap(seed["password"] as? String)); app.buttons["登录"].tap()
        let start = app.buttons["start-today"]; XCTAssertTrue(start.waitForExistence(timeout: 20)); start.tap()
        let choice = app.buttons["quiz-option-0"]; XCTAssertTrue(choice.waitForExistence(timeout: 20)); choice.tap()
        let remember = app.buttons["记得"]; XCTAssertTrue(remember.waitForExistence(timeout: 20))
        selectSection("例句", in: app)
        app.buttons["study-more"].tap()
        let read = app.buttons["完整例句"].firstMatch; reveal(read, in: app); read.tap()
        let text = app.textViews["reader-page"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let next = app.buttons["reader-next"]
        XCTAssertTrue(next.isEnabled)
        var recovered = ""
        for _ in 0..<50 {
            recovered += try XCTUnwrap(text.value as? String)
            if !next.isEnabled { break }
            reveal(next, in: app); next.tap()
        }
        XCTAssertEqual(recovered, sentence)
        capture("compact-reader-last-page",app:app)
        app.buttons["关闭"].tap()
        selectSection("跟读", in: app); selectSection("答案", in: app)
        reveal(remember,in:app); remember.tap()
        let home = app.buttons["返回主页"]
        XCTAssertTrue(home.waitForExistence(timeout:20)); home.tap()
        app.buttons["account-menu"].tap()
        reveal(app.buttons["立即同步"], in: app)
        selectSection("云端备份", in: app); reveal(app.buttons["查看服务器恢复前备份"], in: app)
        selectSection("登录管理", in: app)
        let logout = app.buttons["退出登录"]; reveal(logout, in: app); logout.tap()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 20))
    }

    @MainActor func testSingleScreenValidation() async throws {
        continueAfterFailure = false
        let app = vocabularyApp()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launchArguments += ["-vocab_guest","NO"]
        app.launch()
        app.buttons["先逛逛（游客模式）"].tap()
        app.buttons["settings-menu"].tap()
        selectSection("定级与校验", in: app)
        let validate = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "独立水平校验")).firstMatch
        reveal(validate, in: app); validate.tap()
        for i in 1...24 {
            let prompt = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "独立水平校验 \(i)/24")).firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 15))
            let choices = app.buttons["quiz-option-0"]
            XCTAssertTrue(choices.waitForExistence(timeout: 15)); reveal(choices, in: app); choices.tap()
        }
        XCTAssertTrue(app.staticTexts["独立校验结果"].waitForExistence(timeout: 20))
        let back = app.buttons["返回设置"]; reveal(back,in:app);back.tap()
        XCTAssertTrue(validate.waitForExistence(timeout: 15))
    }

    func testListeningCoachAndClassicSwitch() throws {
        continueAfterFailure = false
        let app=XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765"
        app.launch()
        let guest=app.buttons["先逛逛（游客模式）"]
        if guest.waitForExistence(timeout:4) {guest.tap()}
        if app.buttons["coach-enable"].exists {app.buttons["coach-enable"].tap()}
        let bank=app.buttons["coach-bank"]
        XCTAssertTrue(bank.waitForExistence(timeout:15));capture("studio-home",app:app);bank.tap()
        XCTAssertTrue(app.staticTexts["You want to pick up the raincoat tomorrow. What should you do?"].waitForExistence(timeout:20))
        let transcript=app.buttons["coach-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout:18));XCTAssertGreaterThanOrEqual(transcript.frame.height,44);capture("studio-listen",app:app);transcript.tap(); selectSection("作答", in:app)
        if ProcessInfo.processInfo.environment["VOCAB_VERIFY_OS_APPEARANCE"]=="1" {
            let question=app.staticTexts["You want to pick up the raincoat tomorrow. What should you do?"]
            for mode in ["dark","light"] {
                print("VOCAB_REQUEST_SYSTEM_\(mode)")
                fflush(stdout)
                expectLight(mode=="light",app:app,timeout:60)
                XCTAssertTrue(question.exists)
                XCTAssertTrue(app.buttons["coach-option-0"].isEnabled)
                capture("lesson-system-\(mode)",app:app)
            }
        }
        let wrong=app.buttons.matching(NSPredicate(format:"label CONTAINS %@", "今天必须取走")).firstMatch
        XCTAssertTrue(wrong.waitForExistence(timeout:5));wrong.tap()
        XCTAssertTrue(app.staticTexts["一起看这条线索"].waitForExistence(timeout:10));capture("studio-feedback",app:app)
        selectSection("例解",in:app)
        app.buttons.matching(NSPredicate(format:"label CONTAINS %@", "请 AI 再讲一句")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@", "课程题解 ·")).firstMatch.waitForExistence(timeout:12))
        selectSection("反馈",in:app)
        app.buttons["coach-next"].tap()
        selectSection("作答",in:app)
        XCTAssertTrue(app.staticTexts["今天是唯一可取的日子吗？"].waitForExistence(timeout:8))
        app.buttons["coach-pause"].tap()
        app.buttons["home-section-3"].tap(); app.buttons["切回经典界面"].tap()
        XCTAssertTrue(app.buttons["coach-enable"].waitForExistence(timeout:5));app.buttons["coach-enable"].tap()
        app.buttons["coach-start"].tap(); selectSection("作答",in:app)
        XCTAssertTrue(app.staticTexts["今天是唯一可取的日子吗？"].waitForExistence(timeout:15))
        app.buttons["coach-option-0"].tap()
        XCTAssertTrue(app.buttons["coach-next"].waitForExistence(timeout:10));app.buttons["coach-next"].tap()
        selectSection("作答", in: app)
        app.buttons["coach-option-0"].tap()
        XCTAssertTrue(app.buttons["coach-next"].waitForExistence(timeout:10));app.buttons["coach-next"].tap()
        XCTAssertTrue(transcript.waitForExistence(timeout:8));transcript.tap(); selectSection("作答",in:app)
        app.buttons["coach-option-0"].tap()
        XCTAssertTrue(app.buttons["coach-next"].waitForExistence(timeout:10));app.buttons["coach-next"].tap()
        XCTAssertTrue(app.staticTexts["今日教练课完成"].waitForExistence(timeout:8))
    }

    func testAppearancePreference() throws {
        continueAfterFailure = false
        let app=XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765"
        app.launch()
        let guest=app.buttons["先逛逛（游客模式）"]
        if guest.waitForExistence(timeout:3) {guest.tap()}
        func settings() {
            let button=app.buttons["settings-menu"]
            XCTAssertTrue(button.waitForExistence(timeout:10))
            button.tap(); selectSection("外观与声音", in: app)
        }
        settings()
        let picker=app.segmentedControls["appearance-picker"]
        picker.buttons["跟随系统"].tap()
        let ambient=lightBackground(app)
        picker.buttons["浅色"].tap();expectLight(true,app:app)
        capture("appearance-light-settings",app:app)
        picker.buttons["深色"].tap();expectLight(false,app:app)
        capture("appearance-dark-settings",app:app)
        app.terminate();app.launch();settings()
        XCTAssertTrue(picker.buttons["深色"].isSelected);expectLight(false,app:app)
        picker.buttons[ambient ? "深色":"浅色"].tap();expectLight(!ambient,app:app)
        picker.buttons["跟随系统"].tap();expectLight(ambient,app:app)
        XCTAssertTrue(picker.buttons["跟随系统"].isSelected)
        app.buttons["返回"].tap()
    }

    func testLargeTextNavigation() throws {
        let app=XCUIApplication()
        app.launchArguments=["-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityL"]
        app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765"
        app.launch()
        let guest=app.buttons["先逛逛（游客模式）"]
        if guest.waitForExistence(timeout:3){guest.tap()}
        let settings=app.buttons["settings-menu"];XCTAssertTrue(settings.waitForExistence(timeout:12));settings.tap()
        let back=app.buttons["返回"];XCTAssertTrue(back.waitForExistence(timeout:6));XCTAssertGreaterThanOrEqual(back.frame.height,44)
        capture("large-settings",app:app);back.tap()
        app.buttons["stats-menu"].tap();XCTAssertTrue(back.waitForExistence(timeout:6));capture("large-stats",app:app);back.tap()
        XCTAssertTrue(settings.waitForExistence(timeout:6))
    }

    func testCoachAdvisoryTimeInClassic() throws {
        let app=XCUIApplication()
        app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765"
        app.launch()
        let guest=app.buttons["先逛逛（游客模式）"]
        if guest.waitForExistence(timeout:3) {guest.tap()}
        func setBoundary(_ n:Int) throws {
            var request=URLRequest(url:URL(string:"http://127.0.0.1:18765/__fixture/clock/\(n)")!)
            request.httpMethod="POST"
            let ready=expectation(description:"seed isolated clock")
            URLSession.shared.dataTask(with:request){_,r,_ in
                XCTAssertEqual((r as? HTTPURLResponse)?.statusCode,200);ready.fulfill()
            }.resume()
            wait(for:[ready],timeout:8)
        }
        func setDelay(_ n:Int) throws {
            var request=URLRequest(url:URL(string:"http://127.0.0.1:18765/__fixture/clock-delay/\(n)")!)
            request.httpMethod="POST"
            let ready=expectation(description:"isolated slow clock")
            URLSession.shared.dataTask(with:request){_,r,_ in
                XCTAssertEqual((r as? HTTPURLResponse)?.statusCode,200);ready.fulfill()
            }.resume()
            wait(for:[ready],timeout:8)
        }
        try setDelay(8)
        defer {try? setDelay(0)}
        if app.buttons["home-section-3"].exists { app.buttons["home-section-3"].tap() }
        if app.buttons["切回经典界面"].exists {app.buttons["切回经典界面"].tap()}
        let start=app.buttons["开始定级"]
        XCTAssertTrue(start.waitForExistence(timeout:8))
        start.tap()
        let clock=app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@", "用时仅作参考")).firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout:5))
        try setBoundary(3600)
        XCTAssertFalse(app.buttons["再练最多 10 分钟"].exists)
        XCTAssertFalse(app.staticTexts["正在核对今日练习时间…"].exists)
        let choice=app.buttons["不认识"]
        XCTAssertTrue(choice.waitForExistence(timeout:5));onScreen(choice,app:app);choice.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@", "今日已练 60")).firstMatch.waitForExistence(timeout:25))
        XCTAssertTrue(choice.waitForExistence(timeout:6));onScreen(choice,app:app)
        try setBoundary(0)
    }

    func testGuestPlacementAndFirstStudy() throws {
        continueAfterFailure = false
        let app = vocabularyApp()
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
        let app = vocabularyApp()
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
        selectSection("登录管理", in: app)
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
        let app = vocabularyApp()
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
        let credentialWarning = credentialWarningVisible(app)
        app.terminate(); app.launch()
        if !start.waitForExistence(timeout: 8) {
            // Unsigned simulator builds may have no Keychain entitlement. The app must
            // warn before restart, and re-login must recover the original local work.
            if !credentialWarning { print("SHARED-PLAN-RESTART",app.debugDescription);capture("shared-plan-restart-state",app:app) }
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

    @MainActor func testAutomaticSyncAfterNavigationAndOutage() async throws {
        continueAfterFailure=false
        let control="/api/v1/__ui_fixture/auto-sync"
        let seed=try await fixtureRequest("/api/v1/__ui_fixture/recovery-case",method:"POST")
        let token=try XCTUnwrap(seed["token"] as? String)
        let app=vocabularyApp()
        app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765"
        let username=try XCTUnwrap(seed["username"] as? String),password=try XCTUnwrap(seed["password"] as? String)
        _ = try await fixtureRequest(control,method:"POST",body:[:])
        func launchAccount(){
            app.launch()
            // The isolated unsigned simulator bundle can lack a Keychain access group.
            // Only sign in again on its welcome screen; both paths must use the same verified slot.
            if app.buttons["登录"].waitForExistence(timeout:3) && !app.buttons["account-menu"].exists {
                app.buttons["登录"].tap()
                let user=app.textFields["auth-username"],pass=app.secureTextFields["auth-password"]
                XCTAssertTrue(user.waitForExistence(timeout:15));user.tap();user.typeText(username)
                pass.tap();pass.typeText(password);app.buttons["登录"].tap()
            }
        }
        launchAccount()
        let account=app.buttons["account-menu"]
        let count=app.descendants(matching:.any)["learned-count"]
        let banner=app.buttons["sync-status"]
        func expectCount(_ n:Int) {
            let check=expectation(for:NSPredicate(format:"label BEGINSWITH %@",String(n)),evaluatedWith:count)
            wait(for:[check],timeout:35)
        }
        XCTAssertTrue(account.waitForExistence(timeout:30));expectCount(1)
        app.terminate()
        try await addRemoteCard("banana",token:token)
        _ = try await fixtureRequest(control,method:"POST",body:["hold":true])
        defer {Task {_ = try? await self.fixtureRequest(control,method:"POST",body:["release":true])}}
        launchAccount();XCTAssertTrue(account.waitForExistence(timeout:20))
        var held=false
        for _ in 0..<50 {
            if try await fixtureRequest(control)["held"] as? Bool==true {held=true;break}
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertTrue(held);XCTAssertFalse(banner.exists);account.tap()
        _ = try await fixtureRequest(control,method:"POST",body:["release":true])
        let status=app.staticTexts["account-sync-message"]
        let synced=expectation(for:NSPredicate(format:"label == %@","✓ 已同步"),evaluatedWith:status)
        await fulfillment(of:[synced],timeout:35)
        app.buttons["返回学习"].tap();expectCount(2);XCTAssertFalse(banner.exists)
        app.terminate();try await addRemoteCard("cherry",token:token)
        _ = try await fixtureRequest(control,method:"POST",body:["failures":2])
        launchAccount();XCTAssertTrue(account.waitForExistence(timeout:20));XCTAssertFalse(banner.exists)
        expectCount(3);XCTAssertFalse(banner.exists)
        let attempts=try await fixtureRequest(control);XCTAssertEqual(attempts["injected"] as? Int,2)
        // A genuine restore/generation conflict must stay visible, with no retry loop.
        app.terminate()
        _ = try await fixtureRequest(control,method:"POST",body:["conflict":true])
        defer { Task {_ = try? await self.fixtureRequest(control,method:"POST",body:[:])} }
        launchAccount();XCTAssertTrue(banner.waitForExistence(timeout:25));expectCount(3)
        let reads=try await fixtureRequest(control)["reads"] as? Int
        try await Task.sleep(for:.seconds(3))
        let after=try await fixtureRequest(control)["reads"] as? Int
        XCTAssertEqual(after,reads)
    }

    @MainActor func testPrunedIncrementalReadFallsBack() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = vocabularyApp()
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
        let app = vocabularyApp()
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
        let app = vocabularyApp()
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
        selectSection("云端备份", in: app)
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
        let app = vocabularyApp()
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
        let conflict = app.buttons["sync-status"]
        XCTAssertTrue(conflict.waitForExistence(timeout: 20))
        XCTAssertTrue(restartedLearned.label.contains("1"), "database rotation must keep the trusted local state")
        conflict.tap()
        XCTAssertTrue(app.staticTexts["account-sync-message"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["✓ 已同步"].exists)
    }

    @MainActor func testFileBackupAndRestore() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = vocabularyApp()
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
        selectSection("导出与恢复", in: app)
        let export = app.buttons["导出本机学习进度"]
        reveal(export, in: app)
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
        selectSection("云端备份", in: app)
        app.buttons["重新加载服务器进度"].tap()
        let dialog = app.alerts["重新加载服务器进度？"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 20)); dialog.buttons["重新加载"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "服务器进度已加载")).firstMatch.waitForExistence(timeout: 20))
        app.buttons["返回学习"].tap()
        settings.tap()
        selectSection("导出与恢复", in: app)
        let open = app.buttons["选择备份文件恢复"]
        reveal(open, in: app)
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
        let app = vocabularyApp()
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
        selectSection("登录管理", in: app)
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
        let app = vocabularyApp()
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
        selectSection("定级与校验", in: app)
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
        let app = vocabularyApp()
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
        selectSection("登录管理", in: app)
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
        let app = vocabularyApp()
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
        selectSection("登录管理", in: app)
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
        let app = vocabularyApp()
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
        selectSection("登录管理", in: app)
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
        // Keep the fresh automatic read parked so a stale manual response cannot mask a navigation-fence regression.
        let retryGate="/api/v1/__ui_fixture/auto-sync"
        _ = try await fixtureRequest(retryGate,method:"POST",body:["hold":true])
        defer {Task {_ = try? await self.fixtureRequest(retryGate,method:"POST",body:["release":true])}}
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
        _ = try await fixtureRequest(retryGate,method:"POST",body:["release":true])
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "3"), object: learned)
        await fulfillment(of: [refreshed], timeout: 20)
    }

    @MainActor func testBackupWarnsMissingScheduler() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/backup-missing-scheduler", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String), password = try XCTUnwrap(seed["password"] as? String)
        let app = vocabularyApp()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let settings = app.buttons["settings-menu"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30)); settings.tap()
        selectSection("导出与恢复", in: app)
        let export = app.buttons["导出本机学习进度"]
        reveal(export, in: app)
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
        reveal(warning, in: app)
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
        let app = vocabularyApp()
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
        let app=vocabularyApp();app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765";app.launch()
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
        selectSection("同步维护", in: app)
        let recoveryExport=app.buttons["导出大状态恢复记录"]
        reveal(recoveryExport, in: app)
        XCTAssertTrue(recoveryExport.waitForExistence(timeout:20)); recoveryExport.tap()
        let message=app.staticTexts["large-restore-export-message"]
        XCTAssertTrue(message.waitForExistence(timeout:20)); XCTAssertEqual(message.label,"当前没有可导出的大状态恢复记录。")
        selectSection("同步维护", in: app)
        let resume=app.buttons["继续未完成的恢复或整理"]
        reveal(resume, in: app)
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
        let app=vocabularyApp();app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765";app.launch()
        let settings=app.buttons["settings-menu"],user=app.textFields["auth-username"],pass=app.secureTextFields["auth-password"]
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30));app.buttons["登录"].tap()
        XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout:20));pass.tap();pass.typeText(password);app.buttons["登录"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout:90));settings.tap()
        selectSection("同步维护", in: app)
        let checkpoint=app.buttons["整理已同步的历史"]
        reveal(checkpoint, in: app)
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
        selectSection("同步维护", in: app)
        let resume=app.buttons["继续未完成的恢复或整理"]
        reveal(resume, in: app)
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
        let app=vocabularyApp();app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765";app.launch()
        let settings=app.buttons["settings-menu"],user=app.textFields["auth-username"],pass=app.secureTextFields["auth-password"]
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30));app.buttons["登录"].tap()
        XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout:20));pass.tap();pass.typeText(password);app.buttons["登录"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout:90));settings.tap()
        selectSection("同步维护", in: app)
        let checkpoint=app.buttons["整理已同步的历史"]
        reveal(checkpoint, in: app)
        XCTAssertTrue(checkpoint.waitForExistence(timeout:30));checkpoint.tap()
        let confirm=app.alerts["整理已同步的历史？"];XCTAssertTrue(confirm.waitForExistence(timeout:30))
        _ = try await fixtureRequest("/api/v1/__ui_fixture/checkpoint-write-failure",method:"POST",body:["enabled":true])
        confirm.buttons["整理"].tap()
        let failed=app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@", "injected checkpoint failure")).firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout:120),"checkpoint failure was not visible")
        _ = try await fixtureRequest("/api/v1/__ui_fixture/checkpoint-write-failure",method:"POST",body:["enabled":false])
        _ = try await fixtureRequest("/api/v1/__ui_fixture/delta-hold-response",method:"POST")
        selectSection("同步维护", in: app)
        let cancel=app.buttons["取消未提交的历史整理"]
        reveal(cancel, in: app)
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
        reveal(cancel, in: app)
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
        let app=vocabularyApp();app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765";app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30));app.buttons["登录"].tap()
        let user=app.textFields["auth-username"],pass=app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout:20));pass.tap();pass.typeText(password);app.buttons["登录"].tap()
        let settings=app.buttons["settings-menu"];XCTAssertTrue(settings.waitForExistence(timeout:90));settings.tap()
        selectSection("导出与恢复", in: app)
        let export=app.buttons["导出本机学习进度"]
        reveal(export, in: app)
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
        selectSection("每日计划", in: app)
        let fifteen=app.buttons["setting-new-15"],twenty=app.buttons["setting-new-20"]
        reveal(fifteen, in: app)
        XCTAssertTrue(fifteen.waitForExistence(timeout:20));XCTAssertTrue(twenty.exists)
        if fifteen.value as? String == "已选择" { twenty.tap() } else { fifteen.tap() }
        app.buttons["返回"].tap();app.buttons["account-menu"].tap()
        let sync=app.buttons["立即同步"];XCTAssertTrue(sync.waitForExistence(timeout:20));sync.tap()
        XCTAssertTrue(app.staticTexts["✓ 已同步"].waitForExistence(timeout:120))
        app.buttons["返回学习"].tap();settings.tap()
        selectSection("导出与恢复", in: app)
        let open=app.buttons["选择备份文件恢复"]
        reveal(open, in: app)
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
            selectSection("同步维护", in: app)
            let cancelButton=app.buttons["取消未提交的备份恢复"]
            reveal(cancelButton, in: app)
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
            reveal(cancelButton, in: app)
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
            selectSection("同步维护", in: app)
            let resume=app.buttons["继续未完成的恢复或整理"]
            reveal(resume, in: app)
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
        let app=vocabularyApp();app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765";app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30));app.buttons["登录"].tap()
        let user=app.textFields["auth-username"],pass=app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout:20));pass.tap();pass.typeText(password);app.buttons["登录"].tap()
        let settings=app.buttons["settings-menu"]
        XCTAssertTrue(settings.waitForExistence(timeout:90));settings.tap()
        selectSection("同步维护", in: app)
        let resume=app.buttons["继续未完成的恢复或整理"]
        reveal(resume, in: app)
        XCTAssertTrue(resume.waitForExistence(timeout:20));resume.tap()
        let message=app.staticTexts["large-restore-export-message"]
        let completed=NSPredicate(format:"label CONTAINS %@", "恢复完成")
        await fulfillment(of:[XCTNSPredicateExpectation(predicate:completed,object:message)],timeout:180)
    }

    @MainActor func testExperimentalLargeRestoreLocalConflict() async throws {
        continueAfterFailure=false
        let seed=try await fixtureRequest("/api/v1/__ui_fixture/staged-ui-case")
        let username=try XCTUnwrap(seed["username"] as? String),password=try XCTUnwrap(seed["password"] as? String)
        let app=vocabularyApp();app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765";app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30));app.buttons["登录"].tap()
        let user=app.textFields["auth-username"],pass=app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout:20));pass.tap();pass.typeText(password);app.buttons["登录"].tap()
        let settings=app.buttons["settings-menu"];XCTAssertTrue(settings.waitForExistence(timeout:90));settings.tap()
        selectSection("每日计划", in: app)
        let fifteen=app.buttons["setting-new-15"],twenty=app.buttons["setting-new-20"]
        XCTAssertTrue(fifteen.waitForExistence(timeout:20));XCTAssertTrue(twenty.exists)
        if fifteen.value as? String == "已选择" { twenty.tap() } else { fifteen.tap() }
        selectSection("同步维护", in: app)
        let resume=app.buttons["继续未完成的恢复或整理"]
        reveal(resume, in: app)
        XCTAssertTrue(resume.waitForExistence(timeout:20));resume.tap()
        let message=app.staticTexts["large-restore-export-message"]
        let blocked=NSPredicate(format:"label CONTAINS %@", "本机进度已变化")
        await fulfillment(of:[XCTNSPredicateExpectation(predicate:blocked,object:message)],timeout:180)
    }

    @MainActor func testExperimentalLargeReplayAfterProcessTermination() async throws {
        continueAfterFailure = false
        let seed=try await fixtureRequest("/api/v1/__ui_fixture/staged-ui-case")
        let username=try XCTUnwrap(seed["username"] as? String), password=try XCTUnwrap(seed["password"] as? String), token=try XCTUnwrap(seed["token"] as? String)
        let app=vocabularyApp();app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765"
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
        let app = vocabularyApp()
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
        let app = vocabularyApp()
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
        let app = vocabularyApp()
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
        selectSection("登录管理", in: app)
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
        let app = vocabularyApp()
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
        let app = vocabularyApp()
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
        let app = vocabularyApp()
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
        selectSection("登录管理", in: app)
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

    @MainActor func testQueueRejectsChangedDailyProgress() async throws {
        continueAfterFailure = false
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX")
        formatter.calendar = Calendar(identifier:.gregorian); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from:Date())
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/queue-budget-case", method:"POST", body:["day":day])
        let username = try XCTUnwrap(seed["username"] as? String), password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = vocabularyApp(); app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"; app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout:20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout:20)); pass.tap(); pass.typeText(password); app.buttons["登录"].tap()
        let start = app.buttons["start-today"]
        XCTAssertTrue(start.waitForExistence(timeout:30)); start.tap()
        var attempts = 0
        for _ in 0..<100 {
            attempts = try await fixtureRequest("/api/v1/__ui_fixture/queue-status")["attempts"] as? Int ?? 0
            if attempts > 0 { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertGreaterThan(attempts, 0)
        XCUIDevice.shared.press(.home)
        let pulled = try await fixtureRequest("/api/v1/me/state", token:token)
        var state = try XCTUnwrap(pulled["state"] as? [String:Any])
        var log = state["log"] as? [[String:Any]] ?? []
        log.append(["d":day,"word":"other-device","kind":"review","rating":3,"eventId":UUID().uuidString.lowercased()])
        state["log"] = log
        _ = try await fixtureRequest("/api/v1/me/state",method:"PUT",token:token,body:state)
        app.activate()
        XCTAssertTrue(app.descendants(matching:.any)["预计今日进度，已完成 3，共 3 词"].waitForExistence(timeout:30), app.debugDescription)
        _ = try await fixtureRequest("/api/v1/__ui_fixture/queue-release",method:"POST")
        let retry = app.buttons["重新加载"]
        XCTAssertTrue(retry.waitForExistence(timeout:30), "stale queue opened a session")
        retry.tap()
        XCTAssertTrue(app.staticTexts["今日已达上限"].waitForExistence(timeout:30))
        XCTAssertFalse(app.buttons["学会了 →"].exists)
    }

    @MainActor func testLearningMaintenanceControls() async throws {
        continueAfterFailure=false
        let format=DateFormatter();format.dateFormat="yyyy-MM-dd"
        let seed=try await fixtureRequest("/api/v1/__ui_fixture/same-day-relearning-case",method:"POST",body:["day":format.string(from:Date())])
        let app=vocabularyApp();app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765";app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30));app.buttons["登录"].tap()
        let user=app.textFields["auth-username"],pass=app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(seed["username"] as! String)
        pass.tap();pass.typeText(seed["password"] as! String);app.buttons["登录"].tap()
        XCTAssertTrue(app.buttons["settings-menu"].waitForExistence(timeout:30));app.buttons["settings-menu"].tap()
        selectSection("离线与数据维护", in: app)
        let library=app.buttons["下载／更新整库离线包"]
        reveal(library, in: app)
        XCTAssertTrue(library.isHittable);library.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","词已校验保存")).firstMatch.waitForExistence(timeout:120))
        let repair=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","检查并修复异常卡")).firstMatch
        reveal(repair, in: app)
        XCTAssertTrue(repair.isHittable);repair.tap()
        XCTAssertTrue(app.staticTexts["没有需要修复的异常卡。"].waitForExistence(timeout:10))
        let localPractice=app.buttons["本机生成薄弱词例句"]
        reveal(localPractice, in: app)
        XCTAssertTrue(localPractice.isHittable);localPractice.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@ OR label CONTAINS %@","本机中英双语模型尚不可用","没有需要生成例句")).firstMatch.waitForExistence(timeout:20))
        let health=app.buttons["实际学习效果与存档健康"]
        reveal(health, in: app)
        XCTAssertTrue(health.exists);health.tap()
        XCTAssertTrue(app.staticTexts["以下为服务器已同步数据。"].waitForExistence(timeout:20))
    }

    @MainActor func testCorePolicyGuessAndTimedContinuation() async throws {
        continueAfterFailure = false
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/same-day-relearning-case", method:"POST", body:["day":format.string(from:Date()),"short_steps":true])
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = vocabularyApp(); app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        func login() {
            XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30));app.buttons["登录"].tap()
            let user=app.textFields["auth-username"], pass=app.secureTextFields["auth-password"]
            XCTAssertTrue(user.waitForExistence(timeout:20));user.tap();user.typeText(seed["username"] as! String)
            pass.tap();pass.typeText(seed["password"] as! String);app.buttons["登录"].tap()
        }
        login()
        XCTAssertTrue(app.buttons["start-today"].waitForExistence(timeout:30));app.buttons["start-today"].tap()
        XCTAssertTrue(app.buttons["quiz-option-0"].waitForExistence(timeout:30));app.buttons["quiz-option-0"].tap()
        let guess=app.buttons["猜对了／其实没记住"]
        XCTAssertTrue(guess.waitForExistence(timeout:20));guess.tap()
        XCTAssertTrue(app.staticTexts["本轮学习完成 🎉"].waitForExistence(timeout:20))
        let more=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","继续今日任务")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout:25),"due-time refresh never enabled continuation")
        var state: [String:Any] = [:]
        for _ in 0..<80 {
            state=(try await fixtureRequest("/api/v1/me/state",token:token))["state"] as? [String:Any] ?? [:]
            let card=(state["cards"] as? [String:[String:Any]])?["apple"] ?? [:]
            if ((card["studyEvidence"] as? [String:Any])?["events"] as? [String:Any])?.count == 1 { break }
            try await Task.sleep(for:.milliseconds(200))
        }
        let card=try XCTUnwrap((state["cards"] as? [String:[String:Any]])?["apple"])
        let evidence=try XCTUnwrap((card["studyEvidence"] as? [String:Any])?["events"] as? [String:[String:Any]])
        let entry=try XCTUnwrap(evidence.first)
        XCTAssertEqual(entry.value["rating"] as? Int,1)
        XCTAssertEqual(entry.value["guessed"] as? Bool,true)
        let logs=try XCTUnwrap(state["log"] as? [[String:Any]])
        XCTAssertTrue(logs.contains { ($0["eventId"] as? String)==entry.key })
        XCTAssertEqual(Set(logs.map { $0["word"] as! String }).count,1)
        app.terminate();app.launch()
        if !app.buttons["start-today"].waitForExistence(timeout:8) { login() }
        XCTAssertTrue(app.buttons["start-today"].waitForExistence(timeout:30));app.buttons["start-today"].tap()
        XCTAssertTrue(app.buttons["quiz-option-0"].waitForExistence(timeout:30));app.buttons["quiz-option-0"].tap()
        XCTAssertTrue(app.buttons["记得"].waitForExistence(timeout:20));app.buttons["记得"].tap()
        XCTAssertTrue(app.staticTexts["本轮学习完成 🎉"].waitForExistence(timeout:20))
    }

    @MainActor func testSameDayRelearningAtDailyCapacity() async throws {
        try await checkSameDayRelearning(offline: false)
    }

    @MainActor func testOfflineRelearningAtDailyCapacity() async throws {
        try await checkSameDayRelearning(offline: true)
    }

    @MainActor private func checkSameDayRelearning(offline: Bool) async throws {
        continueAfterFailure = false
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX")
        formatter.calendar = Calendar(identifier:.gregorian); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/same-day-relearning-case", method:"POST", body:["day":formatter.string(from:Date()), "offline":offline])
        let username = try XCTUnwrap(seed["username"] as? String), password = try XCTUnwrap(seed["password"] as? String)
        let app = vocabularyApp(); app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"; app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout:20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout:20)); pass.tap(); pass.typeText(password); app.buttons["登录"].tap()
        XCTAssertTrue(app.buttons["start-today"].waitForExistence(timeout:30), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["预计今日进度，已完成 1，共 1 词"].exists, app.debugDescription)
        app.buttons["start-today"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@", "复习 1/1")).firstMatch.waitForExistence(timeout:30))
        XCTAssertTrue(app.staticTexts["apple"].exists, "due relearning must remain available after the distinct-word cap is reached")
        if offline {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@", "临时安排")).firstMatch.exists)
            let status = try await fixtureRequest("/api/v1/__ui_fixture/fsrs-status")
            XCTAssertGreaterThan(status["failures"] as? Int ?? 0, 0)
        }
    }

    @MainActor func testSharedProbeCountsEvidenceOnce() async throws {
        continueAfterFailure = false
        let format = DateFormatter(); format.locale = Locale(identifier:"en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/shared-probe-case",method:"POST",
            body:["day":format.string(from:Date()),"offset_minutes":TimeZone.current.secondsFromGMT()/60])
        let username = try XCTUnwrap(seed["username"] as? String), password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = vocabularyApp(); app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"; app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout:20)); user.tap(); user.typeText(username)
        pass.tap(); pass.typeText(password); app.buttons["登录"].tap()
        XCTAssertTrue(app.buttons["start-today"].waitForExistence(timeout:30)); app.buttons["start-today"].tap()
        XCTAssertTrue(app.staticTexts["apple"].waitForExistence(timeout:30))
        XCTAssertTrue(app.buttons["quiz-option-0"].waitForExistence(timeout:20))
        _ = try await fixtureRequest("/api/v1/__ui_fixture/shared-probe-other-answer",method:"POST")
        app.buttons["quiz-option-0"].tap()
        var state: [String:Any] = [:]
        for _ in 0..<300 {
            state = (try await fixtureRequest("/api/v1/me/state",token:token))["state"] as? [String:Any] ?? [:]
            if (state["log"] as? [[String:Any]] ?? []).filter({ ($0["kind"] as? String)=="probe" }).count == 2 { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        let logs = try XCTUnwrap(state["log"] as? [[String:Any]])
        XCTAssertEqual(logs.filter { ($0["kind"] as? String)=="probe" }.count,2)
        XCTAssertEqual(state["probeCount"] as? Int,1)
        let history = try XCTUnwrap(state["posteriorHistory"] as? [String:Any])
        let events = try XCTUnwrap(history["events"] as? [String:Any])
        XCTAssertEqual(events.count,2); XCTAssertTrue(events.keys.allSatisfy { $0.hasPrefix("p1_") })
    }

    @MainActor func testSharedDailyPlanSurvivesRestart() async throws {
        continueAfterFailure = false
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"
        let day = format.string(from: Date())
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/shared-plan-case", method: "POST",
            body: ["day":day,"offset_minutes":TimeZone.current.secondsFromGMT()/60])
        let username = try XCTUnwrap(seed["username"] as? String), password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = vocabularyApp(); app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:30)); app.buttons["登录"].tap()
        let user=app.textFields["auth-username"], pass=app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout:20)); user.tap(); user.typeText(username)
        pass.tap(); pass.typeText(password); app.buttons["登录"].tap()
        XCTAssertTrue(app.buttons["start-today"].waitForExistence(timeout:30)); app.buttons["start-today"].tap()
        XCTAssertTrue(app.staticTexts["cat"].waitForExistence(timeout:30), "use the other device's reserved final word, not the local dog candidate")
        XCTAssertFalse(app.staticTexts["dog"].exists)
        XCTAssertTrue(app.buttons["退出"].waitForExistence(timeout:10)); app.buttons["退出"].tap()
        _ = try await fixtureRequest("/api/v1/__ui_fixture/study-plan-offline", method:"POST", body:["enabled":true])
        let credentialWarning = credentialWarningVisible(app)
        app.terminate(); app.launch()
        if !app.buttons["start-today"].waitForExistence(timeout:8) {
            if !credentialWarning { print("SHARED-PLAN-RESTART",app.debugDescription);capture("shared-plan-restart-state",app:app) }
            XCTAssertTrue(credentialWarning, "session vanished without a credential warning")
            XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout:15)); app.buttons["登录"].tap()
            XCTAssertTrue(user.waitForExistence(timeout:15)); user.tap(); user.typeText(username)
            pass.tap(); pass.typeText(password); app.buttons["登录"].tap()
        }
        XCTAssertTrue(app.buttons["start-today"].waitForExistence(timeout:30)); app.buttons["start-today"].tap()
        XCTAssertTrue(app.staticTexts["cat"].waitForExistence(timeout:30), "persisted reservations survive a process restart and allocation service outage")
        XCTAssertTrue(app.buttons["学会了 →"].waitForExistence(timeout:20)); app.buttons["学会了 →"].tap()
        let acceptance = app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","验收测试 1/1")).firstMatch
        XCTAssertTrue(acceptance.waitForExistence(timeout:30)); XCTAssertTrue(app.buttons["quiz-option-0"].waitForExistence(timeout:20))
        app.buttons["quiz-option-0"].tap()
        var state: [String:Any] = [:]
        for _ in 0..<100 {
            state = (try await fixtureRequest("/api/v1/me/state",token:token))["state"] as? [String:Any] ?? [:]
            if (state["quizCompleted"] as? [String] ?? []).contains("cat") { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        let logs = try XCTUnwrap(state["log"] as? [[String:Any]])
        let todayLogs = logs.filter { ($0["d"] as? String)==day && ["learn","review","probe"].contains($0["kind"] as? String ?? "") }
        XCTAssertEqual(Set(todayLogs.compactMap { $0["word"] as? String }).count,100)
        XCTAssertEqual(todayLogs.filter { ($0["kind"] as? String)=="learn" }.count,1)
        let cards = try XCTUnwrap(state["cards"] as? [String:[String:Any]])
        XCTAssertNil(cards["dog"]); let cat = try XCTUnwrap(cards["cat"])
        let pending = try XCTUnwrap(cat["pendingFsrs"] as? [String:Any])
        XCTAssertEqual((pending["events"] as? [Any])?.count,2,"learning and acceptance must survive FSRS unavailability")
        _ = try await fixtureRequest("/api/v1/__ui_fixture/study-plan-offline", method:"POST", body:["enabled":false])
    }

    @MainActor func testMasteredWordsExcludedAndNewTargetReserved() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/mastery-budget-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = vocabularyApp()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let plannedNew = app.descendants(matching: .any)["daily-new-planned"]
        XCTAssertTrue(plannedNew.waitForExistence(timeout: 30)); XCTAssertTrue(plannedNew.label.contains("2"))
        XCTAssertTrue(app.staticTexts["另有 2 个词已到期，超出今日上限，暂未安排。"].exists)
        app.buttons["start-today"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "复习 1/3")).firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["book"].exists, "a mastered card must not be queued")
        let option = app.buttons["quiz-option-0"]
        XCTAssertTrue(option.waitForExistence(timeout: 20))
        for i in 0..<4 {XCTAssertTrue(onScreen(app.buttons["quiz-option-\(i)"],app:app))}
        let last=app.buttons["quiz-option-3"]
        XCTAssertGreaterThan(last.frame.maxY,app.frame.height-100)
        XCTAssertFalse(app.buttons["page-next"].exists)
        capture("thumb-review-options",app:app)
        option.tap()
        let remember = app.buttons["记得"]
        XCTAssertTrue(remember.waitForExistence(timeout: 20))
        let example=app.staticTexts["study-example"]
        XCTAssertTrue(example.waitForExistence(timeout:20));XCTAssertTrue(onScreen(example,app:app))
        XCTAssertTrue(onScreen(app.staticTexts["study-meaning"],app:app));XCTAssertTrue(onScreen(remember,app:app))
        XCTAssertFalse(app.buttons["page-next"].exists);capture("thumb-answer-with-example",app:app)
        remember.tap()
        XCTAssertTrue(app.staticTexts["dog"].waitForExistence(timeout: 30), "the first reserved new word must be present")
        XCTAssertTrue(app.buttons["学会了 →"].waitForExistence(timeout:30))
        XCTAssertTrue(example.waitForExistence(timeout:20));XCTAssertTrue(onScreen(example,app:app))
        XCTAssertTrue(onScreen(app.staticTexts["study-meaning"],app:app));XCTAssertTrue(onScreen(app.buttons["study-more"],app:app))
        XCTAssertFalse(app.buttons["page-next"].exists);capture("thumb-new-word-with-example",app:app)
        app.buttons["学会了 →"].tap()
        XCTAssertTrue(app.staticTexts["cat"].waitForExistence(timeout:30), "a skipped-range random word replaced the reserved new word")
        var reviewGuess: Double?
        for _ in 0..<100 {
            let response = try await fixtureRequest("/api/v1/me/state",token:token)
            let state = response["state"] as? [String:Any], history = state?["posteriorHistory"] as? [String:Any]
            let events = history?["events"] as? [String:[String:Any]] ?? [:]
            reviewGuess = events.values.first(where:{ ($0["weight"] as? Double) == 0.15 })?["guess"] as? Double
            if reviewGuess != nil { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertEqual(reviewGuess, 0.25, "mature four-choice answers still have a guessing component")
        app.buttons["学会了 →"].tap()
        for index in 1...2 {
            let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "验收测试 \(index)/2")).firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 30))
            XCTAssertTrue(app.buttons["quiz-option-0"].waitForExistence(timeout: 20))
            app.buttons["quiz-option-0"].tap()
        }
        var finalState: [String:Any] = [:]
        for _ in 0..<100 {
            finalState = (try await fixtureRequest("/api/v1/me/state",token:token))["state"] as? [String:Any] ?? [:]
            if Set(finalState["quizCompleted"] as? [String] ?? []) == Set(["dog","cat"]) { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertEqual(Set(finalState["quizCompleted"] as? [String] ?? []), Set(["dog","cat"]))
        let finalHistory = finalState["posteriorHistory"] as? [String:Any]
        let updates = (finalHistory?["events"] as? [String:[String:Any]] ?? [:]).values.filter { ($0["kind"] as? String) == "update" }
        XCTAssertEqual(updates.count, 1, "two taught words and immediate acceptance must not add general-level evidence")
        let finalLogs = (finalState["log"] as? [[String:Any]] ?? []).filter { ["learn","review"].contains($0["kind"] as? String ?? "") }
        XCTAssertEqual(finalLogs.count, 5, "review, two learned words and two acceptance grades must all survive")
        XCTAssertTrue(finalLogs.allSatisfy { ($0["ts"] as? String) != nil })
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
        let app = vocabularyApp()
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
        let todayReviewed = app.descendants(matching: .any)["session-reviewed"]
        XCTAssertTrue(todayReviewed.waitForExistence(timeout: 10))
        XCTAssertTrue(todayReviewed.label.contains("3"), "completion screen must show the daily cumulative count")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "继续今日任务")).firstMatch.exists)
        let adjust = app.buttons["adjust-daily-cap"]
        XCTAssertTrue(adjust.waitForExistence(timeout: 10)); adjust.tap()
        let largerCap = app.buttons["setting-cap-200"]
        XCTAssertTrue(largerCap.waitForExistence(timeout: 20)); largerCap.tap()
        XCTAssertEqual(largerCap.value as? String, "已选择")
        XCTAssertTrue(app.buttons["返回"].waitForExistence(timeout: 10)); app.buttons["返回"].tap()
        app.buttons["start-today"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "复习")).firstMatch.waitForExistence(timeout: 30))
        app.buttons["退出"].tap()
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
        let app = vocabularyApp()
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
        let app = vocabularyApp(); app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"; app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let stats = app.buttons["stats-menu"]; XCTAssertTrue(stats.waitForExistence(timeout: 30)); stats.tap()
        selectSection("复习预测", in: app)
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
        let app = vocabularyApp(); app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"; app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        let stats = app.buttons["stats-menu"]; XCTAssertTrue(stats.waitForExistence(timeout: 30)); stats.tap()
        selectSection("保持率", in: app)
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
        let app = vocabularyApp()
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
        selectSection("导出与恢复", in: app)
        let check = app.buttons["检查并恢复旧存档 1"]
        reveal(check, in: app)
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
        let app = vocabularyApp()
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
        selectSection("登录管理", in: app)
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

    @MainActor func testStaticSentenceSwapFailureKeepsSentence() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/static-swap-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let app = vocabularyApp()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        XCTAssertTrue(app.buttons["start-today"].waitForExistence(timeout: 30)); app.buttons["start-today"].tap()
        XCTAssertTrue(app.buttons["quiz-option-0"].waitForExistence(timeout: 30)); app.buttons["quiz-option-0"].tap()
        selectSection("例句", in: app)
        let sentence = app.staticTexts["An apple is here."]
        XCTAssertTrue(sentence.waitForExistence(timeout: 30))
        app.buttons["study-more"].tap()
        let swap = app.buttons.matching(identifier: "swap-static-apple").firstMatch
        XCTAssertTrue(swap.waitForExistence(timeout: 10)); swap.tap()
        XCTAssertTrue(app.staticTexts["暂时无法换句，原例句仍可使用。"].waitForExistence(timeout: 20))
        XCTAssertTrue(sentence.exists, "the original sentence should remain visible on failure")
        _ = try await fixtureRequest("/api/v1/__ui_fixture/static-swap-online", method: "POST")
        app.buttons["study-more"].tap();swap.tap()
        XCTAssertTrue(app.staticTexts["A different apple sentence."].waitForExistence(timeout: 20))
        XCTAssertFalse(sentence.exists, "an available alternative should replace the original")
    }

    @MainActor func testPersonalSentenceRejection() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/personal-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let initial = try await fixtureRequest("/api/v1/me/state", token: token)
        let stale = try XCTUnwrap(initial["state"] as? [String: Any])
        let app = vocabularyApp()
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
        selectSection("例句", in: app)
        let sentence = app.staticTexts["An old sentence."]
        XCTAssertTrue(sentence.waitForExistence(timeout: 30))
        app.buttons["study-more"].tap()
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

    @MainActor func testPlacementCeilingDoesNotRepeat() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/placement-ceiling-case",method:"POST")
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = vocabularyApp()
        app.launchEnvironment["VOCAB_UI_TEST_API"]="http://127.0.0.1:18765"
        func enter() {
            app.launch()
            if app.buttons["登录"].waitForExistence(timeout:3) {
                app.buttons["登录"].tap()
                let user=app.textFields["auth-username"],pass=app.secureTextFields["auth-password"]
                user.tap();user.typeText(seed["username"] as! String)
                pass.tap();pass.typeText(seed["password"] as! String);app.buttons["登录"].tap()
            }
            XCTAssertTrue(app.buttons["继续定级"].waitForExistence(timeout:20));app.buttons["继续定级"].tap()
        }
        enter();var words=Set(["facilitator"])
        for i in 13...30 {
            let progress=app.staticTexts["placement-progress"]
            expectation(for:NSPredicate(format:"label CONTAINS %@","第 \(i)/30"),evaluatedWith:progress)
            waitForExpectations(timeout:20)
            let word=app.staticTexts["placement-word"]
            XCTAssertTrue(word.waitForExistence(timeout:20));XCTAssertTrue(words.insert(word.label).inserted,"repeated \(word.label)")
            for j in 0..<4 {XCTAssertTrue(onScreen(app.buttons["quiz-option-\(j)"],app:app))}
            if i==13 {capture("placement-ceiling-unseen-word",app:app)}
            app.buttons["quiz-option-0"].tap()
            if i==18 {
                expectation(for:NSPredicate(format:"label CONTAINS %@","第 19/30"),evaluatedWith:progress);waitForExpectations(timeout:20)
                app.buttons["退出"].tap();app.terminate();enter()
            }
        }
        XCTAssertTrue(app.staticTexts["定级完成"].waitForExistence(timeout:20))
        XCTAssertTrue(app.staticTexts["recognition-range"].exists)
        capture("placement-ceiling-finished",app:app)
        var state:[String:Any]=[:]
        for _ in 0..<100 {
            state=(try await fixtureRequest("/api/v1/me/state",token:token))["state"] as? [String:Any] ?? [:]
            if state["calibrated"] as? Bool == true {break}
            try await Task.sleep(for:.milliseconds(200))
        }
        XCTAssertEqual(state["probeCount"] as? Int,30)
        let bands=state["bandEvidence"] as? [String:[String:Any]] ?? [:]
        let events=bands.values.flatMap {($0["events"] as? [String:[String:Any]] ?? [:]).values}
        XCTAssertEqual(events.count,30);XCTAssertEqual(Set(events.compactMap {$0["pos"] as? Int}).count,30)
        XCTAssertNotNil((state["cards"] as? [String:Any])?["apple"],"placement must preserve learned cards")
    }

    @MainActor func testReplacementPlacementResume() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = vocabularyApp()
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
        selectSection("定级与校验", in: app)
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
        let range=app.staticTexts["recognition-range"]
        XCTAssertTrue(range.waitForExistence(timeout:10));XCTAssertTrue(range.label.hasPrefix("0～"))
        XCTAssertTrue(onScreen(finish,app:app))
        capture("recognition-range-after-resume",app:app)
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
        let recognition=state["recognitionEvidence"] as? [String:[String:Any]] ?? [:]
        XCTAssertEqual(recognition.count,30)
        XCTAssertEqual(Set(recognition.values.compactMap{$0["pos"] as? Int}).count,30)
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
        let app = vocabularyApp()
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
        let app = vocabularyApp()
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
        let app = vocabularyApp()
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
        selectSection("同步维护", in: app)
        let checkpoint = app.buttons["整理已同步的历史"]
        reveal(checkpoint, in: app)
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
        let app = vocabularyApp()
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
        selectSection("云端备份", in: app)
        let reload = app.buttons["重新加载服务器进度"]
        XCTAssertTrue(reload.waitForExistence(timeout: 20)); reload.tap()
        var attempts = 0
        for _ in 0..<50 {
            attempts = try await fixtureRequest("/api/v1/__ui_fixture/state-get-status")["attempts"] as? Int ?? 0
            if attempts > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(attempts, 0)
        selectSection("登录管理", in: app)
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
        let app = vocabularyApp()
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
        selectSection("云端备份", in: app)
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
        let app = vocabularyApp()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        XCTAssertTrue(app.buttons["settings-menu"].waitForExistence(timeout: 30)); app.buttons["settings-menu"].tap()
        selectSection("复习提醒", in: app)
        let toggle = app.switches["setting-reminder-enabled"]
        reveal(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 20)); toggle.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "不允许"])).firstMatch
        XCTAssertTrue(deny.waitForExistence(timeout: 20), "Notification permission prompt did not appear")
        deny.tap()
        let warning = app.staticTexts["系统通知权限未开启，请在系统设置中允许词航发送通知。"]
        XCTAssertTrue(warning.waitForExistence(timeout: 20), "Denied notification permission was not reported")
    }

    @MainActor func testSyncedReminderAppliesImmediately() async throws {
        continueAfterFailure = false
        let seed = try await fixtureRequest("/api/v1/__ui_fixture/recovery-case", method: "POST")
        let username = try XCTUnwrap(seed["username"] as? String)
        let password = try XCTUnwrap(seed["password"] as? String)
        let token = try XCTUnwrap(seed["token"] as? String)
        let app = vocabularyApp()
        app.launchEnvironment["VOCAB_UI_TEST_API"] = "http://127.0.0.1:18765"
        app.launch()
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 30)); app.buttons["登录"].tap()
        let user = app.textFields["auth-username"], pass = app.secureTextFields["auth-password"]
        XCTAssertTrue(user.waitForExistence(timeout: 20)); user.tap(); user.typeText(username)
        XCTAssertTrue(pass.waitForExistence(timeout: 20)); pass.tap(); pass.typeText(password)
        app.buttons["登录"].tap()
        XCTAssertTrue(app.buttons["account-menu"].waitForExistence(timeout: 30))
        let response = try await fixtureRequest("/api/v1/me/state", token: token)
        var state = try XCTUnwrap(response["state"] as? [String: Any])
        var settings = try XCTUnwrap(state["settings"] as? [String: Any])
        settings["notifyEnabled"] = true; settings["notifyHour"] = 20; state["settings"] = settings
        _ = try await fixtureRequest("/api/v1/me/state", method: "PUT", token: token, body: state)
        app.buttons["account-menu"].tap()
        XCTAssertTrue(app.buttons["立即同步"].waitForExistence(timeout: 20)); app.buttons["立即同步"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "不允许"])).firstMatch
        XCTAssertTrue(deny.waitForExistence(timeout: 30), "Synced reminder did not request notification permission")
        deny.tap()
        XCTAssertTrue(app.buttons["返回学习"].waitForExistence(timeout: 20)); app.buttons["返回学习"].tap()
        XCTAssertTrue(app.buttons["settings-menu"].waitForExistence(timeout: 20)); app.buttons["settings-menu"].tap()
        let warning = app.staticTexts["系统通知权限未开启，请在系统设置中允许词航发送通知。"]
        reveal(warning, in: app)
        XCTAssertTrue(warning.waitForExistence(timeout: 20), "Synced setting or denied-permission warning is missing")
    }
}
