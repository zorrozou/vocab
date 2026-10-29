import Foundation
struct APIClient { struct FsrsIn: Codable, Equatable {} }
@main struct QuizIdentityRegression {
    static func main() {
        var quiz = Quiz(word: "apple", pos: 100, options: [QuizOption(text: "苹果", ok: true), QuizOption(text: "梨", ok: false), QuizOption(text: "桃", ok: false), QuizOption(text: "李", ok: false)])
        precondition(quiz.matches(word: "Apple"))
        precondition(!quiz.matches(word: "pear"))
        quiz.options[1].ok = true
        precondition(!quiz.matches(word: "apple"))
        quiz.options[1].ok = false
        quiz.options[1].text = " "
        precondition(!quiz.matches(word: "apple"))
        print("PASS iOS quiz word identity and answer validity")
    }
}
