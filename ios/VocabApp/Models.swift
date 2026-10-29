import Foundation
import Observation

// MARK: - 学习状态（与 Web 端 vocab_v1 完全同构，跨端无损同步）
// 字段清单与 web/index.html 的 defaultState() + 运行期扩展字段一一对应。
// 日期/到期时间一律保留原始字符串，解析仅在比较时进行，保证往返不失真。

struct FsrsState: Codable, Equatable {
    var state: Int            // 1 Learning / 2 Review / 3 Relearning
    var stability: Double
    var difficulty: Double
    var due: String?
    var scheduled_days: Double?
    var step: Int?            // Learning/Relearning 当前步数；可选兼容旧存档
    var lastReview: String?   // 上次复习时间，避免依赖会被裁剪的日志推导

    private enum CodingKeys: String, CodingKey {
        case state, stability, difficulty, due, scheduled_days, step, lastReview
        case legacyLastReview = "last_review"
    }

    init(state: Int, stability: Double, difficulty: Double, due: String?,
         scheduled_days: Double?, step: Int?, lastReview: String?) {
        self.state = state; self.stability = stability; self.difficulty = difficulty
        self.due = due; self.scheduled_days = scheduled_days; self.step = step
        self.lastReview = lastReview
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(Int.self, forKey: .state)
        stability = try c.decode(Double.self, forKey: .stability)
        difficulty = try c.decode(Double.self, forKey: .difficulty)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        scheduled_days = try c.decodeIfPresent(Double.self, forKey: .scheduled_days)
        step = try c.decodeIfPresent(Int.self, forKey: .step)
        lastReview = try c.decodeIfPresent(String.self, forKey: .lastReview)
            ?? c.decodeIfPresent(String.self, forKey: .legacyLastReview)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encode(stability, forKey: .stability)
        try c.encode(difficulty, forKey: .difficulty)
        try c.encodeIfPresent(due, forKey: .due)
        try c.encodeIfPresent(scheduled_days, forKey: .scheduled_days)
        try c.encodeIfPresent(step, forKey: .step)
        try c.encodeIfPresent(lastReview, forKey: .lastReview)
    }
}

struct FsrsSchedulerBackups: Decodable {
    var versions: [String: FsrsSchedulerConfig]
}

struct FsrsSchedulerConfig: Codable, Equatable {
    var library: String
    var parameters: [Double]
    var desired_retention: Double
    var learning_steps: [Double]
    var relearning_steps: [Double]
    var maximum_interval: Int
}

struct PendingFsrsEvent: Codable, Equatable {
    var id: String
    var rating: Int
    var at: String
    var schedulerKey: String? = nil // 应用该次评分时的参数版本
}

struct PendingFsrs: Codable, Equatable {
    var base: APIClient.FsrsIn
    var events: [PendingFsrsEvent]
    var schedulerKey: String? = nil
}

struct CardState: Codable, Equatable {
    var stage: Int?           // 旧阶梯遗留（1~6），FSRS 化后删除
    var due: String?          // ISO8601 字符串
    var lt: Int?              // lapse today 计数（旧逻辑保留）
    var pos: Int?             // 词在学习序列中的位置
    var fsrs: FsrsState?
    var easyStreak: Int?      // 连续“熟练”次数；其他评分清零，不改变 FSRS 间隔
    var pendingFsrs: PendingFsrs? = nil // 离线评分在服务器可用时按原时间重放
    var appliedFsrs: [String]? = nil   // 已应用事件 ID，避免旧设备恢复已处理的队列
    var fsrsHistory: PendingFsrs? = nil // 可重放的共同起点与完整评分历史
    var fsrsReplayVersions: [String: String]? = nil // 已按对应参数重放的事件
}

struct LogEntry: Codable, Equatable {
    var d: String             // 本地日期 yyyy-MM-dd
    var word: String
    var rating: Int           // 1 Again / 2 Hard / 3 Good / 4 Easy；曝光事件固定 3，不计薄弱
    var kind: String          // "learn" / "review" / "probe" / "shadow" / "exposure"
    var ts: String? = nil       // 精确时间（曝光效果分析用；老日志只有日期）
    var reverse: Bool? = nil  // probe 是否反向回想
    var source: String? = nil // exposure 来源：personal / trio / weave / shadow
    var sentenceId: String? = nil
    var played: Bool? = nil   // 是否实际播放/朗读
    var score: Int? = nil     // 跟读完整度等百分制得分
    var eventId: String? = UUID().uuidString.lowercased() // 新记录唯一标识，旧存档可缺省
}

struct Sense: Codable, Equatable {
    var pos: String?
    var text: String
}

struct SentenceItem: Codable, Equatable {
    var tier: Int?            // 1 基础 / 2 进阶 / 3 挑战；个性化句为 nil
    var text: String
    var zh: String?
}

extension Array where Element == SentenceItem {
    func firstAlternative(excluding texts: [String]) -> SentenceItem? {
        first { !texts.contains($0.text) }
    }

    // An async replacement may complete after another row was removed or refreshed.
    mutating func replaceSentence(_ original: SentenceItem, with replacement: SentenceItem?) {
        guard let index = firstIndex(of: original) else { return }
        if let replacement { self[index] = replacement } else { remove(at: index) }
    }
}

/// 待学新词（pendingNew 元素 / lexicon/at 返回元素同构）
struct NewWord: Codable, Equatable {
    var word: String
    var pos: Int
    var sense: String?
    var phonetic: String?
    var level: Int?
    var examTags: String?
    var senses: [Sense]?
    var `static`: String?
    var sentences: [SentenceItem]?
    /// 仅本地组队使用：定级/探测答错产生的待补学词，不推进顺序发词游标。
    var fromPending: Bool?
}

// MARK: - 词库等级显示（定义见 pipeline/build_lexicon_*.py）

/// 等级 → 学习者可读名称
func levelDisplayName(_ level: Int?) -> String {
    switch level {
    case 1: return "入门高频"
    case 2: return "基础三千"
    case 3: return "四级"
    case 4: return "六级"
    case 5: return "雅思托福"
    case 6: return "万二高阶"
    default: return ""
    }
}

/// 词条缺 level 字段时按学习位置兜底（词库按 level+frq 排序；词库重建后需同步更新区间）
/// L1 1-903 / L2 904-2652 / L3 2653-4652 / L4 4653-6152 / L5 6153-9152 / L6 9153-10991
func levelForPos(_ pos: Int) -> Int {
    switch pos {
    case ...903: return 1
    case 904...2652: return 2
    case 2653...4652: return 3
    case 4653...6152: return 4
    case 6153...9152: return 5
    default: return 6
    }
}

struct PersonalizedSentence: Codable, Equatable {
    var text: String
    var recall: String?
    var zh: String?
}

struct PersonalVersion: Codable, Equatable {
    var counter: Int
    var device: String
    var deleted: Bool
}

struct PersonalJob: Codable, Equatable {
    var id: String
    var date: String
    var weakKey: String
    var weakWords: [String]
    var learnedMaxPos: Int
    var replace: Bool
    var owner: String
    var status: String
    var personalVersions: [String: PersonalVersion]? = nil
}

/// 水平追踪状态（自适应水平追踪 v1.2/v1.3）：后验本体沿用 S.posterior
struct TrackState: Codable, Equatable {
    var evalDay: String?      // 今日位置重估是否已生效（每日最多一次）
    var lowSince: String?     // 游标持续超前于水平的起始日（连续 2 天触发减压）
    var throttle: Bool?       // 旧档兼容字段；不再自动降低新词目标
    var lastNote: String?     // 最近一次追踪动作的人话说明（完成页展示）
    // v1.3 新增（全可选，兼容旧存档）
    var diffuseDay: String?   // 置信度扩散每日一次
    var pendingBand: Int?     // 滞回：候选新级别（1~6）
    var pendingDays: Int?     // 候选级别已连续天数（≥3 才正式调整）
    var shownLevel: Int?      // 当前对外展示的级别（滞回后）
    var dayW: Double?         // 今日被动证据累计权重（封顶 1.5）
    var dayWDay: String?      // dayW 对应日期
}

/// Separate from LearningState: a server-issued daily reservation is not a
/// learning grade, and restoring a progress backup must not release its slots.
struct SharedStudyWord: Codable, Equatable {
    var word: String
    var kind: String
    var from_pending: Bool = false
}

struct SharedStudyPlan: Codable, Equatable {
    struct Item: Codable, Equatable {
        var word, kind: String
        var new_word, probe_word, completed, from_pending: Bool
    }
    var account_id, day: String
    var cap, new_target: Int
    var configured_cap, configured_new_per_day: Int
    var items: [Item]
    var approved: [String]
    var over_limit, requires_sync: Bool

    func valid(account: String, day: String) -> Bool {
        account_id == account && self.day == day && (0...10000).contains(cap) &&
        (0...10000).contains(configured_cap) && (0...10000).contains(configured_new_per_day) &&
        (0...cap).contains(new_target) && items.count <= 10000 &&
        Set(items.map(\.word)).count == items.count &&
        items.allSatisfy { !$0.word.isEmpty && $0.word.count <= 100 && ["learn","review","probe"].contains($0.kind) }
    }

    func permits(word: String, kind: String) -> Bool {
        guard let item = items.first(where: { $0.word == word }) else { return false }
        return kind == "learn" ? item.new_word : kind == "probe" ? item.probe_word : kind == "review"
    }
}

struct EvalReport: Codable, Equatable {
    var date: String
    var mean: Int
    var std: Int
    var appMean: Int
    var delta: Int
    var correct: Int
    var count: Int
}

struct KnowledgeStat: Codable, Equatable {
    var a: Double = 0
    var b: Double = 0
    var pos: Int?
}

struct KnowledgeEvent: Codable, Equatable {
    var device: String
    var at: String
    var ok: Bool
    var pos: Int
}

struct KnowledgeEvidence: Codable, Equatable {
    var baseId: String
    var base: KnowledgeStat
    var events: [String: KnowledgeEvent]
}

struct PosteriorEvent: Codable, Equatable {
    var kind: String
    var device: String
    var at: String
    var day: String
    var parents: [String]
    var rank: Int? = nil
    var resp: Double? = nil
    var weight: Double? = nil
    var guess: Double? = nil
}

struct PosteriorHistory: Codable, Equatable {
    var algorithm: String = "bayes-grid-1"
    var baseId: String
    var base: [Double]?
    var baseCount: Int
    var events: [String: PosteriorEvent] = [:]
}

struct StreakEvidence: Codable, Equatable {
    var baseId: String
    var baseDay: String?
    var baseStreak: Int
    var days: [String]
}

struct Settings: Codable, Equatable {
    var newPerDay: Int = 10
    var dailyCap: Int = 100
    var voice: String?        // TTS 嗓音；nil=服务器默认 Aria
    var notifyEnabled: Bool = false   // 每日复习提醒
    var notifyHour: Int = 21          // 提醒时间（整点）

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        newPerDay = try c.decodeIfPresent(Int.self, forKey: .newPerDay) ?? 10
        dailyCap = try c.decodeIfPresent(Int.self, forKey: .dailyCap) ?? 100
        voice = try c.decodeIfPresent(String.self, forKey: .voice)
        notifyEnabled = try c.decodeIfPresent(Bool.self, forKey: .notifyEnabled) ?? false
        notifyHour = try c.decodeIfPresent(Int.self, forKey: .notifyHour) ?? 21
    }
}

struct SettingVersion: Codable, Equatable {
    var counter: Int
    var device: String
}

struct PlacementVersion: Codable, Equatable {
    var counter: Int
    var device: String
    var id: String
}

struct LearningState: Codable, Equatable {
    var v: Int = 1
    var calibrated: Bool = false
    var frontier: Int = 0
    var pointer: Int = 1
    var probeCount: Int = 0
    var posterior: [Double]?
    var posteriorHistory: PosteriorHistory?
    var pendingNew: [NewWord] = []
    var cards: [String: CardState] = [:]
    var log: [LogEntry] = []
    var personalized: [String: PersonalizedSentence] = [:]
    var rejectedPersonalized: [String: [String]]?
    var personalVersions: [String: PersonalVersion]?
    var streak: Int = 0
    var lastDay: String?
    var streakEvidence: StreakEvidence?
    var settings: Settings = .init()
    var settingsVersions: [String: SettingVersion]?
    // 运行期扩展字段（web 里动态添加，这里显式声明以免同步丢失）
    var quizDay: String?
    var quizProgressDay: String?
    var quizCompleted: [String]?
    var weaveDay: String?
    var weaveCount: Int = 0
    var wrongStreak: Int = 0
    var personalizedDay: String?
    var personalizedWeak: String?
    var personalJobs: [PersonalJob]? // 保留请求参数，便于断网和重启后幂等恢复
    var track: TrackState?          // 自适应水平追踪状态（v1.2 新增，可选兼容旧存档）
    var evalReport: EvalReport?     // 独立留出校验报告（v1.4；不参与学习调度）
    var placementResetAt: Double?   // 显式重新定级时间戳，防止同步合并撤销重测
    var placementVersion: PlacementVersion? // 逻辑版本；不依赖设备时钟排序
    var restoreEpoch: Int?          // 服务端恢复后的版本；旧设备不可覆盖恢复结果
    var fsrsSchedulers: [String: FsrsSchedulerConfig]? // 随备份携带可验证的参数快照
    var bandStats: [String: KnowledgeStat]?   // 各词汇量档位先验（v2.0 词级模型）
    var bandEvidence: [String: KnowledgeEvidence]? // 与定级词级事件关联的分档证据
    var knowledge: [String: KnowledgeStat]?   // 每词 a/b 证据（v2.0 词级模型）
    var knowledgeEvidence: [String: KnowledgeEvidence]? // 可合并的词级证据事件及共同基线

    init() {}

    /// 缺省容错：web 运行期扩展字段在老存档里可能不存在，缺省值补齐
    /// （Swift 合成 Decodable 不会用属性默认值，必须手写）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        calibrated = try c.decodeIfPresent(Bool.self, forKey: .calibrated) ?? false
        frontier = try c.decodeIfPresent(Int.self, forKey: .frontier) ?? 0
        pointer = try c.decodeIfPresent(Int.self, forKey: .pointer) ?? 1
        probeCount = try c.decodeIfPresent(Int.self, forKey: .probeCount) ?? 0
        posterior = try c.decodeIfPresent([Double].self, forKey: .posterior)
        posteriorHistory = try c.decodeIfPresent(PosteriorHistory.self, forKey: .posteriorHistory)
        pendingNew = try c.decodeIfPresent([NewWord].self, forKey: .pendingNew) ?? []
        cards = try c.decodeIfPresent([String: CardState].self, forKey: .cards) ?? [:]
        log = try c.decodeIfPresent([LogEntry].self, forKey: .log) ?? []
        personalized = try c.decodeIfPresent([String: PersonalizedSentence].self, forKey: .personalized) ?? [:]
        rejectedPersonalized = try c.decodeIfPresent([String: [String]].self, forKey: .rejectedPersonalized)
        personalVersions = try c.decodeIfPresent([String: PersonalVersion].self, forKey: .personalVersions)
        streak = try c.decodeIfPresent(Int.self, forKey: .streak) ?? 0
        lastDay = try c.decodeIfPresent(String.self, forKey: .lastDay)
        streakEvidence = try c.decodeIfPresent(StreakEvidence.self, forKey: .streakEvidence)
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        settingsVersions = try c.decodeIfPresent([String: SettingVersion].self, forKey: .settingsVersions)
        quizDay = try c.decodeIfPresent(String.self, forKey: .quizDay)
        quizProgressDay = try c.decodeIfPresent(String.self, forKey: .quizProgressDay)
        quizCompleted = try c.decodeIfPresent([String].self, forKey: .quizCompleted)
        weaveDay = try c.decodeIfPresent(String.self, forKey: .weaveDay)
        weaveCount = try c.decodeIfPresent(Int.self, forKey: .weaveCount) ?? 0
        wrongStreak = try c.decodeIfPresent(Int.self, forKey: .wrongStreak) ?? 0
        personalizedDay = try c.decodeIfPresent(String.self, forKey: .personalizedDay)
        personalizedWeak = try c.decodeIfPresent(String.self, forKey: .personalizedWeak)
        personalJobs = try c.decodeIfPresent([PersonalJob].self, forKey: .personalJobs)
        track = try c.decodeIfPresent(TrackState.self, forKey: .track)
        evalReport = try c.decodeIfPresent(EvalReport.self, forKey: .evalReport)
        placementResetAt = try c.decodeIfPresent(Double.self, forKey: .placementResetAt)
        placementVersion = try c.decodeIfPresent(PlacementVersion.self, forKey: .placementVersion)
        restoreEpoch = try c.decodeIfPresent(Int.self, forKey: .restoreEpoch)
        fsrsSchedulers = try c.decodeIfPresent([String: FsrsSchedulerConfig].self, forKey: .fsrsSchedulers)
        bandStats = try c.decodeIfPresent([String: KnowledgeStat].self, forKey: .bandStats)
        bandEvidence = try c.decodeIfPresent([String: KnowledgeEvidence].self, forKey: .bandEvidence)
        knowledge = try c.decodeIfPresent([String: KnowledgeStat].self, forKey: .knowledge)
        knowledgeEvidence = try c.decodeIfPresent([String: KnowledgeEvidence].self, forKey: .knowledgeEvidence)
    }
}

// MARK: - API DTO

/// 用户名使用服务端的 ASCII 大小写不敏感规则；文件名不含路径字符。
enum LocalAccountSlot {
    static func validAccountID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func name(userId: Int, username: String, accountId: String? = nil) -> String {
        if let accountId { return "a\(accountId)" }
        let encoded = username.lowercased().utf8.map { String(format: "%02x", $0) }.joined()
        return "u\(userId)_\(encoded)"
    }

    static func loadVerified(state: URL, owner: URL, expected: String?) -> LearningState? {
        if let expected {
            guard let stored = try? String(contentsOf: owner, encoding: .utf8),
                  stored.lowercased() == expected.lowercased() else { return nil }
        }
        guard let data = try? Data(contentsOf: state),
              let result = try? JSONDecoder().decode(LearningState.self, from: data) else { return nil }
        return result
    }

    static func migrateClocks(_ defaults: UserDefaults, from legacy: String, to slot: String) {
        let newWrite = "vocab_write_\(slot)"
        guard defaults.object(forKey: newWrite) == nil else { return }
        let oldWrite = "vocab_write_\(legacy)", oldSync = "vocab_sync_\(legacy)"
        if defaults.object(forKey: oldWrite) == nil || defaults.object(forKey: oldSync) == nil {
            // 没有可靠水位时先补传旧档，不能把它当作已同步而用远端覆盖。
            defaults.set(max(1, Date().timeIntervalSince1970, defaults.double(forKey: oldWrite)), forKey: newWrite)
            defaults.set(0.0, forKey: "vocab_sync_\(slot)")
        } else {
            defaults.set(defaults.double(forKey: oldWrite), forKey: newWrite)
            defaults.set(defaults.double(forKey: oldSync), forKey: "vocab_sync_\(slot)")
        }
    }

    /// 在覆盖无署名或其他账号署名的文件前，原样保留一份不可覆盖的副本。
    static func preserveUnverified(state: URL, owner: URL, expected: String, slot: String, force: Bool = false) throws -> URL? {
        let files = FileManager.default
        guard files.fileExists(atPath: state.path) else { return nil }
        let stored = try? String(contentsOf: owner, encoding: .utf8)
        if !force, stored?.lowercased() == expected.lowercased() { return nil }
        var destinationSlot = slot, category = "unverified"
        if let stored, stored.lowercased() != expected.lowercased() {
            // 可识别的旧署名归还给该用户名；未知署名不展示给当前账号。
            let digits = slot.dropFirst().prefix { $0.isNumber }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
            if slot.hasPrefix("u"), let uid = Int(digits), !stored.isEmpty,
               stored.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
                destinationSlot = name(userId: uid, username: stored)
            } else {
                category = "other-owner"
            }
        }
        let name = "\(category)-\(destinationSlot)-\(UUID().uuidString.lowercased()).json"
        let destination = state.deletingLastPathComponent().appendingPathComponent(name)
        try files.copyItem(at: state, to: destination)
        return destination
    }
}

struct AuthUser: Codable, Equatable {
    var id: Int
    var username: String
    var nickname: String
    var account_id: String?
}

struct AuthResponse: Codable {
    var token: String
    var user: AuthUser
}

struct StateResponse: Codable {
    var state: LearningState?
    var updated_at: Double?
    // Revisions are decimal strings on the wire: they can exceed the range
    // of integers that JavaScript represents exactly. Older servers omit both.
    var state_revision: String?
    var sync_generation: String?
    // Local-only marker: the legacy endpoint could not return this state.
    var fromLargeSnapshot = false
    private enum CodingKeys: String, CodingKey { case state, updated_at, state_revision, sync_generation }
}

struct StateBackupEntry: Codable, Identifiable {
    var id: Int
    var created_at: Double
    var reason: String
}

struct StateBackupList: Codable {
    var backups: [StateBackupEntry]
}

struct QuizOption: Codable, Equatable {
    var text: String
    var ok: Bool
}

/// Owns the brief answer highlight. Leaving or replacing a question cancels
/// its pending callback before it can change another question or account.
@MainActor @Observable
final class QuizAnswerFeedback {
    private(set) var picked: Int?
    private var revision: UInt64 = 0
    private var delivery: Task<Void, Never>?
    private let wait: () async throws -> Void

    init(wait: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 650_000_000) }) {
        self.wait = wait
    }

    func choose(_ index: Int, correct: Bool, commit: @escaping (Bool) -> Void) {
        guard picked == nil else { return }
        picked = index
        revision &+= 1
        let current = revision
        delivery = Task {
            do { try await wait() } catch { return }
            guard !Task.isCancelled, current == revision else { return }
            picked = nil
            delivery = nil
            commit(correct)
        }
    }

    func cancel() {
        revision &+= 1
        delivery?.cancel()
        delivery = nil
        picked = nil
    }
}

struct Quiz: Codable {
    var word: String
    var pos: Int
    var options: [QuizOption]
    var mode: String?      // "reverse"=反向回想（给中文选英文）；nil=正向再认
    var prompt: String?    // 反向模式的题干（中文词义）

    func matches(word expected: String) -> Bool {
        word.caseInsensitiveCompare(expected) == .orderedSame && pos > 0 && options.count == 4 &&
            options.filter(\.ok).count == 1 && options.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct PlacementItem: Codable {
    var word: String
    var pos: Int
    var options: [QuizOption]
}

struct PlacementSet: Codable {
    var words: [PlacementItem]
    var seed: String?
}

struct LexiconAtResponse: Codable {
    var from: Int
    var words: [NewWord]
    var nextPos: Int?
    var exhausted: Bool?

    enum CodingKeys: String, CodingKey {
        case from, words, exhausted
        case nextPos = "next_pos"
    }
}

struct TrioResponse: Codable {
    var word: String
    var sentences: [SentenceItem]
    var err: String?
}

struct WeaveResponse: Codable {
    var text: String
    var zh: String?
    var source: String?
}

struct EnsureResponse: Codable {
    var word: String
    var text: String
    var cached: Bool?
}

struct PersonalizeResponse: Codable {
    var queued: Bool
    var date: String
    var background: Bool?
    var job_id: String?
    var status: String?
}

struct PersonalJobResponse: Codable {
    var job_id: String
    var date: String
    var status: String
    var error: String?
    var sentences: [PersonalizedOut.Row]
}

struct PersonalizedOut: Codable {
    struct Row: Codable {
        var target: String
        var recall: String?
        var text: String
        var zh: String?
    }
    var device: String
    var date: String
    var sentences: [Row]
}

struct FsrsResponse: Codable {
    var state: Int
    var stability: Double
    var difficulty: Double
    var due: String?
    var scheduled_days: Double?
    var step: Int?
    var lastReview: String?
    var schedulerKey: String? = nil
    var schedulerConfig: FsrsSchedulerConfig? = nil

    enum CodingKeys: String, CodingKey {
        case state, stability, difficulty, due, scheduled_days, step
        case lastReview = "last_review"
        case schedulerKey = "scheduler_key"
        case schedulerConfig = "scheduler_config"
    }
}

// MARK: - 日期工具（"今天"用设备本地日期——UTC 日期会让 UTC+8 用户上午被错判成"昨天"，
// 导致验收测试/streak/每日上限全部按错误的日界工作。log/due 的历史 UTC 日期戳向前兼容）

extension LearningState {
    /// Exposure and pronunciation events do not change the last study day.
    func lastStudyDay(for word: String) -> String? {
        log.last { $0.word == word && ($0.kind == "learn" || $0.kind == "review") }?.d
    }
}

enum DayUtil {
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func today() -> String { dayFmt.string(from: Date()) }
    static func localDay(_ date: Date) -> String { dayFmt.string(from: date) }

    /// Match Web's local-noon interpretation of a learning day.
    static func localNoon(_ day: String) -> Date? {
        guard day.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
              let start = dayFmt.date(from: day), dayFmt.string(from: start) == day else { return nil }
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: start)
    }

    static func addDays(_ d: String, _ n: Int) -> String {
        guard let base = dayFmt.date(from: d) else { return d }
        let t = Calendar(identifier: .gregorian).date(byAdding: .day, value: n, to: base) ?? base
        return dayFmt.string(from: t)
    }

    /// 解析各种 ISO8601（web 的 ".000Z" / 服务端的 "+00:00" 带 6 位小数 / 不带小数）
    static func parseISO(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        // JavaScript Date interprets a date-only ISO value at UTC midnight.
        // Older Web cards use this format, so keep the same due instant on iOS.
        if s.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil {
            guard let date = isoPlain.date(from: s + "T00:00:00Z"),
                  String(isoPlain.string(from: date).prefix(10)) == s else { return nil }
            return date
        }
        if let d = isoFrac.date(from: s) { return d }
        if let d = isoPlain.date(from: s) { return d }
        // 服务端可能带 6 位微秒，截断到 3 位再试
        if let dot = s.lastIndex(of: "."), s.distance(from: dot, to: s.endIndex) > 4 {
            var cut = String(s[s.startIndex...dot])
            let tail = s[s.index(after: dot)...]
            let digits = tail.prefix(while: { $0.isNumber }).prefix(3)
            cut += digits
            if let tzStart = tail.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
                cut += tail[tzStart...]
            }
            if let d = isoFrac.date(from: cut) { return d }
        }
        return nil
    }

    static func isoString(_ d: Date) -> String { isoFrac.string(from: d) }
}

/// 分词（与 web 的 tokens() 一致：小写、去首尾撇号）
func wordTokens(_ t: String) -> [String] {
    t.lowercased()
        .split(separator: #/[^a-z']+/#)
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
        .filter { !$0.isEmpty }
}

func shadowCompleteness(target: String, recognized: String) -> Int {
    let expected = wordTokens(target)
    guard !expected.isEmpty else { return 0 }
    var remaining = Dictionary(wordTokens(recognized).map { ($0, 1) }, uniquingKeysWith: +)
    var hits = 0
    for word in expected where (remaining[word] ?? 0) > 0 {
        hits += 1
        remaining[word, default: 0] -= 1
    }
    return Int((Double(hits) / Double(expected.count) * 100).rounded())
}
