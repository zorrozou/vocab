import Foundation

enum Config {
    static let apiBase: URL? = {
        let url = URL(string: ProcessInfo.processInfo.environment["VOCAB_TEST_BASE"] ?? "http://127.0.0.1:18765")!
        guard url.scheme == "http", url.host == "127.0.0.1", url.port != nil else { fatalError("fixture must use loopback") }
        return url
    }()
}
@main struct LegacyDateCheck {
    static func main() async throws {
        let token = ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"]!
        let api = APIClient.shared
        await api.setToken(token)
        let remote = try await api.pullState(expectedToken: token)
        let state = remote.state!
        precondition(state.cards["apple"]?.due == "2020-01-01")
        precondition(StudyEngine.dailyPlanSummary(state, day: DayUtil.today(), now: Date()).dueAvailable == 1)
        try await api.pushState(state, expectedToken: token)
        let confirmed = try await api.pullState(expectedToken: token)
        precondition(confirmed.state?.cards["apple"]?.due == "2020-01-01")
        print("PASS iOS reads and preserves Web date-only due card")
    }
}
