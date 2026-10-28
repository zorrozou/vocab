import Foundation
enum Config { static let apiBase: URL? = URL(string: "http://127.0.0.1:18767") }
@main struct PasswordCheck {
    static func main() async throws {
        let api=APIClient.shared
        let username="ip_"+UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(10).lowercased()
        let first=try await api.register(username:username,password:"test_password_123",nickname:"")
        do { _=try await api.login(username:username,password:"wrong");fatalError("wrong password accepted") }
        catch let error as APIError { precondition(error.statusCode == 401) }
        let again=try await api.login(username:username.uppercased(),password:"test_password_123")
        precondition(first.user.account_id == again.user.account_id)
        await api.setToken(again.token)
        try await api.pushState(LearningState(),expectedToken:again.token)
        let saved=try await api.pullState(expectedToken:again.token)
        precondition(saved.state != nil)
        print("PASS iOS registration, incorrect password, login and authenticated state over HTTP")
    }
}
