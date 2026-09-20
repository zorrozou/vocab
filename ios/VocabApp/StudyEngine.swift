import Foundation

/// 调度引擎：FSRS-6（服务端计算）+ 阶梯兜底 + 定级贝叶斯，全部逻辑 1:1 移植自 web/index.html
enum StudyEngine {

    // MARK: 常量（与 web 一致）

    static let legacyStab: [Int: Double] = [1: 1, 2: 6, 3: 8, 4: 15, 5: 45]
    static let ladderInterval: [Int: Int] = [1: 1, 2: 6, 3: 8, 4: 15, 5: 45]

    // MARK: 掌握判定

    static func isMastered(_ c: CardState) -> Bool {
        c.stage == 6 || (c.fsrs.map { $0.stability >= 180 } ?? false)
    }

    // MARK: FSRS 请求构造（新卡 / FSRS 卡 / 旧阶梯卡迁移）

    static func fsrsBody(for c: CardState?, rating: Int, isNewCard: Bool) -> APIClient.FsrsIn {
        if let fsrs = c?.fsrs {
            return APIClient.FsrsIn(is_new: false, state: fsrs.state,
                                    stability: fsrs.stability, difficulty: fsrs.difficulty,
                                    due: fsrs.due, rating: rating)
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
                                due: due, rating: rating)
    }

    /// 应用服务端 FSRS 结果到卡片
    static func applyFsrs(_ r: FsrsResponse, to c: inout CardState, today: String) {
        c.fsrs = FsrsState(state: r.state, stability: r.stability,
                           difficulty: r.difficulty, due: r.due,
                           scheduled_days: r.scheduled_days)
        c.due = r.due ?? DayUtil.isoString(
            Calendar.current.date(byAdding: .day, value: 1,
                                  to: DayUtil.parseISO(today + "T08:00:00Z") ?? Date()) ?? Date())
        c.stage = nil
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

    static func posteriorUpdate(_ s: inout LearningState, rank: Int, resp: Double) {
        if s.posterior == nil {
            s.posterior = [Double](repeating: 1.0 / Double(grid.count), count: grid.count)
        }
        var sum = 0.0
        s.posterior = s.posterior!.enumerated().map { i, p in
            let pk = logistic((grid[i] - Double(rank)) / 400)
            let like = resp * pk + (1 - resp) * (1 - pk)
            let v = p * like
            sum += v
            return v
        }
        if sum > 0 { s.posterior = s.posterior!.map { $0 / sum } }
        s.probeCount += 1
    }

    static func postMean(_ s: LearningState) -> Double {
        guard let p = s.posterior else { return 0 }
        return zip(grid, p).map(*).reduce(0, +)
    }

    static func postStd(_ s: LearningState) -> Double {
        guard let p = s.posterior else { return 0 }
        let m = postMean(s)
        return sqrt(zip(grid, p).map { ($0 - m) * ($0 - m) * $1 }.reduce(0, +))
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
