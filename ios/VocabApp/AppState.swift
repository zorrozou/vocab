import Foundation
import SwiftUI

/// 会话内瞬态（不持久化）：今日队列与进度
struct Session {
    enum Item: Equatable {
        case review(word: String)
        case learn(word: NewWord)
    }
    var queue: [Item] = []
    var idx = 0
    var learnedToday = 0
    var reviewedToday = 0
    /// 当日验收测试进度（学完新词后的 4 选 1）
    var acceptanceIdx: Int?
}

struct Auth: Equatable {
    let userId: Int
    let username: String
    let nickname: String
    let token: String
}

enum Route: Equatable {
    case welcome
    case auth(login: Bool)
    case home
    case placement
    case session
    case stats
    case settings
    case userMenu
}

@MainActor
@Observable
final class AppState {
    var S = LearningState()
    var auth: Auth?
    var route: Route = .welcome
    var session = Session()
    var placementSet: PlacementSet?
    var booted = false
    var syncMsg = ""

    let audio = AudioService()
    let speech = SpeechService()
    private let api = APIClient.shared
    private var pushTask: Task<Void, Never>?

    var isGuest: Bool { auth == nil }

    // MARK: 本地持久化（Documents 目录，按账号分槽位）

    private var slotKey: String {
        auth.map { "u\($0.userId)" } ?? "guest"
    }

    private func stateURL(for slot: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Config.stateFilePrefix)_\(slot).json")
    }

    private func userURL(for slot: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Config.stateFilePrefix)_\(slot).user")
    }

    private func saveLocal() {
        guard let data = try? JSONEncoder().encode(S) else { return }
        try? data.write(to: stateURL(for: slotKey), options: .atomic)
        // 槽位署名：服务端删号后 uid 会被复用，凭署名防止旧槽位错配给同名新账号
        try? (auth?.username ?? "guest").write(to: userURL(for: slotKey), atomically: true, encoding: .utf8)
    }

    private func loadLocal(slot: String, forUsername: String? = nil) -> LearningState? {
        // 有主槽位（非游客）：必须有署名且用户名一致才认
        // （uid 复用/旧版本无署名槽位一律不信任——反正服务器存档优先，损失为零）
        if let u = forUsername, slot != "guest" {
            guard let sidecar = try? String(contentsOf: userURL(for: slot), encoding: .utf8),
                  sidecar == u else {
                return nil
            }
        }
        guard let data = try? Data(contentsOf: stateURL(for: slot)),
              let s = try? JSONDecoder().decode(LearningState.self, from: data) else { return nil }
        return s
    }

    /// 保存 = 本地立即 + 登录后防抖 2s 推服务器（与 web 一致）
    func save() {
        saveLocal()
        guard auth != nil else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            try? await self.api.pushState(self.S)
        }
    }

    func pushNow() async {
        guard auth != nil else { return }
        pushTask?.cancel()
        do {
            try await api.pushState(S)
            syncMsg = "✓ 已同步"
        } catch {
            syncMsg = "同步失败，稍后再试"
        }
    }

    // MARK: 设备 ID（个性化例句分桶，与 web 规则一致）

    func deviceId() -> String {
        if let auth { return "u\(auth.userId)" }
        let key = "vocab_device"
        if let d = UserDefaults.standard.string(forKey: key) { return d }
        let d = "ios-" + UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(d, forKey: key)
        return d
    }

    // MARK: 启动与认证

    func boot() async {
        guard !booted else { return }
        booted = true
        if let a = restoreAuth() {
            auth = a
            await api.setToken(a.token)
            // 服务器状态优先；拉不到用本地槽位
            if let remote = try? await api.pullState().state {
                S = remote
            } else if let local = loadLocal(slot: slotKey, forUsername: a.username) {
                S = local
            }
            saveLocal()
            route = .home
        } else if UserDefaults.standard.bool(forKey: "vocab_guest") {
            S = loadLocal(slot: "guest") ?? LearningState()
            route = .home
        } else {
            route = .welcome
        }
    }

    private func restoreAuth() -> Auth? {
        guard let token = Keychain.load("token"),
              let d = UserDefaults.standard.data(forKey: "vocab_profile"),
              let p = try? JSONDecoder().decode(AuthUser.self, from: d) else { return nil }
        return Auth(userId: p.id, username: p.username, nickname: p.nickname, token: token)
    }

    func enterGuest() {
        UserDefaults.standard.set(true, forKey: "vocab_guest")
        S = loadLocal(slot: "guest") ?? LearningState()
        route = .home
    }

    /// 登录/注册成功后的状态装载
    /// - 服务器有存档 → 服务器为准
    /// - 否则有本机槽位 → 用槽位并推上服务器
    /// - 注册新账号：绝不并入当前内存进度（新账号 = 全新开始 + 定级）
    /// - 登录老账号且两端都空 → 才把当前（游客）进度并入
    func authed(_ r: AuthResponse, isRegistration: Bool = false) async {
        // 归档当前进度——但空状态不归档（切换/登出后 S 已被重置，
        // 此时归档会把游客等旧槽位覆盖成空白，造成进度丢失）
        if !S.cards.isEmpty || S.probeCount > 0 || !S.log.isEmpty {
            saveLocal()
        }
        let a = Auth(userId: r.user.id, username: r.user.username,
                     nickname: r.user.nickname, token: r.token)
        auth = a
        await api.setToken(a.token)
        Keychain.save(a.token, for: "token")
        if let d = try? JSONEncoder().encode(r.user) {
            UserDefaults.standard.set(d, forKey: "vocab_profile")
        }
        UserDefaults.standard.set(false, forKey: "vocab_guest")
        if let remote = try? await api.pullState().state {
            S = remote
        } else if let local = loadLocal(slot: slotKey, forUsername: r.user.username) {
            S = local
            try? await api.pushState(S)
        } else if !isRegistration && !S.cards.isEmpty {
            try? await api.pushState(S)   // 游客进度并入老账号
        } else {
            S = LearningState()           // 新账号全新开始
        }
        saveLocal()
        route = .home
    }

    func switchAccount() {
        saveLocal()
        auth = nil
        Task { await api.setToken(nil) }
        Keychain.delete("token")
        UserDefaults.standard.removeObject(forKey: "vocab_profile")
        S = LearningState()
        route = .welcome
    }

    func logout() async {
        await pushNow()
        await api.logout()
        switchAccount()
        if let g = loadLocal(slot: "guest") {
            S = g
            UserDefaults.standard.set(true, forKey: "vocab_guest")
            route = .home
        }
    }

    // MARK: 学习/复习评分写卡（FSRS 服务端 + 阶梯兜底）

    func learn(word: String, pos: Int, rating: Int) async {
        let today = DayUtil.today()
        var c = S.cards[word] ?? CardState(stage: 1, due: DayUtil.addDays(today, 1) + "T12:00:00Z",
                                           lt: 0, pos: pos, fsrs: nil)
        let isNewCard = S.cards[word] == nil
        let body = StudyEngine.fsrsBody(for: S.cards[word], rating: rating, isNewCard: isNewCard)
        if let r = try? await api.fsrsReview(body) {
            StudyEngine.applyFsrs(r, to: &c, today: today)
        } else {
            StudyEngine.ladderFallback(&c, rating: rating, today: today)
        }
        S.cards[word] = c
        S.log.append(LogEntry(d: today, word: word, rating: rating, kind: "learn"))
    }

    func review(word: String, rating: Int) async {
        guard var c = S.cards[word] else { return }
        let today = DayUtil.today()
        S.log.append(LogEntry(d: today, word: word, rating: rating, kind: "review"))
        let body = StudyEngine.fsrsBody(for: c, rating: rating, isNewCard: false)
        if let r = try? await api.fsrsReview(body) {
            StudyEngine.applyFsrs(r, to: &c, today: today)
            if rating == 1 { c.lt = 0 }
        } else {
            StudyEngine.ladderFallback(&c, rating: rating, today: today)
        }
        S.cards[word] = c
    }

    // MARK: 每日队列（到期复习 + 提前巩固概率池 + 新词）

    func buildQueue() async {
        let now = Date()
        let cap = S.settings.dailyCap

        let due = S.cards
            .filter { !StudyEngine.isMastered($0.value) && (DayUtil.parseISO($0.value.due) ?? .distantFuture) <= now }
            .sorted { (DayUtil.parseISO($0.value.due) ?? .distantFuture) < (DayUtil.parseISO($1.value.due) ?? .distantFuture) }
            .map { $0.key }
        let reviews = Array(due.prefix(cap))

        // 提前巩固位：1~7 天前碰过、FSRS 未到期、未掌握，P=(1−R)×0.5，≤5 个
        let reviewSet = Set(reviews)
        let earlyPool = S.cards.filter { pair in
            let (w, c) = pair
            guard !StudyEngine.isMastered(c), let dueD = DayUtil.parseISO(c.due), dueD > now else { return false }
            guard let last = S.log.reversed().first(where: { $0.word == w }) else { return false }
            guard let lastD = DayUtil.parseISO(last.d + "T12:00:00Z") else { return false }
            let elapsed = now.timeIntervalSince(lastD) / 86400
            guard elapsed >= 1, elapsed <= 7 else { return false }
            let r = StudyEngine.retrievability(c, elapsedDays: elapsed)
            return Double.random(in: 0..<1) < (1 - r) * 0.5
        }.map { $0.key }
        let early = earlyPool.filter { !reviewSet.contains($0) }
            .prefix(min(5, max(0, cap - reviews.count)))
        let reviewsAll = reviews + early

        // 新词：pendingNew 优先，然后按 pointer 顺序取
        let nNew = min(S.settings.newPerDay, max(0, cap - reviewsAll.count))
        var news: [NewWord] = []
        var rest = S.pendingNew
        while news.count < nNew, !rest.isEmpty { news.append(rest.removeFirst()) }
        S.pendingNew = rest
        if news.count < nNew {
            let want = nNew - news.count + 2
            if let r = try? await api.lexiconAt(pos: S.pointer, n: want) {
                for w in r.words {
                    if news.count >= nNew { break }
                    if S.cards[w.word] == nil && !news.contains(where: { $0.word == w.word }) {
                        news.append(w)
                    }
                }
            }
        }

        session = Session()
        session.queue = reviewsAll.map { .review(word: $0) } + news.map { .learn(word: $0) }
        if let lastPos = news.last?.pos { S.pointer = lastPos + 1 }
        save()
        prefetchDay(news: news, reviewWords: reviewsAll)
    }

    /// 队列确定后立即后台预生成三句套装 + TTS 预热（不等翻卡）
    private func prefetchDay(news: [NewWord], reviewWords: [String]) {
        let weak = StudyEngine.recentWeakWords(S, today: DayUtil.today()).prefix(15).joined(separator: ",")
        let api = self.api
        let cap = S.pointer + 10
        let voice = S.settings.voice
        Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: (String, TrioResponse?).self) { group in
                for w in news {
                    group.addTask {
                        let r = try? await api.trio(word: w.word, weak: weak, cap: cap)
                        return (w.word, r)
                    }
                }
                var texts: [String] = reviewWords.prefix(15).map { $0 }
                for await (word, r) in group {
                    if let sents = r?.sentences, !sents.isEmpty {
                        if let i = self.session.queue.firstIndex(where: {
                            if case .learn(let nw) = $0 { return nw.word == word } else { return false }
                        }), case .learn(var nw) = self.session.queue[i] {
                            nw.sentences = sents
                            self.session.queue[i] = .learn(word: nw)
                        }
                        texts.append(word)
                        texts.append(contentsOf: sents.map { $0.text })
                    }
                }
                await api.warmTTS(Array(texts.prefix(80)), voice: voice)
            }
        }
    }

    // MARK: 当日完成与自动个性化

    func markDayDone() {
        let today = DayUtil.today()
        if S.lastDay != today {
            S.streak = S.lastDay == DayUtil.addDays(today, -1) ? S.streak + 1 : 1
            S.lastDay = today
        }
        // 注意：不在这里设 quizDay——只有验收测试真正跑完才能标记（与 web 一致），
        // 否则同一天二次学习的新词会永远错过验收。
        save()
    }

    /// 今日到期（含日内 FSRS steps 稍后到期）统计
    func dueNowCount() -> Int {
        let now = Date()
        return S.cards.values.filter {
            !StudyEngine.isMastered($0) && (DayUtil.parseISO($0.due) ?? .distantFuture) <= now
        }.count
    }

    func dueLaterTodayCount() -> Int {
        let now = Date()
        let eod = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
        return S.cards.values.filter {
            guard !StudyEngine.isMastered($0), let d = DayUtil.parseISO($0.due), d > now else { return false }
            return d < eod
        }.count
    }

    /// 为今日薄弱词定制例句（完成学习自动触发，后台异步生成 + 轮询取回）
    func autoPersonalize(onStatus: @escaping (String) -> Void,
                         onRows: (([PersonalizedOut.Row]) -> Void)? = nil) async {
        let date = DayUtil.today()
        let weakToday = StudyEngine.recentWeakWords(S, today: date)
            .filter { w in S.log.contains(where: { $0.d == date && $0.word == w && $0.rating <= 2 }) }
        let weakKey = weakToday.sorted().joined(separator: ",")
        if S.personalizedDay == date && S.personalizedWeak == weakKey {
            onStatus("✓ 今天的薄弱词例句已就绪")
            // 重进完成页时把已生成的例句一并回显（否则列表会丢）
            let rows = weakToday.compactMap { w -> PersonalizedOut.Row? in
                guard let p = S.personalized[w] else { return nil }
                return PersonalizedOut.Row(target: w, recall: p.recall, text: p.text, zh: p.zh)
            }
            if !rows.isEmpty { onRows?(rows) }
            return
        }
        guard !weakToday.isEmpty else {
            S.personalizedDay = date; S.personalizedWeak = ""; save()
            onStatus("今天没有薄弱词，全部掌握得很好 👍 无需定制")
            return
        }
        onStatus("正在为今天的 \(weakToday.count) 个薄弱词定制复习例句…")
        do {
            _ = try await api.personalize(.init(device: deviceId(), date: date,
                                                weak_words: Array(weakToday.prefix(15)),
                                                learned_max_pos: S.pointer + 10,
                                                sync: true, replace: true))
        } catch {
            onStatus("生成暂不可用，明天用静态例句（不影响学习）")
            return
        }
        // 慢速模型异步生成：轮询取结果
        var rows: [PersonalizedOut.Row] = []
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if let p = try? await api.personalized(device: deviceId(), date: date), !p.sentences.isEmpty {
                rows = p.sentences
                break
            }
        }
        if rows.isEmpty {
            S.personalizedDay = date; S.personalizedWeak = weakKey; save()
            onStatus("✓ 已提交生成任务（\(weakToday.count) 个薄弱词），例句正在后台定制，明天复习时自动就绪")
            return
        }
        for r in rows {
            S.personalized[r.target] = PersonalizedSentence(text: r.text, recall: r.recall, zh: r.zh ?? "")
        }
        S.personalizedDay = date
        S.personalizedWeak = weakKey
        save()
        await api.warmTTS(rows.map { $0.text }, voice: S.settings.voice)
        onStatus("✓ 已为今天 \(weakToday.count) 个薄弱词定制 \(rows.count) 条复习例句（明天复习时优先显示）")
        onRows?(rows)
    }

    // MARK: 织入巩固句（新词卡 40% 概率、每天 ≤3 次）

    func maybeWeave(for word: String) async -> (text: String, zh: String?, weak: String)? {
        let today = DayUtil.today()
        if S.weaveDay != today { S.weaveDay = today; S.weaveCount = 0 }
        let pool = StudyEngine.recentWeakWords(S, today: today)
            .filter { $0 != word }
        guard !pool.isEmpty, S.weaveCount < 3, Double.random(in: 0..<1) < 0.4 else { return nil }
        let weakW = pool.randomElement()!
        S.weaveCount += 1
        save()
        guard let r = try? await api.weave(word: word, weak: weakW, cap: S.pointer + 10,
                                           device: deviceId()),
              !r.text.isEmpty else { return nil }
        await api.warmTTS([r.text], voice: S.settings.voice)
        return (r.text, r.zh, weakW)
    }

    // MARK: ↻ 换一句

    func swapSentence(word: String, oldText: String, kind: String) async -> SentenceItem? {
        do {
            if kind == "static" {
                try await api.report(word: word, text: oldText, device: deviceId())
                _ = try? await api.trio(word: word, weak: "", cap: S.pointer + 10)
                let pos = S.cards[word]?.pos ?? S.pointer
                let r = try await api.lexiconAt(pos: pos, n: 20)
                if let wd = r.words.first(where: { $0.word == word }),
                   let fresh = (wd.sentences ?? []).first(where: { $0.text != oldText }) {
                    return fresh
                }
                return nil
            } else {
                S.personalized[word] = nil
                save()
                _ = try await api.personalize(.init(device: deviceId(), date: DayUtil.today(),
                                                    weak_words: [word],
                                                    learned_max_pos: S.pointer + 10,
                                                    sync: true, replace: false))
                for _ in 0..<8 {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if let p = try? await api.personalized(device: deviceId(), date: DayUtil.today()),
                       let s = p.sentences.first(where: { $0.target == word && $0.text != oldText }) {
                        let item = PersonalizedSentence(text: s.text, recall: s.recall, zh: s.zh ?? "")
                        S.personalized[word] = item
                        save()
                        return SentenceItem(tier: nil, text: s.text, zh: s.zh)
                    }
                }
                return nil
            }
        } catch {
            return nil
        }
    }
}
