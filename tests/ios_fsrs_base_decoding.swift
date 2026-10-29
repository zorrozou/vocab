import Foundation

@main struct FsrsBaseDecodingRegression {
    static func main() throws {
        // These are the actual compact request shapes emitted by Web's learn/review.
        let bases = [
            #"{"is_new":true,"rating":3}"#,
            #"{"state":2,"stability":8,"difficulty":5,"due":"2026-10-29T00:00:00Z","rating":1}"#,
            #"{"is_new":false,"state":2,"stability":200,"difficulty":5}"#
        ]
        do {
            for base in bases {
                let data = Data("""
                {"cards":{"apple":{"pos":1,"pendingFsrs":{"base":\(base),"events":[{"id":"pending","rating":1,"at":"2026-10-29T00:00:00Z"}]},"fsrsHistory":{"base":\(base),"events":[{"id":"pending","rating":1,"at":"2026-10-29T00:00:00Z"}]}}}}
                """.utf8)
                let state = try JSONDecoder().decode(LearningState.self, from: data)
                let card = state.cards["apple"]!
                precondition(card.pendingFsrs?.events.first?.id == "pending")
                precondition(card.fsrsHistory == card.pendingFsrs)
                let roundTrip = try JSONDecoder().decode(LearningState.self, from: JSONEncoder().encode(state))
                precondition(roundTrip == state)
                let schedule = StudyEngine.provisionalSchedule(card)!
                precondition(schedule.state == (card.pendingFsrs!.base.is_new ? 1 : 3))
            }
            for bad in [#"{"is_new":"true"}"#, #"{"state":"two"}"#] {
                do {
                    _ = try JSONDecoder().decode(APIClient.FsrsIn.self, from: Data(bad.utf8))
                    preconditionFailure("wrong field types must still be rejected")
                } catch {}
            }
            print("PASS iOS reads compact Web FSRS bases without dropping pending events or history")
        } catch {
            fputs("FAIL compact FSRS base: \(error)\n", stderr)
            exit(1)
        }
    }
}
