import Foundation

// The scheduler only needs the API request value type for this standalone test.
enum APIClient {
    struct FsrsIn: Codable, Equatable {
        var is_new: Bool = false
        var state: Int = 1
        var stability: Double = 0
        var difficulty: Double = 0
        var due: String? = nil
        var rating: Int = 3
        var step: Int? = nil
        var last_review: String? = nil
        var legacy_last_review_day: String? = nil
        var now: String? = nil
        var deterministic: Bool? = nil
        var scheduler_key: String? = nil
    }
}

struct SelectionCase: Decodable {
    let name: String
    let probeCount, gridIndex: Int
    let used: [Int]
    let excludedRanges: [[Int]]
    let low, high: Int?
    let count: Int
    let ceiling: Bool
}
@main struct PlacementSelectionCheck {
    static func main() throws {
        let cases = try JSONDecoder().decode([SelectionCase].self, from: Data(contentsOf: URL(fileURLWithPath:"tests/placement_selection_fixtures.json")))
        for c in cases {
            var s=LearningState();s.posterior=Array(repeating:0,count:49);s.posterior?[c.gridIndex]=1
            for pos in c.used {StudyEngine.recordKnowledge(&s,word:"word-\(pos)",pos:pos,ok:true,isPlacement:true)}
            s.probeCount=c.probeCount
            let excluded=Set(c.excludedRanges.flatMap { Array($0[0]...$0[1]) })
            let pool=StudyEngine.placementCandidatePool(s,excluding:excluded)
            precondition(pool.count==c.count && pool.first==c.low && pool.last==c.high,c.name)
            precondition(StudyEngine.placementAtCeiling(s)==c.ceiling,c.name)
        }
        for correct in [true,false] {
            var s=LearningState(),seen=Set<Int>()
            for i in 0..<30 {
                let pool=StudyEngine.placementCandidatePool(s),pos=pool[pool.count/2]
                precondition(seen.insert(pos).inserted)
                StudyEngine.recordKnowledge(&s,word:"word-\(pos)",pos:pos,ok:correct,isPlacement:true)
                StudyEngine.posteriorUpdate(&s,rank:pos,resp:correct ? 1:0,guess:0.25)
                if i==16 {s=try JSONDecoder().decode(LearningState.self,from:JSONEncoder().encode(s))}
            }
            precondition(seen.count==30 && s.probeCount==30)
        }
        print("PASS Swift placement limits, persisted exclusions, exhausted windows and 30 unique all-correct/all-wrong answers")
    }
}
