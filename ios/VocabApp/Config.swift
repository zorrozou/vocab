import Foundation

enum Config {
    /// 生产服务器（nginx /vocab/ → FastAPI）
    static let apiBase = URL(string: "http://175.27.210.206/vocab")!
    static let appName = "词航"
    /// 本地状态文件名前缀（按账号分槽位，与 web 的 vocab_v1_u{id}/guest 对应）
    static let stateFilePrefix = "vocab_state"
}
