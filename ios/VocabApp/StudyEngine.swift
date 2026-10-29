import Foundation

private enum FsrsReplayError: LocalizedError {
    case schedulerChanged
    var errorDescription: String? { "FSRS 参数已变化，无法安全重放旧评分，请先导出进度" }
}

/// 调度引擎：FSRS-6（服务端计算）+ 阶梯兜底 + 定级贝叶斯，全部逻辑 1:1 移植自 web/index.html
enum StudyEngine {

    /// A backup can only replay referenced scheduler versions it actually
    /// contains. Legacy events without a recorded version remain unverifiable.
    static func referencedBackupSchedulers(_ state: LearningState) -> Set<String> {
        var referenced = Set<String>()
        for card in state.cards.values {
            for key in (card.fsrsReplayVersions ?? [:]).values where !key.isEmpty { referenced.insert(key) }
            for group in [card.fsrsHistory, card.pendingFsrs].compactMap({ $0 }) {
                if let key = group.schedulerKey, !key.isEmpty { referenced.insert(key) }
                for event in group.events {
                    if let key = event.schedulerKey, !key.isEmpty { referenced.insert(key) }
                }
            }
        }
        return referenced
    }

    static func usableBackupScheduler(_ key: String, _ value: FsrsSchedulerConfig) -> Bool {
        func valid(_ values: [Double], low: Double, high: Double) -> Bool {
            values.count <= 32 && values.allSatisfy { $0.isFinite && $0 >= low && $0 <= high && !($0 == 0 && $0.sign == .minus) }
        }
        return key.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
            !value.library.isEmpty && value.library.unicodeScalars.count <= 64 &&
            valid(value.parameters, low: -1_000_000, high: 1_000_000) &&
            value.desired_retention.isFinite && value.desired_retention >= 0.01 && value.desired_retention <= 0.9999 &&
            valid(value.learning_steps, low: 0, high: 31_536_000) && valid(value.relearning_steps, low: 0, high: 31_536_000) &&
            value.maximum_interval >= 1 && value.maximum_interval <= 1_000_000
    }

    static func invalidBackupSchedulers(_ state: LearningState) -> Set<String> {
        Set((state.fsrsSchedulers ?? [:]).compactMap { usableBackupScheduler($0.key, $0.value) ? nil : $0.key })
    }

    static func missingBackupSchedulers(_ state: LearningState) -> Set<String> {
        let referenced = referencedBackupSchedulers(state), versions = state.fsrsSchedulers ?? [:]
        return Set(referenced.filter { key in
            guard let value = versions[key] else { return true }
            return !usableBackupScheduler(key, value)
        })
    }

    static func identicalBackupScheduler(_ a: FsrsSchedulerConfig, _ b: FsrsSchedulerConfig) -> Bool {
        func equal(_ x: [Double], _ y: [Double]) -> Bool {
            x.count == y.count && zip(x, y).allSatisfy { $0.0.bitPattern == $0.1.bitPattern }
        }
        return a.library == b.library && a.maximum_interval == b.maximum_interval &&
            a.desired_retention.bitPattern == b.desired_retention.bitPattern && equal(a.parameters, b.parameters) &&
            equal(a.learning_steps, b.learning_steps) && equal(a.relearning_steps, b.relearning_steps)
    }

    static func incompleteLegacyFsrsBackup(_ state: LearningState) -> Bool {
        state.cards.values.contains { card in
            guard let history = card.fsrsHistory else { return false }
            let applied = Set(card.appliedFsrs ?? [])
            return history.events.contains { event in
                let explicit = event.schedulerKey.flatMap { $0.isEmpty ? nil : $0 }
                return applied.contains(event.id) && (explicit ?? history.schedulerKey)?.isEmpty != false
            }
        }
    }

    // MARK: 常量（与 web 一致）

    static let legacyStab: [Int: Double] = [1: 1, 2: 6, 3: 8, 4: 15, 5: 45, 6: 45]
    static let ladderInterval: [Int: Int] = [1: 1, 2: 6, 3: 8, 4: 15, 5: 45]

    // MARK: 掌握判定

    static func completedDailyWords(_ log: [LogEntry], day: String) -> Set<String> {
        Set(log.filter { $0.d == day && ["learn", "review", "probe"].contains($0.kind) }.map(\.word))
    }

    struct DailyPlanSummary: Equatable {
        let completed: Int
        let dueAvailable: Int
        let duePlanned: Int
        let newPlanned: Int
        let repeatPlanned: Int
        var totalPlanned: Int { completed + duePlanned + newPlanned - repeatPlanned }
    }

    /// Recent retained learning and review records with repeated difficulty.
    /// Placement, probes and speech are different signals and do not count.
    static func stubbornWords(_ s: LearningState) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for entry in s.log where (entry.kind == "learn" || entry.kind == "review") && entry.rating <= 2 {
            counts[entry.word, default: 0] += 1
        }
        var result: [(String, Int)] = []
        for (word, count) in counts {
            guard count >= 2, let card = s.cards[word], !isMastered(card) else { continue }
            result.append((word, count))
        }
        result.sort { a, b in a.1 == b.1 ? a.0 < b.0 : a.1 > b.1 }
        return Array(result.prefix(8))
    }

    static func stubbornDrillWords(_ s: LearningState, day: String, now: Date) -> [String] {
        let completed = completedDailyWords(s.log, day: day)
        let remaining = max(0, s.settings.dailyCap - completed.count)
        var newSlots = max(0, remaining - dailyPlanSummary(s, day: day, now: now).newPlanned)
        return stubbornWords(s).map(\.0).filter { word in
            if completed.contains(word) { return true }
            guard newSlots > 0 else { return false }
            newSlots -= 1
            return true
        }
    }

    /// 与建队列相同的去重、新词目标及每日容量规则；不预估随机探测和提前复习。
    static func dailyPlanSummary(_ s: LearningState, day: String, now: Date) -> DailyPlanSummary {
        let completed = completedDailyWords(s.log, day: day)
        let remaining = max(0, s.settings.dailyCap - completed.count)
        let dueCards = s.cards.filter { word, card in
            !isMastered(card) && (!completed.contains(word) || [1, 3].contains(card.fsrs?.state ?? 0)) &&
                (DayUtil.parseISO(card.due) ?? .distantFuture) <= now
        }
        let repeats = dueCards.filter { completed.contains($0.key) }.count
        let due = dueCards.count
        let learned = Set(s.log.filter { $0.d == day && $0.kind == "learn" }.map(\.word)).count
        let plannedNew = min(max(0, s.settings.newPerDay - learned), remaining)
        let plannedDue = repeats + min(due - repeats, max(0, remaining - plannedNew))
        return DailyPlanSummary(completed: completed.count, dueAvailable: due, duePlanned: plannedDue, newPlanned: plannedNew, repeatPlanned: repeats)
    }

    /// Group actual due instants by the device's calendar day; old date-only
    /// values are parsed at UTC midnight, as they are in Web's review queue.
    static func forecastDueDates(_ cards: [String: CardState], day: String, days: Int = 14) -> [(String, Int)] {
        guard days > 0 else { return [] }
        var result = (0..<days).map { (DayUtil.addDays(day, $0), 0) }
        let indices = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.0, $0.offset) })
        for card in cards.values {
            if isMastered(card) { continue }
            guard let due = DayUtil.parseISO(card.due) else { continue }
            let localDay = DayUtil.localDay(due)
            if localDay < day { result[0].1 += 1 }
            else if let index = indices[localDay] { result[index].1 += 1 }
        }
        return result
    }

    struct RetentionSummary {
        var counts = [0, 0, 0, 0, 0]
        var unknown = 0
        var approximate = 0
    }

    /// Estimate with the default curve, using exact FSRS review times when
    /// present. Legacy day-only learning/review logs are approximate; sentence
    /// exposure and unprocessed offline ratings are not a confirmed review.
    static func retentionSummary(_ cards: [String: CardState], log: [LogEntry], now: Date) -> RetentionSummary {
        var latest: [String: Date] = [:]
        for event in log where event.kind == "learn" || event.kind == "review" {
            guard event.d.count == 10, DayUtil.parseISO(event.d) != nil,
                  let time = DayUtil.parseISO(event.d + "T08:00:00Z") else { continue }
            if latest[event.word] == nil || time > latest[event.word]! { latest[event.word] = time }
        }
        var result = RetentionSummary()
        for (word, card) in cards {
            guard let fsrs = card.fsrs, fsrs.stability.isFinite, fsrs.stability > 0,
                  card.pendingFsrs?.events.isEmpty != false else { result.unknown += 1; continue }
            let recorded = fsrs.lastReview
            let timestamp: Date?
            if let recorded {
                let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2}))?$"#
                if recorded.range(of: pattern, options: .regularExpression) != nil,
                   DayUtil.parseISO(String(recorded.prefix(10))) != nil { timestamp = DayUtil.parseISO(recorded) }
                else { timestamp = nil }
            } else { timestamp = latest[word] }
            guard let timestamp, now.timeIntervalSince1970.isFinite, timestamp <= now else { result.unknown += 1; continue }
            if recorded == nil || recorded?.count == 10 { result.approximate += 1 }
            let r = retrievability(card, elapsedDays: now.timeIntervalSince(timestamp) / 86400)
            result.counts[r >= 0.95 ? 0 : r >= 0.9 ? 1 : r >= 0.8 ? 2 : r >= 0.6 ? 3 : 4] += 1
        }
        return result
    }

    static func comparePersonalVersions(_ a: PersonalVersion?, _ b: PersonalVersion?) -> Int {
        guard let a else { return b == nil ? 0 : -1 }
        guard let b else { return 1 }
        if a.counter != b.counter { return a.counter < b.counter ? -1 : 1 }
        if a.device == b.device { return 0 }
        return a.device < b.device ? -1 : 1
    }

    static func reservePersonalVersions(_ state: LearningState, words: [String], device: String, deleted: Bool = false) -> [String: PersonalVersion]? {
        var result: [String: PersonalVersion] = [:]
        for word in Set(words) {
            var counter = state.personalVersions?[word]?.counter ?? 0
            for job in state.personalJobs ?? [] { counter = max(counter, job.personalVersions?[word]?.counter ?? 0) }
            guard counter >= 0, counter < 9_007_199_254_740_991 else { return nil }
            result[word] = PersonalVersion(counter: counter + 1, device: device, deleted: deleted)
        }
        return result
    }

    @discardableResult
    static func rejectPersonalSentence(_ state: inout LearningState, word: String, text: String, device: String) -> Bool {
        guard !word.isEmpty, !text.isEmpty else { return false }
        let matches = state.personalized[word]?.text == text
        let version = matches ? reservePersonalVersions(state, words: [word], device: device, deleted: true)?[word] : nil
        if matches && version == nil { return false }
        var rejected = state.rejectedPersonalized ?? [:]
        var texts = rejected[word] ?? []
        if !texts.contains(text) { texts.append(text) }
        rejected[word] = texts
        state.rejectedPersonalized = rejected
        if matches {
            state.personalized.removeValue(forKey: word)
            if state.personalVersions == nil { state.personalVersions = [:] }
            state.personalVersions?[word] = version
        }
        return true
    }

    static func applyPersonalJobResult(_ state: inout LearningState, job: PersonalJob, row: PersonalizedOut.Row) -> Bool {
        let word = row.target, version = job.personalVersions?[word], current = state.personalVersions?[word]
        let reservations = (state.personalJobs ?? []).compactMap { $0.personalVersions?[word] }
        if version == nil && (current != nil || !reservations.isEmpty) { return false }
        if let version {
            if comparePersonalVersions(version, current) < 0 || reservations.contains(where: { comparePersonalVersions(version, $0) < 0 }) ||
                (comparePersonalVersions(version, current) == 0 && current?.deleted == true) { return false }
        }
        let value = PersonalizedSentence(text: row.text, recall: row.recall, zh: row.zh ?? "")
        if let version, comparePersonalVersions(version, current) == 0, let existing = state.personalized[word],
           (existing.text != value.text || (existing.recall ?? "") != (value.recall ?? "") || (existing.zh ?? "") != (value.zh ?? "")) { return false }
        let changed = state.personalized[word] != value || (version != nil && comparePersonalVersions(version, current) != 0)
        state.personalized[word] = value
        if let version {
            if state.personalVersions == nil { state.personalVersions = [:] }
            state.personalVersions?[word] = version
        }
        return changed
    }

    static func remainingDailyCapacity(_ log: [LogEntry], day: String, cap: Int) -> Int {
        max(0, cap - completedDailyWords(log, day: day).count)
    }

    static func nextPlacementVersion(_ previous: PlacementVersion?, device: String, id: String) -> PlacementVersion? {
        let counter = previous?.counter ?? 0
        guard counter >= 0, counter < 9_007_199_254_740_991 else { return nil }
        return PlacementVersion(counter: counter + 1, device: device, id: id)
    }

    /// 保留最近三个学习日期以及本机今天的每词记录，避免跨时区时丢失限额依据。
    static func trimLearningLog(_ log: [LogEntry], day: String) -> [LogEntry] {
        let start = max(0, log.count - 1200), kinds = Set(["learn", "review", "probe"])
        let activeDays = Set(log.filter { kinds.contains($0.kind) && $0.d.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil }.map(\.d))
        let days = Set(activeDays.sorted().suffix(3)).union([day])
        var last: [String: Int] = [:]
        for (index, item) in log.enumerated() where days.contains(item.d) && kinds.contains(item.kind) {
            last[item.d + "\u{0}" + item.kind + "\u{0}" + item.word] = index
        }
        let keep = Set(last.values)
        return log.enumerated().compactMap { index, item in index >= start || keep.contains(index) ? item : nil }
    }

    static func hasStudyActivity(_ log: [LogEntry], day: String) -> Bool {
        log.contains { $0.d == day && (["learn", "review", "probe", "placement", "shadow"].contains($0.kind) || ($0.kind == "exposure" && $0.source == "shadow" && $0.score != nil)) }
    }

    static func recordStudyDay(_ s: inout LearningState, day: String) {
        if s.streakEvidence == nil {
            s.streakEvidence = StreakEvidence(baseId: s.lastDay == nil ? "empty" : UUID().uuidString.lowercased(),
                                              baseDay: s.lastDay, baseStreak: s.streak, days: [])
        }
        guard var evidence = s.streakEvidence else { return }
        if !evidence.days.contains(day) { evidence.days.append(day) }
        evidence.days.sort()
        var last = evidence.baseDay, streak = evidence.baseStreak
        if let last {
            let days = Set(evidence.days)
            var first = DayUtil.addDays(last, 1 - streak)
            while first > "0001-01-01" && days.contains(DayUtil.addDays(first, -1)) {
                first = DayUtil.addDays(first, -1)
                streak += 1
            }
        }
        for current in evidence.days {
            if let previous = last, current <= previous { continue }
            streak = last == DayUtil.addDays(current, -1) ? streak + 1 : 1
            last = current
        }
        s.streakEvidence = evidence
        s.lastDay = last
        s.streak = streak
    }

    static func isMastered(_ c: CardState) -> Bool {
        if c.pendingFsrs?.events.contains(where: { $0.rating == 1 }) == true { return false }
        if [1, 3].contains(c.fsrs?.state ?? 0) { return false }
        return c.stage == 6 || (c.fsrs.map { $0.stability >= 180 } ?? false)
    }

    // MARK: FSRS 请求构造（新卡 / FSRS 卡 / 旧阶梯卡迁移）

    /// lastReview：该词上一次学习/复习日期（YYYY-MM-DD，从日志推导），必须传给服务端；
    /// 缺了它 FSRS 会把距上次复习算成 0 天，稳定度不增长（2026-10-26 实测发现的 P0）
    static func fsrsBody(for c: CardState?, rating: Int, isNewCard: Bool, lastReview: String? = nil) -> APIClient.FsrsIn {
        let lr = lastReview.map { $0 + "T08:00:00Z" }
        if let fsrs = c?.fsrs {
            return APIClient.FsrsIn(is_new: false, state: fsrs.state,
                                    stability: fsrs.stability, difficulty: fsrs.difficulty,
                                    due: fsrs.due, rating: rating, step: fsrs.step,
                                    last_review: fsrs.lastReview ?? lr)
        }
        if isNewCard {
            return APIClient.FsrsIn(is_new: true, rating: rating)
        }
        // 旧阶梯卡：stage → 初始稳定度映射
        let stage = c?.stage ?? 1
        var due = c?.due
        if let d = c?.due, d.count == 10 { due = d + "T12:00:00Z" }
        return APIClient.FsrsIn(is_new: false, state: 2,
                                stability: legacyStab[stage] ?? 1, difficulty: 5,
                                due: due, rating: rating, last_review: lr)
    }

    /// 应用服务端 FSRS 结果到卡片
    static func applyFsrs(_ r: FsrsResponse, to c: inout CardState, today: String) {
        c.fsrs = FsrsState(state: r.state, stability: r.stability,
                           difficulty: r.difficulty, due: r.due,
                           scheduled_days: r.scheduled_days, step: r.step, lastReview: r.lastReview)
        c.due = r.due ?? DayUtil.isoString(
            Calendar.current.date(byAdding: .day, value: 1,
                                  to: DayUtil.parseISO(today + "T08:00:00Z") ?? Date()) ?? Date())
        c.stage = nil
    }

    /// 无副作用地按事件时间重放；调用者仅在整批成功且卡片未变化时提交结果。
    static func replayFsrs(_ pending: PendingFsrs,
                           onVersion: (String, String) -> Void = { _, _ in },
                           call: (APIClient.FsrsIn) async throws -> FsrsResponse) async throws -> FsrsResponse? {
        var body = pending.base
        var result: FsrsResponse?
        for event in pending.events {
            let schedulerKey = event.schedulerKey ?? pending.schedulerKey
            body.scheduler_key = schedulerKey
            body.rating = event.rating
            body.now = event.at
            body.deterministic = true
            let response = try await call(body)
            if let expected = schedulerKey, response.schedulerKey != expected {
                throw FsrsReplayError.schedulerChanged
            }
            if let version = response.schedulerKey ?? schedulerKey { onVersion(event.id, version) }
            result = response
            body = APIClient.FsrsIn(state: response.state, stability: response.stability,
                                    difficulty: response.difficulty, due: response.due,
                                    rating: event.rating, step: response.step,
                                    last_review: response.lastReview)
        }
        return result
    }

    /// 端点不可用时的本地阶梯兜底（与 web ladderFallback 一致）
    static func ladderFallback(_ c: inout CardState, rating: Int, today: String) {
        if rating == 1 {
            c.stage = max(1, (c.stage ?? 1) - 1)
            c.due = DayUtil.addDays(today, 1) + "T12:00:00Z"
            c.lt = 0
            return
        }
        let mult: Double = rating == 2 ? 0.6 : (rating == 4 ? 1.5 : 1)
        c.stage = min(5, (c.stage ?? 1) + 1)
        let days = max(1, Int((Double(ladderInterval[c.stage!] ?? 1) * mult).rounded()))
        c.due = DayUtil.addDays(today, days) + "T12:00:00Z"
    }

    // MARK: 记忆保持率（FSRS-6 遗忘曲线幂律近似）

    static func retrievability(_ c: CardState, elapsedDays t: Double) -> Double {
        let s0 = c.fsrs.map { max(0.2, $0.stability) } ?? 2
        return pow(1 + 0.9805 * t / s0, -0.1542)
    }

    // MARK: 定级（网格贝叶斯，0~12000 步长 250）

    static let grid: [Double] = stride(from: 0.0, through: 12000.0, by: 250.0).map { $0 }

    static func logistic(_ x: Double) -> Double { 1 / (1 + exp(-x)) }

    /// 纯函数版 3PL 后验计算：独立校验可复用，不写 LearningState
    static func posteriorCalc(_ post: [Double]?, rank: Int, resp: Double, weight: Double = 1.0, guess: Double = 0) -> [Double] {
        let base = post ?? [Double](repeating: 1.0 / Double(grid.count), count: grid.count)
        var sum = 0.0
        let out = base.enumerated().map { i, p -> Double in
            let pk = guess + (1 - guess) * logistic((grid[i] - Double(rank)) / 400)
            let raw = resp * pk + (1 - resp) * (1 - pk)
            let like = pow(raw, weight)
            let v = p * like
            sum += v
            return v
        }
        return sum > 0 ? out.map { $0 / sum } : out
    }

    static func recordPosterior(_ s: inout LearningState, kind: String, rank: Int? = nil, resp: Double? = nil, weight: Double? = nil, guess: Double? = nil) {
        if s.posteriorHistory == nil {
            let empty = s.posterior == nil && s.probeCount == 0
            s.posteriorHistory = PosteriorHistory(baseId: empty ? "empty" : UUID().uuidString.lowercased(), base: s.posterior, baseCount: s.probeCount)
        }
        guard var history = s.posteriorHistory else { return }
        let parents = Set(history.events.values.flatMap { $0.parents })
        let heads = history.events.keys.filter { !parents.contains($0) }.sorted()
        let defaults = UserDefaults.standard, key = "vocab_settings_device"
        let device = defaults.string(forKey: key) ?? UUID().uuidString.lowercased()
        defaults.set(device, forKey: key)
        let event = PosteriorEvent(kind: kind, device: device, at: ISO8601DateFormatter().string(from: Date()), day: DayUtil.today(), parents: heads, rank: rank, resp: resp, weight: weight, guess: guess)
        history.events[UUID().uuidString.lowercased()] = event
        s.posteriorHistory = history
    }

    static func posteriorUpdate(_ s: inout LearningState, rank: Int, resp: Double, weight: Double = 1.0, guess: Double = 0) {
        recordPosterior(&s, kind: "update", rank: rank, resp: resp, weight: weight, guess: guess)
        s.posterior = posteriorCalc(s.posterior, rank: rank, resp: resp, weight: weight, guess: guess)
        s.probeCount += 1
    }

    static func posteriorMean(_ p: [Double]?) -> Double {
        guard let p else { return 0 }
        return zip(grid, p).map(*).reduce(0, +)
    }

    static func posteriorStd(_ p: [Double]?) -> Double {
        guard let p else { return 0 }
        let m = posteriorMean(p)
        return sqrt(zip(grid, p).map { ($0 - m) * ($0 - m) * $1 }.reduce(0, +))
    }

    static func postMean(_ s: LearningState) -> Double { posteriorMean(s.posterior) }

    static func postStd(_ s: LearningState) -> Double { posteriorStd(s.posterior) }

    // MARK: v2.0 词级知识预测（HLR/BKT 思路）

    static let placementBands = [(1, 2000), (2001, 4000), (4001, 6000),
                                 (6001, 8000), (8001, 10000), (10001, 10987)]

    static func bandIndex(of pos: Int) -> Int {
        for (i, b) in placementBands.enumerated() where pos >= b.0 && pos <= b.1 { return i }
        return placementBands.count - 1
    }

    static func bandPrior(_ s: LearningState, _ index: Int) -> Double {
        if let st = s.bandStats?["\(index)"], st.a + st.b > 0 { return st.a / (st.a + st.b) }
        let b = placementBands[index]
        let center = Double(b.0 + b.1) / 2
        if s.frontier > 0 { return max(0.05, min(0.95, logistic((Double(s.frontier) - center) / 400))) }
        return 0.2   // 没有定级证据时保持保守先验，避免默认每档都“会一半”导致预计认识词数虚高
    }

    static func knowledgeProb(_ s: LearningState, word: String, pos: Int) -> Double {
        if let c = s.cards[word], let fsrs = c.fsrs {
            let last = fsrs.lastReview ?? s.log.last { $0.word == word && ($0.kind == "learn" || $0.kind == "review") }?.d
            let elapsed = last.flatMap { DayUtil.parseISO($0.count == 10 ? $0 + "T08:00:00Z" : $0).map { max(0, Date().timeIntervalSince($0) / 86400) } } ?? 0
            return pow(1 + 0.9805 * elapsed / max(0.2, fsrs.stability), -0.1542)
        }
        if let k = s.knowledge?[word], k.a + k.b > 0 { return k.a / (k.a + k.b) }
        return bandPrior(s, bandIndex(of: pos))
    }

    static func expectedKnown(_ s: LearningState) -> Int {
        var total = 0.0
        for i in placementBands.indices {
            let b = placementBands[i]
            total += Double(b.1 - b.0 + 1) * bandPrior(s, i)
        }
        let words = Set((s.knowledge ?? [:]).keys).union(s.cards.keys)
        for w in words {
            let pos = s.cards[w]?.pos ?? s.knowledge?[w]?.pos ?? s.pointer
            let idx = bandIndex(of: pos)
            total += knowledgeProb(s, word: w, pos: pos) - bandPrior(s, idx)
        }
        return max(0, Int(total.rounded()))
    }

    static func placementPointer(_ s: LearningState) -> Int {
        for (i, b) in placementBands.enumerated() {
            let p = bandPrior(s, i)
            if p < 0.75 {
                return max(b.0, min(b.1, b.0 + Int(Double(b.1 - b.0 + 1) * p)))
            }
        }
        return placementBands[placementBands.count - 1].1 - 50
    }

    static func recordKnowledge(_ s: inout LearningState, word: String, pos: Int, ok: Bool, isPlacement: Bool = false) {
        var k = s.knowledge?[word] ?? KnowledgeStat(a: 0, b: 0, pos: pos)
        let baseId = (k.a == 0 && k.b == 0) ? "empty" : UUID().uuidString.lowercased()
        var evidence = s.knowledgeEvidence?[word] ?? KnowledgeEvidence(baseId: baseId, base: k, events: [:])
        let defaults = UserDefaults.standard, deviceKey = "vocab_settings_device"
        let stored = defaults.string(forKey: deviceKey)
        let device = stored.flatMap { UUID(uuidString: $0) != nil ? $0.lowercased() : nil } ?? UUID().uuidString.lowercased()
        defaults.set(device, forKey: deviceKey)
        let eventId = UUID().uuidString.lowercased()
        let event = KnowledgeEvent(device: device, at: ISO8601DateFormatter().string(from: Date()), ok: ok, pos: pos)
        evidence.events[eventId] = event
        if s.knowledgeEvidence == nil { s.knowledgeEvidence = [:] }
        s.knowledgeEvidence?[word] = evidence
        if ok { k.a += 1 } else { k.b += 1 }
        k.pos = pos
        if s.knowledge == nil { s.knowledge = [:] }
        s.knowledge?[word] = k
        if isPlacement {
            let idx = bandIndex(of: pos)
            var st = s.bandStats?["\(idx)"] ?? KnowledgeStat(a: 0, b: 0, pos: nil)
            let bandBaseId = (st.a == 0 && st.b == 0) ? "empty" : UUID().uuidString.lowercased()
            var band = s.bandEvidence?["\(idx)"] ?? KnowledgeEvidence(baseId: bandBaseId, base: st, events: [:])
            band.events[eventId] = event
            if s.bandEvidence == nil { s.bandEvidence = [:] }
            s.bandEvidence?["\(idx)"] = band
            if ok { st.a += 1 } else { st.b += 1 }
            if s.bandStats == nil { s.bandStats = [:] }
            s.bandStats?["\(idx)"] = st
        }
    }

    /// v1.3 置信度扩散（借鉴 Glicko RD 增长）：每天一次，后验与 σ=100 高斯核卷积。
    /// 均值不变、std 缓慢回升（封顶 400）——水平会漂移，收敛后的后验保持"可被说服"
    static func diffusePosterior(_ s: inout LearningState) {
        guard let p = s.posterior, postStd(s) < 400 else { return }
        guard !(s.posteriorHistory?.events.values.contains { $0.kind == "diffuse" && $0.day == DayUtil.today() } ?? false) else { return }
        recordPosterior(&s, kind: "diffuse")
        let k = exp(-(250.0 * 250.0) / (2 * 100.0 * 100.0))   // 网格步长 250 的邻位权重 ≈0.0439
        let n = p.count
        var out = [Double](repeating: 0, count: n)
        var sum = 0.0
        for i in 0..<n {
            let v = p[i] + k * ((i > 0 ? p[i - 1] : 0) + (i < n - 1 ? p[i + 1] : 0))
            out[i] = v
            sum += v
        }
        if sum > 0 { s.posterior = out.map { $0 / sum } }
    }

    // MARK: 薄弱词（近 7 天评分 ≤2 的词，当天个性化/织入用）

    static func recentWeakWords(_ s: LearningState, today: String, excludeMastered: Bool = true) -> [String] {
        let since = DayUtil.addDays(today, -7)
        var seen = Set<String>()
        var out: [String] = []
        for l in s.log where l.rating <= 2 && l.d >= since {
            if excludeMastered, let c = s.cards[l.word], isMastered(c) { continue }
            if seen.insert(l.word).inserted { out.append(l.word) }
        }
        return out
    }
}
