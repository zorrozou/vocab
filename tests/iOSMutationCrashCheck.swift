import Foundation
import Darwin

enum Config {
    static let apiBase: URL? = {
        let url = URL(string: ProcessInfo.processInfo.environment["VOCAB_TEST_BASE"] ?? "http://127.0.0.1:18765")!
        guard url.scheme == "http", url.host == "127.0.0.1", url.port != nil else { fatalError("fixture must use loopback") }
        return url
    }()
}
@main struct MutationCrashCheck {
    static func fixture(_ name: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: Config.apiBase!.appendingPathComponent("api/v1/__ui_fixture/" + name))
        if let body { req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError(message: "fixture failed") }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func main() async throws {
        let api = APIClient.shared
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--child" {
            let dir = URL(fileURLWithPath: CommandLine.arguments[2]), account = CommandLine.arguments[3], mode = CommandLine.arguments[4]
            let token = ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"]!
            await api.setToken(token)
            let remote = try await api.pullState(expectedToken: token)
            let coordinator = DeltaSyncCoordinator(directory: dir, api: api)
            if mode == "restore" {
                _ = try await coordinator.restoreAndClear(account: account, token: token, state: remote.state!, expectedUpdatedAt: remote.updated_at,
                    revision: remote.state_revision, generation: remote.sync_generation, archiveDirectory: dir)
            } else {
                _ = try await coordinator.checkpointAndClear(account: account, token: token, expectedUpdatedAt: remote.updated_at!,
                    revision: remote.state_revision, generation: remote.sync_generation, archiveDirectory: dir)
            }
            fatalError("held response unexpectedly returned")
        }
        let user = try await api.register(username: "cr_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased(), password: "test_password_123", nickname: "")
        let token = user.token, account = user.user.account_id!
        await api.setToken(token)
        var state = LearningState()
        state.cards["apple"] = CardState(stage: 1, due: nil, lt: nil, pos: 1, fsrs: nil)
        try await api.pushState(state, expectedToken: token)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-mutation-crash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DeltaStateStore(directory: dir, accountID: account), coordinator = DeltaSyncCoordinator(directory: dir, api: api)
        for mode in ["restore", "checkpoint"] {
            let before = try await api.pullState(expectedToken: token)
            let original = try store.rawRecord()
            if mode == "restore" { precondition(original == nil) } else { precondition(original != nil) }
            _ = try await fixture("mutation-hold-response", ["mode":mode])
            let child = Process(); child.executableURL = Bundle.main.executableURL!.standardizedFileURL
            child.arguments = ["--child", dir.path, account, mode]
            child.environment = ProcessInfo.processInfo.environment.merging(["VOCAB_FIXTURE_TOKEN":token]) { _, new in new }
            try child.run()
            defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
            var held = false
            for _ in 0..<400 {
                if try await fixture("mutation-hold-status")["started"] as? Bool == true { held = true; break }
                if !child.isRunning { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            precondition(held, "server did not commit held mutation")
            let after = try await api.pullState(expectedToken: token)
            precondition(after.state_revision != before.state_revision && after.state?.cards["apple"] != nil)
            kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
            _ = try await fixture("mutation-release-response", [:])
            if mode == "restore" {
                let missing = try store.hasMissingRecord(); precondition(missing)
                do { try await coordinator.push(account: account, token: token, target: state); fatalError("unguarded upload") } catch { }
                let stillMissing = try store.hasMissingRecord(); precondition(stillMissing)
                try store.archivePendingAndClear(to: dir, allowMissingRecord: true)
                state = after.state!
                try await coordinator.prime(account: account, token: token, remote: after, local: state)
            } else {
                let intact = try store.rawRecord(); precondition(intact == original)
                do { try await coordinator.push(account: account, token: token, target: state); fatalError("stale baseline uploaded") } catch { }
                let protected = try store.load()!; precondition(protected.restore_epoch != after.state!.restoreEpoch)
                let unchangedServer = try await api.pullState(expectedToken: token)
                precondition(unchangedServer.state_revision == after.state_revision)
            }
        }
        print("PASS iOS killed after server restore and checkpoint commit retains upload fences")
    }
}
