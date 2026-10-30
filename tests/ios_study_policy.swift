import Foundation
struct PolicyCase: Decodable { let name: String; let card: CardState; let mastered: Bool }
@main struct PolicyCheck {
    static func main() throws {
        let cases = try JSONDecoder().decode([PolicyCase].self, from: Data(contentsOf: URL(fileURLWithPath: "tests/study_policy_fixtures.json")))
        for c in cases { precondition(StudyEngine.isMastered(c.card) == c.mastered, c.name) }
        var s = LearningState(); let day = DayUtil.today()
        s.log = (0..<10).flatMap { i in [LogEntry(d:day,word:"new\(i)",rating:3,kind:"learn"),LogEntry(d:day,word:"new\(i)",rating:3,kind:"review")] }
        s.log += (0..<90).map { LogEntry(d:day,word:"old\($0)",rating:3,kind:"review") }
        let counts = StudyEngine.dailyCounts(s,day:day)
        precondition(counts.total == 100 && counts.learn == 10 && counts.review == 90 && counts.attempts == 110)
        s.log = [];s.newSupply = NewSupply(revision:"fixture",start:1,end:2,available:[])
        precondition(StudyEngine.dailyPlanSummary(s,day:day,now:Date()).newPlanned == 0)
        let config = FsrsSchedulerConfig(library:"fsrs-6.3.2",parameters:Array(repeating:1,count:21),desired_retention:0.9,learning_steps:[],relearning_steps:[],maximum_interval:36500)
        var card = CardState(); card.fsrs = FsrsState(state:2,stability:1,difficulty:5,due:nil,scheduled_days:nil,step:nil,lastReview:nil); card.schedulerKey = "custom"
        let probability = StudyEngine.retrievability(card,elapsedDays:20,configurations:["custom":config])
        precondition(abs(probability - 1.0/(1.0+(1.0/0.9-1.0)*20)) < 1e-12)
        print("PASS \(cases.count) Swift mastery fixtures, exclusive counts and vocabulary exhaustion")
    }
}
