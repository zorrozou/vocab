import Foundation

// Compile together with ios/VocabApp/Models.swift; pass a local day and UTC instant.
// Models refers to this API type; the test exercises the production DayUtil.
struct APIClient { struct FsrsIn: Codable, Equatable {} }

@main struct LocalNoonRegression {
    static func main() {
        let iso = ISO8601DateFormatter()
        let args = CommandLine.arguments
        guard args.count == 3, let expected = iso.date(from: args[2]),
              let actual = DayUtil.localNoon(args[1]) else { fatalError("invalid test date") }
        precondition(actual == expected, "local noon does not match expected instant")
        precondition(DayUtil.localNoon("2026-02-30") == nil, "invalid date must be rejected")
        var state = LearningState()
        state.log = [LogEntry(d:"2026-10-26", word:"apple", rating:3, kind:"learn"),
                     LogEntry(d:"2026-10-29", word:"apple", rating:3, kind:"exposure", source:"audio")]
        precondition(state.lastStudyDay(for:"apple") == "2026-10-26", "audio exposure changed the last study day")
        state.log.removeFirst()
        precondition(state.lastStudyDay(for:"apple") == nil, "exposure alone created a study history")
        print("PASS local noon matches the configured timezone")
    }
}
