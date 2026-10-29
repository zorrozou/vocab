import Foundation

@main struct SharedPlanRegression {
    static func main() throws {
        let raw = #"{"account_id":"account-a","day":"2026-10-29","cap":100,"new_target":10,"configured_cap":100,"configured_new_per_day":10,"approved":["apple"],"over_limit":false,"requires_sync":false,"items":[{"word":"apple","kind":"learn","new_word":true,"probe_word":false,"completed":false,"from_pending":true,"probe_evidence_key":"p1_2026-10-29_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_","review_evidence_key":"r1_2026-10-29_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_"},{"word":"pear","kind":"probe","new_word":false,"probe_word":true,"completed":false,"from_pending":false,"probe_evidence_key":"p1_2026-10-29_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_","review_evidence_key":"r1_2026-10-29_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_"}]}"#
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
        var state = LearningState()
        let key = plan.items[0].probe_evidence_key
        precondition(StudyEngine.posteriorUpdate(&state,rank:5000,resp:1,guess:0.25,evidenceKey:key))
        let before = state
        precondition(!StudyEngine.posteriorUpdate(&state,rank:5000,resp:0,guess:0.25,evidenceKey:key))
        precondition(state == before && state.probeCount == 1)
        let encoded = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(LearningState.self,from:encoded)
        precondition(restored == state)
        var passive = LearningState()
        for i in 0..<6 {
            let id = "r1_2026-10-29_" + String(repeating:String(i),count:32) + "_"
            StudyEngine.posteriorUpdate(&passive,rank:5000,resp:1,weight:0.4,evidenceKey:id)
        }
        precondition(StudyEngine.passiveEvidenceWeight(passive,day:"2026-10-29") == 1.5)
        precondition(StudyEngine.passiveEvidenceWeight(passive,day:"2026-10-30") == 0)
        print("PASS iOS shared plan account/day binding, word permissions, malformed cache rejection and persistence round trip")
    }
}
