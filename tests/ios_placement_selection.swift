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

struct RecognitionFixture: Decodable {
    struct Count: Decodable {let n,k:Int}
    let name:String
    let stats:[Count]
    let lower,upper,pointer:Int
    let mean:Double
}
@main struct PlacementSelectionCheck {
    static func main() throws {
        let cases=try JSONDecoder().decode([RecognitionFixture].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tests/recognition_fixtures.json")))
        for f in cases {
            var s=LearningState();s.recognitionEvidence=[:]
            for (b,c) in f.stats.enumerated() { for i in 0..<c.n {
                s.recognitionEvidence?["\(b)-\(i)"]=RecognitionEvent(word:"w\(b)-\(i)",pos:StudyEngine.placementBands[b].0+i,
                    at:String(format:"2026-11-05T01:%02d:%02dZ",b,i%60),correct:i<c.k,source:"placement",itemId:String(repeating:"a",count:64))
            }}
            let e=StudyEngine.recognitionEstimate(s)
            precondition(e.lower==f.lower && e.upper==f.upper && abs(e.mean-f.mean)<1e-6 && StudyEngine.placementPointer(s)==f.pointer,f.name)
            let roundtrip=try JSONDecoder().decode(LearningState.self,from:JSONEncoder().encode(s))
            precondition(roundtrip.recognitionEvidence==s.recognitionEvidence)
        }
        var s=LearningState(),seen=Set<Int>()
        for i in 0..<30 {
            let pool=StudyEngine.placementCandidatePool(s),pos=pool[pool.count/2]
            precondition(seen.insert(pos).inserted)
            let q=Quiz(word:"w\(pos)",pos:pos,options:[QuizOption(text:"yes",ok:true),QuizOption(text:"a",ok:false),QuizOption(text:"b",ok:false),QuizOption(text:"c",ok:false)],item_id:String(repeating:"a",count:64))
            StudyEngine.recordRecognition(&s,quiz:q,ok:i%2==0,source:"placement")
            StudyEngine.recordKnowledge(&s,word:q.word,pos:pos,ok:i%2==0,isPlacement:true)
            StudyEngine.posteriorUpdate(&s,rank:pos,resp:i%2==0 ? 1:0,guess:0.25)
            if i==17 {s=try JSONDecoder().decode(LearningState.self,from:JSONEncoder().encode(s))}
        }
        precondition(StudyEngine.recognitionCounts(s).map(\.n)==[5,5,5,5,5,5])
        precondition(StudyEngine.placementCandidatePool(s,excluding:Set(1...10987)).isEmpty)
        print("PASS Swift/Web recognition intervals, start positions, restart, coverage and unique questions")
    }
}
