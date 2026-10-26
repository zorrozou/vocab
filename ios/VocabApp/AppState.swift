import OSLog
import SwiftUI

/// 会话内瞬态（不持久化）：今日队列与进度
struct Session {
    enum Item: Equatable {
        case review(word: String)
        case learn(word: NewWord)
        case probe(word: NewWord)   // v1.3 水平探测题（4选1，无卡片负担）
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
    var syncFailed = false   // 上次推送服务器失败（顶栏显示 ⚠️）

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
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "vocab_write_\(slotKey)")
        // 槽位署名：服务端删号后 uid 会被复用，凭署名防止旧槽位错配给同名新账号
        try? (auth?.username ?? "guest").write(to: userURL(for: slotKey), atomically: true, encoding: .utf8)
    }

    /// 回到前台：服务器存档比本机新就拉取（学习会话中不打扰）
    func pullIfNewer() async {
        guard auth != nil, route != .session else { return }
        guard let remote = try? await api.pullState(), let rs = remote.state else { return }
        let localTs = UserDefaults.standard.double(forKey: "vocab_write_\(slotKey)")
        if (remote.updated_at ?? 0) > localTs + 1 {
            S = rs
            saveLocal()
        }
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
        // 状态瘦身：日志只留最近 1200 条（薄弱词窗口 7 天/顽固词统计不受影响；
        // 不瘦身的话状态会超过 nginx 64KB 限制导致推送静默 413——本次同步分歧的真凶）
        if S.log.count > 1200 { S.log.removeFirst(S.log.count - 1200) }
        saveLocal()
        guard auth != nil else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            do {
                try await self.api.pushState(self.S)
                self.syncFailed = false
            } catch {
                self.syncFailed = true   // 推送失败对用户可见（不再静默）
            }
        }
    }

    func pushNow() async {
        guard auth != nil else { return }
        pushTask?.cancel()
        do {
            try await api.pushState(S)
            syncMsg = "✓ 已同步"
            syncFailed = false
        } catch {
            syncMsg = "同步失败，稍后再试"
            syncFailed = true
        }
    }

    // MARK: 设备 ID（个性化例句分桶，与 web 规则一致）

    private var undoSnapshot: (word: String, card: CardState, logCount: Int)?

    /// 撤销最近一次「忘记」评分（手滑误点）：恢复卡片 FSRS 状态、删除日志、回到出题环节
    func undoReview() {
        guard let snap = undoSnapshot else { return }
        S.cards[snap.word] = snap.card
        if S.log.count > snap.logCount {
            S.log.removeLast(S.log.count - snap.logCount)
        }
        undoSnapshot = nil
        if session.reviewedToday > 0 { session.reviewedToday -= 1 }
        save()
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
            // 谁新听谁的（不再服务器无条件覆盖）：
            // 上次学习若在防抖推送前退出/断网，本机比服务器新——这时以本机为准并立刻补推，
            // 否则学过的词会被旧档抹掉、第二天当新词重发（用户实测踩到两次）
            let local = loadLocal(slot: slotKey, forUsername: a.username)
            let localTs = UserDefaults.standard.double(forKey: "vocab_write_\(slotKey)")
            if let remote = try? await api.pullState() {
                if let rs = remote.state {
                    if let local, localTs > (remote.updated_at ?? 0) + 2 {
                        S = local
                        try? await api.pushState(S)   // 本机更新 → 补推上服务器
                    } else {
                        S = rs
                    }
                } else if let local {
                    S = local
                    try? await api.pushState(S)
                }
            } else if let local {
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
        placementSet = nil   // 进游客也清空定级题缓存（与账号隔离）
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
        placementSet = nil   // 换账号必须重抽定级题（否则新用户会做到上一个用户的卷子）
        let a = Auth(userId: r.user.id, username: r.user.username,
                     nickname: r.user.nickname, token: r.token)
        auth = a
        await api.setToken(a.token)
        Keychain.save(a.token, for: "token")
        if let d = try? JSONEncoder().encode(r.user) {
            UserDefaults.standard.set(d, forKey: "vocab_profile")
        }
        UserDefaults.standard.set(false, forKey: "vocab_guest")
        // 服务器为准 → 但本机槽位比服务器新（有未推送的学习）则以本机为准并补推
        if let remote = try? await api.pullState(), let rs = remote.state {
            let local = loadLocal(slot: slotKey, forUsername: r.user.username)
            let localTs = UserDefaults.standard.double(forKey: "vocab_write_\(slotKey)")
            if let local, localTs > (remote.updated_at ?? 0) + 2 {
                S = local
                try? await api.pushState(S)
            } else {
                S = rs
            }
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

    /// 重新定级：重置探测状态并重抽题库（30 题新随机卷）。
    /// 已学卡片、FSRS 调度、连续天数全部保留；完成后 frontier/pointer 跳到新边界。
    func startReplacement() {
        S.posterior = nil
        S.probeCount = 0
        S.wrongStreak = 0
        S.track = nil          // 追踪状态一并刷新（先验更换）
        placementSet = nil
        save()
        route = .placement
    }

    func switchAccount() {
        saveLocal()
        auth = nil
        Task { await api.setToken(nil) }
        Keychain.delete("token")
        UserDefaults.standard.removeObject(forKey: "vocab_profile")
        placementSet = nil   // 切账号清空定级题缓存
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

    /// 该词上一次学习/复习日期（从日志推导，含历史老卡），用于 FSRS 计算真实经过天数
    private func lastReviewDate(_ word: String) -> String? {
        S.log.last { $0.word == word && ($0.kind == "learn" || $0.kind == "review") }?.d
    }

    func learn(word: String, pos: Int, rating: Int) async {
        let today = DayUtil.today()
        let lastReview = lastReviewDate(word)
        var c = S.cards[word] ?? CardState(stage: 1, due: DayUtil.addDays(today, 1) + "T12:00:00Z",
                                           lt: 0, pos: pos, fsrs: nil)
        let isNewCard = S.cards[word] == nil
        let body = StudyEngine.fsrsBody(for: S.cards[word], rating: rating, isNewCard: isNewCard, lastReview: lastReview)
        if let r = try? await api.fsrsReview(body) {
            StudyEngine.applyFsrs(r, to: &c, today: today)
        } else {
            StudyEngine.ladderFallback(&c, rating: rating, today: today)
        }
        S.cards[word] = c
        S.log.append(LogEntry(d: today, word: word, rating: rating, kind: "learn"))
        // 水平追踪观测（v1.2）：不熟悉=强证据(resp 0, w1.0)；学会了=自评弱证据(resp 1, w0.5)
        observeLevel(pos: pos, known: rating != 1, weight: rating == 1 ? 1.0 : 0.5)
    }

    /// 水平观测（v1.2）：每次反馈都是对词汇量后验的一次带权观测
    func observeLevel(pos: Int, known: Bool, weight: Double) {
        guard S.calibrated else { return }
        StudyEngine.posteriorUpdate(&S, rank: pos, resp: known ? 1 : 0, weight: weight)
    }

    func review(word: String, rating: Int, trackWeight: Double? = nil) async {
        guard var c = S.cards[word] else { return }
        let preStab = c.fsrs?.stability ?? Double(c.stage.flatMap { StudyEngine.ladderInterval[$0] } ?? 0)   // v1.3：成熟度用答前稳定度
        let lastReview = lastReviewDate(word)   // 在写今日日志前取上一次记录
        let today = DayUtil.today()
        // 答错前快照（撤销用）：防止手滑误记「忘记」无法挽回
        if rating == 1 {
            undoSnapshot = (word: word, card: c, logCount: S.log.count)
        } else {
            undoSnapshot = nil
        }
        S.log.append(LogEntry(d: today, word: word, rating: rating, kind: "review"))
        let body = StudyEngine.fsrsBody(for: c, rating: rating, isNewCard: false, lastReview: lastReview)
        if let r = try? await api.fsrsReview(body) {
            StudyEngine.applyFsrs(r, to: &c, today: today)
            if rating == 1 { c.lt = 0 }
        } else {
            StudyEngine.ladderFallback(&c, rating: rating, today: today)
        }
        // 熟词毕业（用户反馈驱动）：连按两次「熟练」，或按「熟练」时稳定度已≥30天
        // → 直接跨过已掌握阈值（稳定度≥180），永不再出现在队列中。「记得/困难」照常走 FSRS。
        if rating == 4 {
            c.easyStreak = (c.easyStreak ?? 0) + 1
            let stab = c.fsrs?.stability ?? 0
            if (c.easyStreak ?? 0) >= 2 || stab >= 30 {
                c.fsrs?.stability = max(stab, 200)
            }
        } else if rating == 1 {
            c.easyStreak = 0
        }
        S.cards[word] = c
        // 水平追踪观测（v1.3 权重修正，治"只升不降"）：
        //  - 忘记：曾通过的成熟卡（答前稳定度≥21天）是有力向下证据 w0.4；新卡遗忘 w0.2
        //  - 记得/困难/熟练：只有词排位高于当前估值才算向上证据（低于估值的成功无信息量），w0.15
        //  - 被动证据每日总权重封顶 1.5；验收测试（trackWeight 1.0）不受上限
        if let pos = S.cards[word]?.pos, S.calibrated {
            if let tw = trackWeight {
                observeLevel(pos: pos, known: rating != 1, weight: tw)
            } else {
                var tr = S.track ?? TrackState()
                if tr.dayWDay != today { tr.dayW = 0; tr.dayWDay = today }
                var w = 0.0
                var known = true
                if rating == 1 { w = preStab >= 21 ? 0.4 : 0.2; known = false }
                else if Double(pos) > StudyEngine.postMean(S) { w = 0.15 }
                if w > 0 && (tr.dayW ?? 0) + w <= 1.5 {
                    observeLevel(pos: pos, known: known, weight: w)
                    tr.dayW = (tr.dayW ?? 0) + w
                    S.track = tr
                }
            }
        }
    }

    /// 每天首次 buildQueue 时运行：T=后验均值。
    /// T 超前 pointer >500 且证据够硬(std<800) → pointer 跳到 T（中间词视为已会）；
    /// pointer 超前 T >500 且连续 2 天 → 减压（新词 5 个/天，不后退——已发词 FSRS 在管）。
    /// v1.3：评估前先做置信度扩散（每日一次）；级别变更须连续 3 天跨边界（滞回防抖）
    func trackLevelDaily() {
        guard S.calibrated, S.posterior != nil else { return }
        let today = DayUtil.today()
        if S.track?.evalDay == today { return }   // 每日最多一次
        var track = S.track ?? TrackState()
        if track.diffuseDay != today {
            StudyEngine.diffusePosterior(&S)
            track.diffuseDay = today
        }
        let T = Int(StudyEngine.postMean(S).rounded())
        let std = StudyEngine.postStd(S)
        if Double(T - S.pointer) > 500 && std < 800 {
            track.lastNote = "连续表现超过当前级别，发词位置从 \(S.pointer) 追平到 ≈\(T)（\(levelDisplayName(levelForPos(T)))），中间词视为已会跳过"
            S.pointer = T
            track.lowSince = nil
            track.throttle = false
        } else if Double(S.pointer - T) > 500 {
            if track.lowSince == nil { track.lowSince = today }
            if track.lowSince! <= DayUtil.addDays(today, -1) && track.throttle != true {
                track.throttle = true
                track.lastNote = "近期新词偏难（水平估值 ≈\(T)，游标 \(S.pointer)），新词临时降到 5 个/天，先消化存量"
            }
        } else {
            if track.throttle == true {
                track.lastNote = "水平追上来了（≈\(T)），新词恢复 \(S.settings.newPerDay) 个/天"
            }
            track.lowSince = nil
            track.throttle = false
        }
        // v1.3 级别滞回：后验均值跨边界须连续 3 天，才正式调整展示级别（防单日抖动）
        let band = levelForPos(max(1, T))
        if track.shownLevel == nil { track.shownLevel = levelForPos(max(1, S.pointer)) }
        if band != track.shownLevel {
            if track.pendingBand == band { track.pendingDays = (track.pendingDays ?? 0) + 1 }
            else { track.pendingBand = band; track.pendingDays = 1 }
            if (track.pendingDays ?? 0) >= 3 {
                track.shownLevel = band
                track.lastNote = "词汇水平连续 3 天稳定在「\(levelDisplayName(band))」区间，当前级别已调整"
                track.pendingBand = nil
                track.pendingDays = 0
            }
        } else {
            track.pendingBand = nil
            track.pendingDays = 0
        }
        track.evalDay = today
        S.track = track
        save()
    }

    /// v1.3 主动探测选词：上方近端 / 上方远端 / 下方回归检查 各 1 个（与 web 同规则）
    private func pickProbes(reviewWords: [String], news: [NewWord]) async -> [NewWord] {
        guard S.calibrated, S.posterior != nil else { return [] }
        let today = DayUtil.today()
        // 每日总计 3 题：当天重建队列（继续复习/二次进入）不重复追加探测
        let already = S.log.filter { $0.kind == "probe" && $0.d == today }.count
        let need = 3 - already
        guard need > 0 else { return [] }
        let m = StudyEngine.postMean(S), sd = max(60, StudyEngine.postStd(S))
        let recentProbe = Set(S.log.filter { $0.kind == "probe" && $0.d >= DayUtil.addDays(today, -14) }.map(\.word))
        var busy = Set(reviewWords)
        news.forEach { busy.insert($0.word) }
        let zones: [(Double, Double)] = [
            (m + 0.5 * sd, m + 1.0 * sd),   // 上方近端：是不是已经更强了
            (m + 1.5 * sd, m + 2.0 * sd),   // 上方远端：大幅进步的信号
            (m - 1.0 * sd, m - 0.5 * sd),   // 下方：高估回归检查
        ]
        var out: [NewWord] = []
        for (lo, hi) in zones {
            if out.count >= need { break }
            let a = max(1, Int(lo.rounded())), b = min(10991, Int(hi.rounded()))
            guard a <= b else { continue }
            for _ in 0..<6 {
                let pos = Int.random(in: a...b)
                guard let r = try? await api.lexiconAt(pos: pos, n: 1),
                      let w = r.words.first,
                      S.cards[w.word] == nil,
                      !recentProbe.contains(w.word),
                      !busy.contains(w.word),
                      !out.contains(where: { $0.word == w.word }),
                      !S.pendingNew.contains(where: { $0.word == w.word }) else { continue }
                out.append(w)
                break
            }
        }
        return out
    }

    /// v1.3 探测作答：全额证据（weight 1.0，与定级同级）；答错 → 进明日新词候选
    func answerProbe(_ w: NewWord, ok: Bool) {
        StudyEngine.posteriorUpdate(&S, rank: w.pos, resp: ok ? 1 : 0, weight: 1.0)
        S.log.append(LogEntry(d: DayUtil.today(), word: w.word, rating: ok ? 4 : 1, kind: "probe"))
        if !ok, S.cards[w.word] == nil, !S.pendingNew.contains(where: { $0.word == w.word }) {
            S.pendingNew.append(NewWord(word: w.word, pos: w.pos))
        }
        save()
    }

    /// 跟读结果入档：完整度 <60 记薄弱（进薄弱词管线，当晚就定制例句），≥60 记一次影子练习
    /// 让跟读真正参与学习决策，而不是"白评了"
    func recordShadow(word: String, result: ShadowResult) {
        let rating = result.completeness < 60 ? 1 : 3
        S.log.append(LogEntry(d: DayUtil.today(), word: word, rating: rating, kind: "shadow"))
        save()
    }

    /// 顽固词特训：把 ≥2 次没记住的词单独组一队复习（不进新词，纯歼灭战）
    @discardableResult
    func startStubbornDrill() -> Int {
        var lapse: [String: Int] = [:]
        for l in S.log where l.rating <= 2 { lapse[l.word, default: 0] += 1 }
        let words = S.cards
            .filter { w, c in (lapse[w] ?? 0) >= 2 && !StudyEngine.isMastered(c) }
            .map(\.key)
            .sorted()
        guard !words.isEmpty else { return 0 }
        session = Session()
        session.queue = words.map { .review(word: $0) }
        route = .session
        return words.count
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
        // v1.2：先跑水平追踪（可能跳位/减压），新词量用减压后的有效值
        trackLevelDaily()
        let newPerDay = (S.track?.throttle == true) ? 5 : S.settings.newPerDay
        let nNew = min(newPerDay, max(0, cap - reviewsAll.count))
        var news: [NewWord] = []
        var rest = S.pendingNew
        // 防重守卫：已在卡片里的词（学过/在复习）绝不再当新词发
        while news.count < nNew, !rest.isEmpty {
            let w = rest.removeFirst()
            if S.cards[w.word] == nil && !news.contains(where: { $0.word == w.word }) {
                news.append(w)
            }
        }
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
        // pendingNew 词只有 word+pos（定级遗留），补全音标/义项/静态例句等完整词条
        for i in news.indices where news[i].senses == nil {
            if let r = try? await api.lexiconAt(pos: news[i].pos, n: 10),
               let full = r.words.first(where: { $0.word == news[i].word }) {
                news[i] = full
            }
        }
        // 跳段复核：发生过跳位（pointer 已显著领先定级边界）时，每天从跳过区间随机抽 1 个词
        // 顶替 1 个新词位——给"视为已会"的跳过词一次被抓住的机会。
        // 答对就过（确认真会），答错它会正常进卡片复习，同时水平后验自动回落纠偏。
        if nNew > 0, news.count == nNew, S.pointer - S.frontier > 200 {
            for _ in 0..<6 {   // 最多试 6 个随机位置，避开已入卡的词
                let randPos = Int.random(in: S.frontier..<S.pointer)
                guard let r = try? await api.lexiconAt(pos: randPos, n: 1),
                      let w = r.words.first,
                      S.cards[w.word] == nil,
                      !news.contains(where: { $0.word == w.word }) else { continue }
                news[news.count - 1] = w
                break
            }
        }

        // v1.3 每日主动探测：3 个探测词（2 个后验上方区 / 1 个下方区）随机混入复习段，
        // 4选1 形式与复习测验无差别——用户无感知，证据全额（与定级同级 weight 1.0）
        let probes = await pickProbes(reviewWords: reviewsAll, news: news)
        var revBlock: [Session.Item] = reviewsAll.map { .review(word: $0) }
        for w in probes {
            let at = Int.random(in: 0...revBlock.count)
            revBlock.insert(.probe(word: w), at: at)
        }

        session = Session()
        session.queue = revBlock + news.map { .learn(word: $0) }
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
        Logger.app.info("prefetchDay: \(news.count) 新词, weak=\(weak, privacy: .public)")
        Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: (String, TrioResponse?, String?).self) { group in
                for w in news {
                    group.addTask {
                        do {
                            let r = try await api.trio(word: w.word, weak: weak, cap: cap)
                            return (w.word, r, nil)
                        } catch {
                            return (w.word, nil, String(describing: error))
                        }
                    }
                }
                var texts: [String] = reviewWords.prefix(15).map { $0 }
                for await (word, r, err) in group {
                    if let err { Logger.app.error("trio 失败 \(word, privacy: .public): \(err, privacy: .public)") }
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
