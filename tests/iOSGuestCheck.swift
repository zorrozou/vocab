import Foundation
enum Config { static let apiBase: URL? = URL(string: "http://127.0.0.1:18765") }
@main struct IOSGuestCheck {
    static func main() async throws {
        let defaults = UserDefaults.standard, key = "vocab_guest_credential_v1"
        let previous = defaults.string(forKey: key)
        defaults.removeObject(forKey: key)
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        let api = APIClient.shared
        let prefix = UUID().uuidString.lowercased()
        let one = APIClient.PersonalizeIn(device: "public-device", date: "2026-10-27", weak_words: ["apple"], learned_max_pos: 5000, sync: true, request_id: "a-" + prefix)
        let two = APIClient.PersonalizeIn(device: "public-device", date: "2026-10-27", weak_words: ["apple"], learned_max_pos: 5000, sync: true, request_id: "b-" + prefix)
        async let first = api.personalize(one, enforceSession: true)
        async let second = api.personalize(two, enforceSession: true)
        let (_, _) = try await (first, second)
        guard let token = defaults.string(forKey: key), token.count == 64 else { fatalError("credential not stored") }
        _ = try await api.personalizedJob(id: one.request_id!, device: one.device, enforceSession: true)
        print("PASS iOS guest concurrent credential creation, persistence and HTTP jobs")
    }
}
