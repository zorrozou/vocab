import Foundation

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// FastAPI 错误体（{"detail": "..."}）
private struct ErrBody: Decodable { let detail: String? }

/// 服务端 API 客户端（对齐 web/index.html 的全部调用点）
actor APIClient {
    static let shared = APIClient()
    var token: String?

    func setToken(_ t: String?) { token = t }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 130   // trio/weave 生成句可能触发 LLM，给足余量
        return URLSession(configuration: c)
    }()

    // MARK: 基础请求

    private func url(_ path: String, _ query: [String: String] = [:]) throws -> URL {
        // 注意：URL.appendingPathComponent 在新版 Foundation 会把 "/" 编码成 %2F，
        // 这里用字符串拼接保证 /api/v1/... 路径层级不被破坏。
        guard var comp = URLComponents(string: Config.apiBase.absoluteString + path) else {
            throw APIError(message: "URL 构建失败")
        }
        if !query.isEmpty {
            comp.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let u = comp.url else { throw APIError(message: "URL 构建失败") }
        return u
    }

    private func request<T: Decodable>(_ method: String, _ path: String,
                                       query: [String: String] = [:],
                                       body: (any Encodable)? = nil) async throws -> T {
        var req = URLRequest(url: try url(path, query))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONEncoder().encode(body) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "网络异常") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ErrBody.self, from: data))?.detail
            throw APIError(message: detail ?? "HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        try await request("GET", path, query: query)
    }

    // MARK: 认证与状态同步

    func register(username: String, password: String, nickname: String) async throws -> AuthResponse {
        struct In: Encodable { let username, password, nickname: String }
        return try await request("POST", "/api/v1/auth/register",
                                 body: In(username: username, password: password, nickname: nickname))
    }

    func login(username: String, password: String) async throws -> AuthResponse {
        struct In: Encodable { let username, password: String }
        return try await request("POST", "/api/v1/auth/login",
                                 body: In(username: username, password: password))
    }

    func logout() async {
        struct Ok: Decodable { let ok: Bool }
        _ = try? await request("POST", "/api/v1/auth/logout") as Ok
    }

    func pullState() async throws -> StateResponse {
        try await get("/api/v1/me/state")
    }

    func pushState(_ s: LearningState) async throws {
        struct Ok: Decodable { let ok: Bool }
        _ = try await request("PUT", "/api/v1/me/state", body: s) as Ok
    }

    // MARK: 词库与例句

    func lexiconAt(pos: Int, n: Int) async throws -> LexiconAtResponse {
        try await get("/api/v1/lexicon/at", ["pos": "\(pos)", "n": "\(n)"])
    }

    func placementSet(seed: String) async throws -> PlacementSet {
        try await get("/api/v1/placement/set", ["seed": seed])
    }

    func quiz(pos: Int, seed: Int) async throws -> Quiz {
        try await get("/api/v1/quiz", ["pos": "\(pos)", "seed": "\(seed)"])
    }

    func trio(word: String, weak: String, cap: Int) async throws -> TrioResponse {
        try await get("/api/v1/sentence/trio",
                      ["word": word, "weak": weak, "cap": "\(cap)"])
    }

    func weave(word: String, weak: String, cap: Int, device: String) async throws -> WeaveResponse {
        try await get("/api/v1/sentence/weave",
                      ["word": word, "weak": weak, "cap": "\(cap)", "device": device])
    }

    func ensure(word: String) async throws -> EnsureResponse {
        try await get("/api/v1/sentence/ensure", ["word": word])
    }

    func report(word: String, text: String, device: String) async throws {
        struct Out: Decodable { let ok: Bool; let reported: Int? }
        _ = try await request("POST", "/api/v1/sentence/report",
                              query: ["word": word, "text": text, "device": device]) as Out
    }

    // MARK: 个性化

    struct PersonalizeIn: Encodable {
        var device: String
        var date: String
        var new_words: [String] = []
        var weak_words: [String]
        var learned_max_pos: Int
        var sync: Bool = true
        var replace: Bool = false
    }

    func personalize(_ body: PersonalizeIn) async throws -> PersonalizeResponse {
        try await request("POST", "/api/v1/personalize", body: body)
    }

    func personalized(device: String, date: String) async throws -> PersonalizedOut {
        try await get("/api/v1/personalized", ["device": device, "date": date])
    }

    // MARK: FSRS

    struct FsrsIn: Encodable {
        var is_new: Bool = false
        var state: Int = 1
        var stability: Double = 0
        var difficulty: Double = 0
        var due: String?
        var rating: Int = 3
        var last_review: String?
    }

    func fsrsReview(_ body: FsrsIn) async throws -> FsrsResponse {
        try await request("POST", "/api/v1/fsrs/review", body: body)
    }

    // MARK: TTS

    func ttsURL(_ text: String, voice: String?) -> URL? {
        var q = ["text": text]
        if let voice, !voice.isEmpty { q["v"] = voice }
        return try? url("/api/v1/tts", q)
    }

    /// 音频预热（fire-and-forget：让服务器预生成缓存）
    func warmTTS(_ texts: [String], voice: String?) {
        for t in texts.prefix(80) {
            guard let u = ttsURL(t, voice: voice) else { continue }
            session.dataTask(with: u).resume()
        }
    }
}
