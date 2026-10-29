import Foundation

@main
struct ConfigCheck {
    static func main() {
        precondition(Config.validatedAPIBase("https://example.com/vocab", requireHTTPS: true) != nil)
        precondition(Config.validatedAPIBase("http://example.com/vocab", requireHTTPS: true) == nil)
        precondition(Config.validatedAPIBase("http://127.0.0.1:8000", requireHTTPS: false) != nil)
        precondition(Config.validatedAPIBase("https://user:pass@example.com/vocab", requireHTTPS: true) == nil)
        precondition(Config.validatedAPIBase("https://example.com/vocab?token=x", requireHTTPS: true) == nil)
        precondition(Config.releaseAPIBase("http://175.27.210.206/vocab") == nil)
        precondition(Config.releaseAPIBase("http://175.27.210.206:80/vocab") == nil)
        precondition(Config.releaseAPIBase("http://example.com/vocab") == nil)
        precondition(Config.releaseAPIBase("https://example.com/vocab") != nil)
        #if DEBUG
        if ProcessInfo.processInfo.environment["VOCAB_UI_TEST_API"] == "http://127.0.0.1:18765" {
            precondition(Config.apiBase?.absoluteString == "http://127.0.0.1:18765")
        } else {
            precondition(Config.apiBase?.absoluteString == "https://175.27.210.206/vocab")
        }
        #else
        precondition(Config.apiBase?.absoluteString == "https://175.27.210.206/vocab")
        #endif
        print("PASS configured API URL validation and build-mode defaults")
    }
}
