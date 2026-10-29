import Foundation

@main struct SharedPlanRegression {
    static func main() throws {
        let raw = #"{"account_id":"account-a","day":"2026-10-29","cap":100,"new_target":10,"configured_cap":100,"configured_new_per_day":10,"approved":["apple"],"over_limit":false,"requires_sync":false,"items":[{"word":"apple","kind":"learn","new_word":true,"probe_word":false,"completed":false,"from_pending":true},{"word":"pear","kind":"probe","new_word":false,"probe_word":true,"completed":false,"from_pending":false}]}"#
        let plan = try JSONDecoder().decode(SharedStudyPlan.self, from: Data(raw.utf8))
        precondition(plan.valid(account:"account-a",day:"2026-10-29"))
        precondition(!plan.valid(account:"account-b",day:"2026-10-29"))
        precondition(!plan.valid(account:"account-a",day:"2026-10-30"))
        precondition(plan.permits(word:"apple",kind:"learn") && plan.permits(word:"apple",kind:"review"))
        precondition(!plan.permits(word:"apple",kind:"probe"))
        precondition(plan.permits(word:"pear",kind:"probe") && !plan.permits(word:"pear",kind:"learn"))
        precondition(!plan.permits(word:"unreserved",kind:"review"))
        var duplicate = plan; duplicate.items.append(plan.items[0])
        precondition(!duplicate.valid(account:"account-a",day:"2026-10-29"))
        var malformed = plan; malformed.configured_cap = -1
        precondition(!malformed.valid(account:"account-a",day:"2026-10-29"))
        let roundTrip = try JSONDecoder().decode(SharedStudyPlan.self, from: JSONEncoder().encode(plan))
        precondition(roundTrip == plan)
        print("PASS iOS shared plan account/day binding, word permissions, malformed cache rejection and persistence round trip")
    }
}
