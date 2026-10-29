import Foundation

@main struct DelayedEvidenceRegression {
    static func main() {
        let now = DayUtil.parseISO("2026-10-29T04:00:00Z")!
        var s = LearningState()
        s.cards["x"] = CardState(pos: 7000, fsrs: FsrsState(state: 2, stability: 30, difficulty: 5,
            due: nil, scheduled_days: nil, step: nil, lastReview: "2026-10-28T04:00:00Z"))
        func check(_ expected: Bool, _ label: String) {
            precondition(StudyEngine.delayedReviewEvidence(s, word: "x", now: now) == expected, label)
        }
        check(true, "24 hours")
        s.cards["x"]?.fsrs?.lastReview = "2026-10-28T04:00:00.001Z"
        check(false, "less than 24 hours")
        s.cards["x"]?.fsrs?.lastReview = "2020-01-01T00:00:00Z"
        let pending = PendingFsrs(base: APIClient.FsrsIn(rating:3), events: [PendingFsrsEvent(id:"recent",rating:3,at:"2026-10-29T03:59:00Z")])
        s.cards["x"]?.pendingFsrs = pending; check(false, "offline practice")
        s.cards["x"]?.pendingFsrs = nil; s.cards["x"]?.fsrsHistory = pending; check(false, "history practice")
        s.cards["x"]?.fsrsHistory = nil
        s.log = [LogEntry(d: "2026-10-28", word: "x", rating: 3, kind: "review")]
        check(false, "legacy date cannot imply a full day")
        s.log[0].d = "2026-10-27"; check(true, "older legacy date")
        s.log[0].ts = "2026-10-28T03:00:00Z"
        s.log[0].d = DayUtil.localDay(DayUtil.parseISO(s.log[0].ts)!)
        check(true, "precise log retained")
        s.log[0].ts = "2026-10-28T05:00:00Z"
        s.log[0].d = DayUtil.localDay(DayUtil.parseISO(s.log[0].ts)!)
        check(false, "precise recent log")
        s.log = []; s.cards["x"]?.fsrs = nil; check(false, "unknown age")
        s.cards["x"]?.pendingFsrs = pending
        s.cards["x"]?.pendingFsrs?.events[0].at = "2030-01-01T00:00:00Z"; check(false, "future clock")
        print("PASS iOS delayed evidence: exact 24-hour boundary, pending/history/log precedence, conservative legacy dates and future clocks")
    }
}
