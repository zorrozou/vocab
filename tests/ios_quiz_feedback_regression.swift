import Foundation

struct APIClient { struct FsrsIn: Codable, Equatable {} }

@main struct QuizFeedbackRegression {
    @MainActor static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        fatalError("quiz feedback did not settle")
    }

    @MainActor static func main() async {
        var gates: [CheckedContinuation<Void, Never>] = []
        var commits: [Bool] = []
        let feedback = QuizAnswerFeedback(wait: {
            await withCheckedContinuation { gates.append($0) }
        })
        feedback.choose(0, correct: false) { commits.append($0) }
        feedback.choose(1, correct: true) { commits.append($0) }
        await settle { gates.count == 1 }
        precondition(feedback.picked == 0, "double selection must not replace a pending answer")
        feedback.cancel() // navigation, account change or replacement question
        feedback.choose(2, correct: true) { commits.append($0) }
        await settle { gates.count == 2 }
        gates[0].resume()
        try? await Task.sleep(nanoseconds: 20_000_000)
        precondition(commits.isEmpty && feedback.picked == 2, "old answer affected the replacement question")
        gates[1].resume()
        await settle { commits == [true] }
        precondition(feedback.picked == nil)

        let leaving = QuizAnswerFeedback(wait: { try await Task.sleep(nanoseconds: 20_000_000) })
        leaving.choose(1, correct: false) { commits.append($0) }
        leaving.cancel()
        try? await Task.sleep(nanoseconds: 40_000_000)
        precondition(commits == [true], "leaving a question must cancel delayed delivery")
        print("PASS delayed quiz answers, double taps, cancellation and replacement question")
    }
}
