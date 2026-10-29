import Foundation
struct APIClient { struct FsrsIn: Codable, Equatable {} }
@main struct ShadowScoreRegression {
    static func main() {
        let cases: [(String, String, Int)] = [
            ("I know that I know.","I know",40), ("I know that I know.","I know that I know",100),
            ("one two three","one two",67), ("one two","one one one",50),
            ("one two","",0), ("...","anything",0), ("Don't stop.","don't stop",100)
        ]
        for (target, recognized, expected) in cases {
            precondition(shadowCompleteness(target:target, recognized:recognized) == expected)
        }
        print("PASS iOS shadow completeness repetitions, empty input and rounding")
    }
}
