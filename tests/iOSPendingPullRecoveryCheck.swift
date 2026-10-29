import Foundation

enum Config {
    static let apiBase: URL? = {
        let value = ProcessInfo.processInfo.environment["VOCAB_TEST_BASE"] ?? "http://127.0.0.1:18765"
        guard let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
              url.user == nil, url.password == nil, url.path.isEmpty || url.path == "/" else { fatalError("loopback only") }
        return url
    }()
}

@main struct PendingPullRecoveryCheck {
    static func check(_ value: Bool) { precondition(value) }
    static func object(_ data: Data) throws -> [String: DeltaJSON] {
        guard case .object(let value) = try StateDelta.decode(data) else { fatalError("object expected") }
        return value
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-pull-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let api = APIClient.shared
        let requested = Array(CommandLine.arguments.dropFirst())
        let modes = requested.isEmpty ? ["manual", "automatic", "restart"] : requested
        for mode in modes {
            check(["manual", "automatic", "installed", "restart", "restore", "disk", "conflict"].contains(mode))
            let auth = try await api.register(username: "pull_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased(),
                password: "isolated_test_123", nickname: "")
            let account = auth.user.account_id!, token = auth.token
            await api.setToken(token)
            var initial = LearningState()
            initial.cards["apple"] = CardState(stage: 1, due: nil, lt: nil, pos: 1, fsrs: nil)
            try await api.pushState(initial, expectedToken: token)
            let first = try await api.pullState(expectedToken: token)
            let directory = root.appendingPathComponent(mode).appendingPathComponent("VocabDelta")
            let coordinator = DeltaSyncCoordinator(directory: directory)
            let store = DeltaStateStore(directory: directory, accountID: account)
            try await coordinator.prime(account: account, token: token, remote: first, local: initial)
            let baseline = try store.load()!
            var remote = first.state!
            remote.cards["pear"] = CardState(stage: 1, due: nil, lt: nil, pos: 2, fsrs: nil)
            try await api.pushState(remote, expectedToken: token)
            let downloaded = try await api.pullState(expectedToken: token)
            let stored = try await api.storedStateSnapshot(expectedRevision: downloaded.state_revision!,
                generation: downloaded.sync_generation!, expectedToken: token)
            let envelope = try object(stored.payload)
            guard case .object(let server)? = envelope["state"] else { fatalError("state missing") }
            let previous = try JSONEncoder().encode(initial), target = try JSONEncoder().encode(downloaded.state!)
            try store.stagePull(PendingStatePull(revision: stored.revision, server: server, previous: previous, target: target))
            let interrupted = try store.rawRecord()!
            var local = mode == "installed" ? downloaded.state! : initial
            // A background example job completed after the download was staged.
            local.personalized["apple"] = PersonalizedSentence(text: "The local example must survive.")
            let localBytes = try JSONEncoder().encode(local)
            if mode == "restore" {
                _ = try await api.checkpointState(expectedUpdatedAt: downloaded.updated_at!, revision: downloaded.state_revision,
                    generation: downloaded.sync_generation, expectedToken: token)
                do { try await coordinator.push(account: account, token: token, target: local); fatalError("restore fence ignored") }
                catch let error as APIError { check(error.statusCode == 409 || error.statusCode == 410) }
                check(try store.rawRecord() == interrupted)
                continue
            }
            if mode == "disk" {
                let parent = directory.deletingLastPathComponent()
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
                do { try store.switchPullToMerge(target: localBytes); fatalError("archive failure ignored") } catch {}
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
                check(try store.rawRecord() == interrupted)
            }
            if mode == "automatic" {
                let resumed = try await coordinator.resumePull(account: account, token: token, local: local) { _, _ in
                    fatalError("stale download installed over newer local example")
                }
                check(!resumed)
                check(try store.load()?.pending?.merge == true)
            }
            if mode == "restart" {
                try store.switchPullToMerge(target: localBytes)
                let recovered = DeltaSyncCoordinator(directory: directory)
                try await recovered.push(account: account, token: token, target: local)
            } else if mode == "conflict" {
                // An unrelated restore epoch must not replace the download record.
                var bad = local
                bad.restoreEpoch = 1
                do { try await coordinator.push(account: account, token: token, target: bad); fatalError("epoch mismatch accepted") } catch {}
                check(try store.rawRecord() == interrupted)
                try await coordinator.push(account: account, token: token, target: local)
            } else {
                try await coordinator.push(account: account, token: token, target: local)
            }
            let after = try store.load()!
            check(after.pull == nil && after.pending == nil && after.revision != baseline.revision)
            let merged = try await api.pullState(expectedToken: token)
            check(merged.state?.cards["apple"] != nil && merged.state?.cards["pear"] != nil)
            check(merged.state?.personalized["apple"]?.text == "The local example must survive.")
            let archives = try FileManager.default.contentsOfDirectory(at: directory.deletingLastPathComponent(),
                includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("unverified-a") }
            let values = try archives.map { try object(Data(contentsOf: $0)) }
            let expectedViews = try [previous, target, localBytes].map(object)
            check(expectedViews.allSatisfy { values.contains($0) })
            // A retry after successful reconciliation does not duplicate uploads.
            try await coordinator.push(account: account, token: token, target: local)
            check(try store.load()?.revision == after.revision)
        }
        print("PASS interrupted native download recovery: " + modes.joined(separator: ", "))
    }
}
