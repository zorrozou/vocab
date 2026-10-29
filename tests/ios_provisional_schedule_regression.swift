import Foundation

struct OfflineCase: Decodable {
    let card: CardState
    let configurations: [String: FsrsSchedulerConfig]
    let state: Int
    let step: Int?
    let due: String
}
@main struct ProvisionalRegression {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let cases = try JSONDecoder().decode([OfflineCase].self, from: data)
        for (index, fixture) in cases.enumerated() {
            guard let plan = StudyEngine.provisionalSchedule(fixture.card, configurations: fixture.configurations) else { fatalError("missing plan \(index)") }
            precondition(plan.state == fixture.state && plan.step == fixture.step, "phase \(index)")
            precondition(DayUtil.parseISO(plan.due) == DayUtil.parseISO(fixture.due), "due \(index)")
            var card = fixture.card
            StudyEngine.applyProvisionalSchedule(&card, configurations: fixture.configurations)
            precondition(DayUtil.parseISO(card.due) == DayUtil.parseISO(fixture.due))
            precondition(card.fsrs == fixture.card.fsrs && card.pendingFsrs == fixture.card.pendingFsrs)
        }
        print("PASS \(cases.count) iOS offline phase/step cases against official FSRS")
    }
}
