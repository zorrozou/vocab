import Foundation

struct APIClient { struct FsrsIn: Codable, Equatable {} }

@main struct SentenceSwapRegression {
    static func main() {
        let a = SentenceItem(tier: 1, text: "first", zh: nil)
        let b = SentenceItem(tier: 2, text: "second", zh: nil)
        let c = SentenceItem(tier: 3, text: "third", zh: nil)
        let fresh = SentenceItem(tier: 2, text: "replacement", zh: nil)
        precondition([a, b, c].firstAlternative(excluding: [a.text, b.text, c.text]) == nil, "visible sentences are not alternatives")
        precondition([a, b, c, fresh].firstAlternative(excluding: [a.text, b.text, c.text]) == fresh, "a distinct alternative should be available")
        var rows = [a, b, c]
        rows.replaceSentence(a, with: nil)
        rows.replaceSentence(c, with: fresh)
        precondition(rows == [b, fresh], "concurrent swap changed the wrong sentence")
        rows.replaceSentence(a, with: fresh)
        rows.replaceSentence(c, with: nil)
        precondition(rows == [b, fresh], "stale completion modified current rows")
        rows.removeAll()
        rows.replaceSentence(c, with: nil)
        precondition(rows.isEmpty, "stale removal after refresh must be harmless")
        print("PASS concurrent and stale iOS sentence swaps")
    }
}
