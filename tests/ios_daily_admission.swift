import Foundation

@main struct DailyAdmissionRegression {
    static func main() {
        let day = "2026-10-29"
        var s = LearningState(); s.settings.dailyCap = 3; s.settings.newPerDay = 1
        s.log = [LogEntry(d:day,word:"apple",rating:3,kind:"learn"),
                 LogEntry(d:day,word:"apple",rating:1,kind:"review"),
                 LogEntry(d:day,word:"pear",rating:3,kind:"review"),
                 LogEntry(d:day,word:"ignored",rating:3,kind:"exposure"),
                 LogEntry(d:"2026-10-28",word:"yesterday",rating:3,kind:"learn")]
        s.cards["book"] = CardState(due:"2000-01-01T00:00:00Z")
        s.cards["apple"] = CardState(due:"2000-01-01T00:00:00Z")
        func issue(_ word: String, _ kind: String, sessionDay: String = day) -> String? {
            StudyEngine.studyAdmissionIssue(s, word: word, kind: kind, sessionDay: sessionDay, day: day)
        }
        precondition(issue("book", "review") == nil)
        precondition(issue("book", "learn") != nil)
        precondition(issue("apple", "review", sessionDay:"2026-10-28") != nil)
        s.log.append(LogEntry(d:day,word:"book",rating:3,kind:"probe"))
        precondition(issue("fourth", "review") != nil)
        precondition(issue("fourth", "learn") != nil)
        precondition(issue("fourth", "probe") != nil)
        precondition(issue("apple", "review") == nil, "repeat learning steps must remain possible at capacity")
        s.settings.dailyCap = 100
        s.cards["apple"] = CardState(stage:2,due:nil,lt:0,pos:1,fsrs:nil)
        precondition(issue("apple", "learn") != nil)
        precondition(issue("apple", "probe") != nil)
        precondition(issue("book", "probe") != nil, "same-day probe evidence cannot be counted twice")
        s.log.append(contentsOf:[LogEntry(d:day,word:"x",rating:3,kind:"probe"),LogEntry(d:day,word:"y",rating:3,kind:"probe")])
        precondition(issue("fourth", "probe") != nil)
        print("PASS iOS grading rechecks day, distinct-word cap, new-word target and probe limit without blocking counted-word repeats")
    }
}
