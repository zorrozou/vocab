import Foundation

// MARK: - 学习状态（与 Web 端 vocab_v1 完全同构，跨端无损同步）
// 字段清单与 web/index.html 的 defaultState() + 运行期扩展字段一一对应。
// 日期/到期时间一律保留原始字符串，解析仅在比较时进行，保证往返不失真。

struct FsrsState: Codable, Equatable {
    var state: Int            // 1 Learning / 2 Review / 3 Relearning
    var stability: Double
    var difficulty: Double
    var due: String?
    var scheduled_days: Double?
}

struct CardState: Codable, Equatable {
    var stage: Int?           // 旧阶梯遗留（1~6），FSRS 化后删除
    var due: String?          // ISO8601 字符串
    var lt: Int?              // lapse today 计数（旧逻辑保留）
    var pos: Int?             // 词在学习序列中的位置
    var fsrs: FsrsState?
}

struct LogEntry: Codable, Equatable {
    var d: String             // UTC 日期 yyyy-MM-dd（与 web 的 toISOString().slice(0,10) 一致）
    var word: String
    var rating: Int           // 1 Again / 2 Hard / 3 Good / 4 Easy
    var kind: String          // "learn" / "review"
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

struct Settings: Codable, Equatable {
    var newPerDay: Int = 10
    var dailyCap: Int = 100
    var voice: String?        // TTS 嗓音；nil=服务器默认 Aria

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        newPerDay = try c.decodeIfPresent(Int.self, forKey: .newPerDay) ?? 10
        dailyCap = try c.decodeIfPresent(Int.self, forKey: .dailyCap) ?? 100
        voice = try c.decodeIfPresent(String.self, forKey: .voice)
    }
}

struct LearningState: Codable, Equatable {
    var v: Int = 1
    var calibrated: Bool = false
    var frontier: Int = 0
    var pointer: Int = 1
    var probeCount: Int = 0
    var posterior: [Double]?
    var pendingNew: [NewWord] = []
    var cards: [String: CardState] = [:]
    var log: [LogEntry] = []
    var personalized: [String: PersonalizedSentence] = [:]
    var streak: Int = 0
    var lastDay: String?
    var settings: Settings = .init()
    // 运行期扩展字段（web 里动态添加，这里显式声明以免同步丢失）
    var quizDay: String?
    var weaveDay: String?
    var weaveCount: Int = 0
    var wrongStreak: Int = 0
    var personalizedDay: String?
    var personalizedWeak: String?

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
        pendingNew = try c.decodeIfPresent([NewWord].self, forKey: .pendingNew) ?? []
        cards = try c.decodeIfPresent([String: CardState].self, forKey: .cards) ?? [:]
        log = try c.decodeIfPresent([LogEntry].self, forKey: .log) ?? []
        personalized = try c.decodeIfPresent([String: PersonalizedSentence].self, forKey: .personalized) ?? [:]
        streak = try c.decodeIfPresent(Int.self, forKey: .streak) ?? 0
        lastDay = try c.decodeIfPresent(String.self, forKey: .lastDay)
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        quizDay = try c.decodeIfPresent(String.self, forKey: .quizDay)
        weaveDay = try c.decodeIfPresent(String.self, forKey: .weaveDay)
        weaveCount = try c.decodeIfPresent(Int.self, forKey: .weaveCount) ?? 0
        wrongStreak = try c.decodeIfPresent(Int.self, forKey: .wrongStreak) ?? 0
        personalizedDay = try c.decodeIfPresent(String.self, forKey: .personalizedDay)
        personalizedWeak = try c.decodeIfPresent(String.self, forKey: .personalizedWeak)
    }
}

// MARK: - API DTO

struct AuthUser: Codable, Equatable {
    var id: Int
    var username: String
    var nickname: String
}

struct AuthResponse: Codable {
    var token: String
    var user: AuthUser
}

struct StateResponse: Codable {
    var state: LearningState?
    var updated_at: Double?
}

struct QuizOption: Codable, Equatable {
    var text: String
    var ok: Bool
}

struct Quiz: Codable {
    var word: String
    var pos: Int
    var options: [QuizOption]
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
}

// MARK: - 日期工具（"今天"用 UTC 日期，与 web 端完全一致，保证跨端同一天）

enum DayUtil {
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
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

    static func addDays(_ d: String, _ n: Int) -> String {
        guard let base = dayFmt.date(from: d) else { return d }
        let t = Calendar(identifier: .gregorian).date(byAdding: .day, value: n, to: base) ?? base
        return dayFmt.string(from: t)
    }

    /// 解析各种 ISO8601（web 的 ".000Z" / 服务端的 "+00:00" 带 6 位小数 / 不带小数）
    static func parseISO(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
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
