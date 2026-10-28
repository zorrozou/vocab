import Foundation
import OSLog

extension Logger {
    static let app = Logger(subsystem: "com.zorro.vocab", category: "app")
}

enum Config {
    static func validatedAPIBase(_ raw: String, requireHTTPS: Bool) -> URL? {
        guard let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased(),
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              scheme == "https" || (!requireHTTPS && scheme == "http") else { return nil }
        return components.url
    }

    /// 可用 Xcode 构建设置 VOCAB_API_BASE_URL 覆盖；正式版只接受 HTTPS。
    static let apiBase: URL? = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "VocabAPIBaseURL") as? String
        #if DEBUG
        // UI regression tests may only redirect the debug build to the isolated loopback service.
        if ProcessInfo.processInfo.environment["VOCAB_UI_TEST_API"] == "http://127.0.0.1:18765" {
            return URL(string: "http://127.0.0.1:18765")
        }
        let fallback = "http://175.27.210.206/vocab"
        #else
        let fallback = "https://zorrozou.online/vocab"
        #endif
        let raw = configured.flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 } ?? fallback
        #if DEBUG
        return validatedAPIBase(raw, requireHTTPS: false)
        #else
        return validatedAPIBase(raw, requireHTTPS: true)
        #endif
    }()
    static let appName = "词航"
    /// 本地状态文件名前缀（按账号分槽位，与 web 的 vocab_v1_u{id}/guest 对应）
    static let stateFilePrefix = "vocab_state"
}
