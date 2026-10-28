import Foundation

// The integration test uses an isolated local service, never the production URL.
enum Config {
    static let apiBase: URL? = {
        let value = ProcessInfo.processInfo.environment["VOCAB_TEST_BASE"] ?? "http://127.0.0.1:18765"
        guard let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1",
              url.port != nil, (url.path.isEmpty || url.path == "/"), url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil else { fatalError("Test service must use an explicit loopback HTTP port") }
        return url
    }()
}

@main
struct IOSRestoreCheck {
    static func main() async throws {
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--stage-pull" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let account = CommandLine.arguments[3], localFile = URL(fileURLWithPath: CommandLine.arguments[4])
            guard let token = ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing fixture token") }
            let local = try JSONDecoder().decode(LearningState.self, from: Data(contentsOf: localFile))
            await APIClient.shared.setToken(token)
            let coordinator = DeltaSyncCoordinator(directory: directory)
            _ = try await coordinator.readAndApply(account: account, token: token, local: local) { _, target in
                try JSONEncoder().encode(target).write(to: localFile, options: .atomic)
                Thread.sleep(forTimeInterval: 60) // parent terminates after the local write
            }
            return
        }
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--submit-pending" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let store = DeltaStateStore(directory: directory, accountID: CommandLine.arguments[3])
            guard let pending = try store.load()?.pending,
                  let token = ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing pending fixture") }
            await APIClient.shared.setToken(token)
            _ = try await APIClient.shared.submitStateDelta(pending.batch, expectedToken: token)
            return
        }
        let api = APIClient.shared
        let username = "ir_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
        let auth = try await api.register(username: username, password: "test_password_123", nickname: "")
        await api.setToken(auth.token)
        do {
            try await api.pushState(LearningState(), expectedToken: "old-session-token")
            fatalError("stale session unexpectedly uploaded")
        } catch let error as APIError {
            precondition(error.message.contains("账号已切换"))
        }
        do {
            _ = try await api.fsrsReview(.init(is_new: true), expectedToken: nil, enforceSession: true)
            fatalError("stale guest session unexpectedly used a logged-in token")
        } catch let error as APIError {
            precondition(error.message.contains("账号已切换"))
        }
        await api.clearToken(ifMatches: "old-session-token")
        let currentToken = await api.token
        precondition(currentToken == auth.token)
        var initial = LearningState()
        initial.cards["apple"] = CardState(stage: nil, due: nil, lt: nil, pos: 1, fsrs: nil)
        try await api.pushState(initial)
        let old = try await api.pullState()
        precondition(old.state_revision != nil && old.sync_generation?.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil)
        let review = try await api.fsrsReview(.init(is_new: true, deterministic: true), expectedToken: auth.token)
        let schedulerKey = review.schedulerKey!
        let resolved = try await api.resolveSchedulerBackups(keys: [schedulerKey, String(repeating: "0", count: 64)], generation: old.sync_generation!, expectedToken: auth.token)
        precondition(resolved[schedulerKey] == review.schedulerConfig && resolved.count == 1)
        var schedulerState = initial
        schedulerState.cards["apple"]?.fsrsReplayVersions = ["event": schedulerKey]
        let schedulerReady = try await api.resolveIncrementalSchedulers(schedulerState, generation: old.sync_generation!, expectedToken: auth.token)
        precondition(schedulerReady.fsrsSchedulers?[schedulerKey] == review.schedulerConfig)
        var conflictingConfig = review.schedulerConfig!
        conflictingConfig.maximum_interval += 1
        schedulerState.fsrsSchedulers = [schedulerKey: conflictingConfig]
        do {
            _ = try await api.resolveIncrementalSchedulers(schedulerState, generation: old.sync_generation!, expectedToken: auth.token)
            fatalError("conflicting scheduler unexpectedly accepted")
        } catch is APIError { }
        schedulerState.fsrsSchedulers = nil
        schedulerState.cards["apple"]?.fsrsReplayVersions = ["event": String(repeating: "0", count: 64)]
        do {
            _ = try await api.resolveIncrementalSchedulers(schedulerState, generation: old.sync_generation!, expectedToken: auth.token)
            fatalError("missing scheduler unexpectedly accepted")
        } catch is APIError { }
        let baseline = try await api.storedStateSnapshot(expectedRevision: old.state_revision!, generation: old.sync_generation!, expectedToken: auth.token)
        let raw = try JSONSerialization.jsonObject(with: baseline.payload) as! [String: Any]
        let rawCards = (raw["state"] as! [String: Any])["cards"] as! [String: Any]
        precondition(rawCards["apple"] != nil && baseline.restoreEpoch == 0)
        let otherGeneration = old.sync_generation! == String(repeating: "0", count: 32) ? String(repeating: "1", count: 32) : String(repeating: "0", count: 32)
        do {
            _ = try await api.restoreState(initial, expectedUpdatedAt: old.updated_at, revision: old.state_revision, generation: otherGeneration, expectedToken: auth.token)
            fatalError("stale-generation restore unexpectedly succeeded")
        } catch let error as APIError { precondition(error.statusCode == 409) }
        do {
            _ = try await api.checkpointState(expectedUpdatedAt: old.updated_at!, revision: old.state_revision, generation: otherGeneration, expectedToken: auth.token)
            fatalError("stale-generation checkpoint unexpectedly succeeded")
        } catch let error as APIError { precondition(error.statusCode == 409) }
        do {
            _ = try await api.storedStateSnapshot(expectedRevision: old.state_revision!, generation: otherGeneration, expectedToken: auth.token)
            fatalError("snapshot unexpectedly accepted a different database generation")
        } catch let error as APIError {
            precondition(error.message.contains("同步版本"))
        }
        do {
            _ = try await api.storedStateSnapshot(expectedRevision: old.state_revision!, generation: old.sync_generation!, expectedToken: "old-session-token")
            fatalError("stale session unexpectedly read a snapshot")
        } catch let error as APIError {
            precondition(error.message.contains("账号已切换"))
        }
        var newer = initial
        newer.cards["banana"] = CardState(stage: nil, due: nil, lt: nil, pos: 2, fsrs: nil)
        try await api.pushState(newer)
        let current = try await api.pullState()
        precondition(current.state_revision != old.state_revision && current.sync_generation == old.sync_generation)
        do {
            _ = try await api.storedStateSnapshot(expectedRevision: old.state_revision!, generation: old.sync_generation!, expectedToken: auth.token)
            fatalError("snapshot unexpectedly accepted a stale revision")
        } catch let error as APIError {
            precondition(error.message.contains("同步版本"))
        }
        var backup = LearningState()
        backup.cards["cherry"] = CardState(stage: nil, due: nil, lt: nil, pos: 3, fsrs: nil)
        do {
            _ = try await api.restoreState(backup, expectedUpdatedAt: old.updated_at)
            fatalError("stale restore unexpectedly succeeded")
        } catch let error as APIError {
            precondition(error.message.contains("已变化"))
        }
        let result = try await api.restoreState(backup, expectedUpdatedAt: current.updated_at)
        precondition(result.state?.restoreEpoch == 1 && result.state?.cards["cherry"] != nil)
        let archived = try await api.stateBackups()
        precondition(archived.backups.count == 1)
        let previous = try await api.stateBackup(id: archived.backups[0].id)
        precondition(previous.state?.cards["apple"] != nil && previous.state?.cards["banana"] != nil)
        do {
            try await api.pushState(newer)
            fatalError("stale client unexpectedly overwrote restored state")
        } catch let error as APIError {
            precondition(error.message.contains("恢复"))
        }
        let final = try await api.pullState()
        precondition(final.state?.cards["cherry"] != nil && final.state?.cards["banana"] == nil)
        var versioned = final.state!
        versioned.personalized["apple"] = PersonalizedSentence(text: "Earlier sentence", recall: nil, zh: nil)
        versioned.personalVersions = ["apple": PersonalVersion(counter: 1, device: "ios-test", deleted: false)]
        try await api.pushState(versioned)
        var deleted = versioned
        deleted.personalized.removeValue(forKey: "apple")
        deleted.personalVersions?["apple"] = PersonalVersion(counter: 2, device: "ios-test", deleted: true)
        deleted.rejectedPersonalized = ["apple": ["Earlier sentence"]]
        try await api.pushState(deleted)
        try await api.pushState(versioned)
        let afterStale = try await api.pullState()
        precondition(afterStale.state?.personalized["apple"] == nil && afterStale.state?.personalVersions?["apple"]?.deleted == true)
        var replacement = afterStale.state!
        replacement.personalVersions?["apple"] = PersonalVersion(counter: 3, device: "ios-test", deleted: false)
        replacement.personalized["apple"] = PersonalizedSentence(text: "New sentence", recall: nil, zh: "")
        try await api.pushState(replacement)
        try await api.pushState(versioned)
        let afterReplacement = try await api.pullState()
        precondition(afterReplacement.state?.personalized["apple"]?.text == "New sentence")
        var good = afterReplacement.state!, bad = afterReplacement.state!
        StudyEngine.recordKnowledge(&good, word: "evidence", pos: 9, ok: true)
        StudyEngine.recordKnowledge(&bad, word: "evidence", pos: 9, ok: false)
        try await api.pushState(good)
        try await api.pushState(bad)
        try await api.pushState(good)
        let evidence = try await api.pullState()
        precondition(evidence.state?.knowledge?["evidence"]?.a == 1 && evidence.state?.knowledge?["evidence"]?.b == 1)
        precondition(evidence.state?.knowledgeEvidence?["evidence"]?.events.count == 2)
        let checkpoint = try await api.checkpointState(expectedUpdatedAt: evidence.updated_at!, expectedToken: auth.token)
        precondition(checkpoint.state?.restoreEpoch == 2 && checkpoint.state?.knowledgeEvidence?["evidence"]?.events.isEmpty == true)
        do { try await api.pushState(good); fatalError("stale checkpoint branch unexpectedly uploaded") }
        catch let error as APIError { precondition(error.statusCode == 409) }
        var next = checkpoint.state!
        StudyEngine.recordKnowledge(&next, word: "evidence", pos: 9, ok: true)
        try await api.pushState(next)
        let afterCheckpoint = try await api.pullState()
        precondition(afterCheckpoint.state?.knowledge?["evidence"]?.a == 2 && afterCheckpoint.state?.knowledge?["evidence"]?.b == 1)
        let checkpointBackups = try await api.stateBackups()
        precondition(checkpointBackups.backups.contains { $0.reason == "before_checkpoint" })
        // Exercise actual multi-page transport, including a corrupted later
        // page. Failed reads must release the temporary server snapshot.
        var large = afterCheckpoint.state!
        for i in 0..<5000 {
            large.cards[String(format: "snapshot_word_%05d", i)] = CardState(stage: 1, due: nil, lt: nil, pos: i, fsrs: nil)
        }
        try await api.pushState(large, expectedToken: auth.token)
        let largeHead = try await api.pullState(expectedToken: auth.token)
        let largeSnapshot = try await api.storedStateSnapshot(expectedRevision: largeHead.state_revision!, generation: largeHead.sync_generation!, expectedToken: auth.token)
        precondition(largeSnapshot.payload.count > 128 * 1024 && largeSnapshot.restoreEpoch == 2)
        guard case .object(let largeEnvelope) = try StateDelta.decode(largeSnapshot.payload),
              case .object(let largeState)? = largeEnvelope["state"], case .object(let largeCards)? = largeState["cards"] else {
            fatalError("large snapshot failed checked decode")
        }
        precondition(largeCards.count >= 5000)
        func fixture(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
            var request = URLRequest(url: Config.apiBase!.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            precondition((response as? HTTPURLResponse)?.statusCode == 200)
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        _ = try await fixture("api/v1/__ui_fixture/snapshot-corrupt-page", ["page": 1])
        do {
            _ = try await api.storedStateSnapshot(expectedRevision: largeHead.state_revision!, generation: largeHead.sync_generation!, expectedToken: auth.token)
            fatalError("corrupted snapshot unexpectedly accepted")
        } catch let error as APIError {
            precondition(error.message.contains("校验"))
        }
        let count = try await fixture("api/v1/__ui_fixture/snapshot-count", ["token": auth.token])
        precondition(count["active_count"] as? Int == 0)
        _ = try await fixture("api/v1/__ui_fixture/snapshot-hold-page", ["page": 1])
        let pending = Task {
            try await api.storedStateSnapshot(expectedRevision: largeHead.state_revision!, generation: largeHead.sync_generation!, expectedToken: auth.token)
        }
        var held = false
        for _ in 0..<200 {
            let url = Config.apiBase!.appendingPathComponent("api/v1/__ui_fixture/snapshot-hold-status")
            let (data, _) = try await URLSession.shared.data(from: url)
            let status = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            if status["started"] as? Bool == true { held = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        precondition(held)
        await api.setToken("new-session-token")
        _ = try await fixture("api/v1/__ui_fixture/snapshot-release-page", [:])
        do { _ = try await pending.value; fatalError("snapshot crossed login sessions") }
        catch let error as APIError { precondition(error.message.contains("账号已切换")) }
        await api.setToken(auth.token)
        print("PASS iOS verified multi-page snapshot, corruption cleanup and session switch")

        let deltaUser = try await api.register(username: "id_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased(), password: "test_password_123", nickname: "")
        await api.setToken(deltaUser.token)
        let isolatedVersions = try await api.resolveSchedulerBackups(keys: [schedulerKey], generation: old.sync_generation!, expectedToken: deltaUser.token)
        precondition(isolatedVersions.isEmpty)
        schedulerState.cards["apple"]?.fsrsReplayVersions = ["event": schedulerKey]
        do {
            _ = try await api.resolveIncrementalSchedulers(schedulerState, generation: old.sync_generation!, expectedToken: deltaUser.token)
            fatalError("another account's scheduler unexpectedly resolved")
        } catch is APIError { }
        var deltaStart = LearningState()
        deltaStart.cards["apple"] = CardState(stage: 1, due: nil, lt: nil, pos: 1, fsrs: nil)
        try await api.pushState(deltaStart, expectedToken: deltaUser.token)
        let head = try await api.pullState(expectedToken: deltaUser.token)
        let stored = try await api.storedStateSnapshot(expectedRevision: head.state_revision!, generation: head.sync_generation!, expectedToken: deltaUser.token)
        guard case .object(let envelope) = try StateDelta.decode(stored.payload),
              case .object(let base)? = envelope["state"], case .object(var cards)? = base["cards"] else {
            fatalError("missing stored state")
        }
        cards["banana"] = .object(["stage": .integer(1), "pos": .integer(2)])
        var target = base
        target["cards"] = .object(cards)
        let ops = StateDelta.diff(local: base, target: target, server: base)!
        precondition(ops.count == 1 && ops[0].path == ["cards", "banana"])
        let onlyServer: [String: DeltaJSON] = ["cards": .object(["apple": .integer(1), "remote": .integer(2)]), "remoteTop": .bool(true)]
        let localView: [String: DeltaJSON] = ["cards": .object(["apple": .integer(1)])]
        let localEdit: [String: DeltaJSON] = ["cards": .object(["apple": .integer(1), "banana": .null])]
        let localOps = StateDelta.diff(local: localView, target: localEdit, server: onlyServer)!
        precondition(localOps.count == 1 && localOps[0].path == ["cards", "banana"] && localOps[0].value == .null)
        let localApplied = try StateDelta.apply(localOps, to: onlyServer)
        guard case .object(let localCards)? = localApplied["cards"] else { fatalError("map missing") }
        precondition(localCards["banana"] == .null && localCards["remote"] == .integer(2))
        do {
            _ = try StateDelta.apply([.init(op: "remove", path: ["é"], value: nil)], to: ["e\u{301}": .integer(1)])
            fatalError("normalization collision unexpectedly applied")
        } catch is APIError { }
        let precise = try StateDelta.decode(Data("{\"int\":9007199254740993,\"flag\":true,\"empty\":null}".utf8))
        guard case .object(let values) = precise else { fatalError("JSON object missing") }
        precondition(values["int"] == .integer(9_007_199_254_740_993) && values["flag"] == .bool(true) && values["empty"] == .null)
        do {
            _ = try StateDelta.decode(Data("9223372036854775808".utf8))
            fatalError("out-of-range JSON integer unexpectedly accepted")
        } catch is DecodingError { }
        do {
            _ = try StateDelta.decode(Data("{\"cards\":{\"é\":1,\"e\\u0301\":2}}".utf8))
            fatalError("canonically equivalent JSON keys unexpectedly accepted")
        } catch is APIError { }
        _ = try StateDelta.decode(Data("{\"a\\\"b\":[{\"c\":true},null]}".utf8))
        let batch = StateDeltaBatch(generation: stored.generation, base_revision: stored.revision, restore_epoch: stored.restoreEpoch,
                                    batch_id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), ops: ops)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-delta-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = DeltaStateStore(directory: temp.appendingPathComponent("records"), accountID: deltaUser.user.account_id!)
        let initialRecord = try store.load()
        precondition(initialRecord == nil)
        try store.install(generation: stored.generation, revision: stored.revision, restoreEpoch: stored.restoreEpoch, server: base, local: base)
        let recordsPath = temp.appendingPathComponent("records")
        let recordPath = recordsPath.appendingPathComponent("delta-\(deltaUser.user.account_id!).json")
        let guardPath = recordsPath.appendingPathComponent("delta-\(deltaUser.user.account_id!).guard")
        precondition(FileManager.default.fileExists(atPath: guardPath.path))
        // An older installation with a valid record is upgraded lazily.
        try FileManager.default.removeItem(at: guardPath)
        _ = try store.load()
        precondition(FileManager.default.fileExists(atPath: guardPath.path))
        let targetBytes = try JSONEncoder().encode(DeltaJSON.object(target))
        try store.stage(PendingStateDelta(batch: batch, target: targetBytes))
        let reopened = DeltaStateStore(directory: temp.appendingPathComponent("records"), accountID: deltaUser.user.account_id!)
        let durable = try reopened.load()!
        precondition(durable.pending?.batch == batch && durable.pending?.target == targetBytes)
        let displaced = temp.appendingPathComponent("displaced-record.json")
        try FileManager.default.moveItem(at: recordPath, to: displaced)
        do { _ = try reopened.load(); fatalError("missing record unexpectedly treated as legacy") }
        catch let error as APIError { precondition(error.message.contains("缺失")) }
        let noRecoveryBytes = try reopened.rawRecord()
        precondition(noRecoveryBytes == nil)
        try FileManager.default.moveItem(at: displaced, to: recordPath)
        let recoveredPending = try reopened.load()?.pending?.batch
        precondition(recoveredPending == batch)
        let validMarker = try Data(contentsOf: guardPath)
        try Data("corrupt".utf8).write(to: guardPath, options: .atomic)
        do { _ = try reopened.load(); fatalError("corrupt guard unexpectedly accepted") }
        catch is APIError { }
        try validMarker.write(to: guardPath, options: .atomic)
        do {
            try reopened.install(generation: stored.generation, revision: stored.revision, restoreEpoch: stored.restoreEpoch, server: base, local: base)
            fatalError("pending batch was unexpectedly replaced")
        } catch is APIError { }
        // A separate client process submits the persisted batch; the server
        // commits but holds the response until that process is terminated.
        _ = try await fixture("api/v1/__ui_fixture/delta-hold-response", [:])
        let child = Process()
        child.executableURL = Bundle.main.executableURL!.standardizedFileURL
        child.arguments = ["--submit-pending", temp.appendingPathComponent("records").path, deltaUser.user.account_id!]
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment["VOCAB_FIXTURE_TOKEN"] = deltaUser.token
        child.environment = childEnvironment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        var responseHeld = false
        for _ in 0..<200 {
            let url = Config.apiBase!.appendingPathComponent("api/v1/__ui_fixture/delta-hold-status")
            let (data, _) = try await URLSession.shared.data(from: url)
            let status = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            if status["started"] as? Bool == true { responseHeld = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if !responseHeld { child.terminate(); child.waitUntilExit(); fatalError("delta response was not held") }
        let committedBeforeReplay = try await api.pullState(expectedToken: deltaUser.token)
        child.terminate(); child.waitUntilExit()
        _ = try await fixture("api/v1/__ui_fixture/delta-release-response", [:])
        let receipt = try await api.submitStateDelta(try reopened.load()!.pending!.batch, expectedToken: deltaUser.token)
        precondition(committedBeforeReplay.state_revision == receipt.state_revision)
        let replay = try await api.submitStateDelta(try reopened.load()!.pending!.batch, expectedToken: deltaUser.token)
        precondition(receipt.state_revision == replay.state_revision && receipt.updated_at == replay.updated_at)
        _ = try await fixture("api/v1/__ui_fixture/change-corrupt-page", ["page": 0])
        do {
            _ = try await api.committedStateDelta(batch, receipt: receipt, baseline: base, expectedToken: deltaUser.token)
            fatalError("corrupted committed change unexpectedly accepted")
        } catch let error as APIError { precondition(error.message.contains("校验")) }
        let afterBadPage = try reopened.load()!
        precondition(afterBadPage.pending?.batch == batch)
        let confirmed = try await api.committedStateDelta(batch, receipt: receipt, baseline: base, expectedToken: deltaUser.token)
        let forged = StateDeltaReceipt(ok: true, batch_id: String(repeating: "0", count: 32), generation: receipt.generation,
            state_revision: receipt.state_revision, restore_epoch: receipt.restore_epoch, updated_at: receipt.updated_at)
        do { try reopened.acknowledge(receipt: forged, server: confirmed); fatalError("wrong receipt unexpectedly cleared pending") }
        catch is APIError { }
        let afterBadReceipt = try reopened.load()!
        precondition(afterBadReceipt.pending?.batch == batch)
        let recordsDir = temp.appendingPathComponent("records")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: recordsDir.path)
        var failedWrite = false
        do { try reopened.acknowledge(receipt: receipt, server: confirmed) }
        catch { failedWrite = true }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recordsDir.path)
        precondition(failedWrite)
        let preservedAfterFailure = try reopened.load()!
        precondition(preservedAfterFailure.pending?.batch == batch)
        try reopened.acknowledge(receipt: receipt, server: confirmed)
        let acknowledged = try reopened.load()!
        precondition(acknowledged.pending == nil && acknowledged.revision == receipt.state_revision && acknowledged.server == confirmed && acknowledged.local == target)
        let otherStore = DeltaStateStore(directory: temp.appendingPathComponent("records"), accountID: auth.user.account_id!)
        let otherInitial = try otherStore.load()
        precondition(otherInitial == nil)
        try otherStore.install(generation: stored.generation, revision: stored.revision, restoreEpoch: 0, server: onlyServer, local: localView)
        let nullBatch = StateDeltaBatch(generation: stored.generation, base_revision: stored.revision, restore_epoch: 0,
            batch_id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), ops: localOps)
        let nullTarget = try JSONEncoder().encode(DeltaJSON.object(localEdit))
        try otherStore.stage(PendingStateDelta(batch: nullBatch, target: nullTarget))
        let otherPending = try otherStore.load()!
        precondition(otherPending.pending!.batch.ops[0].value == .null)
        let invalidArchive = temp.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: invalidArchive)
        do { try otherStore.archivePendingAndClear(to: invalidArchive); fatalError("invalid archive unexpectedly succeeded") }
        catch { }
        let preservedAfterArchiveFailure = try otherStore.load()!
        precondition(preservedAfterArchiveFailure.pending?.batch == nullBatch)
        let archive = temp.appendingPathComponent("archives")
        try otherStore.archivePendingAndClear(to: archive)
        let archivedFiles = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
        precondition(archivedFiles.count == 1)
        let archivedTarget = try Data(contentsOf: archivedFiles[0])
        let cleared = try otherStore.load()
        precondition(archivedTarget == nullTarget && cleared == nil)
        let corruptPath = recordsDir.appendingPathComponent("delta-\(auth.user.account_id!).json")
        let corruptBytes = Data("{\"pending\":\"damaged\"}".utf8)
        try corruptBytes.write(to: corruptPath)
        do {
            try otherStore.install(generation: stored.generation, revision: stored.revision, restoreEpoch: 0, server: onlyServer, local: localView)
            fatalError("corrupt delta record unexpectedly replaced")
        } catch { }
        let stillCorrupt = try Data(contentsOf: corruptPath)
        precondition(stillCorrupt == corruptBytes)
        let rawRecovery = try otherStore.rawRecord()
        precondition(rawRecovery == corruptBytes)
        guard case .object(let confirmedCards)? = confirmed["cards"] else { fatalError("confirmed cards missing") }
        precondition(confirmedCards["banana"] != nil)
        let committed = try await api.pullState(expectedToken: deltaUser.token)
        precondition(committed.state?.cards["banana"] != nil && committed.state_revision == receipt.state_revision)
        let confirmedSnapshot = try await api.storedStateSnapshot(expectedRevision: committed.state_revision!, generation: committed.sync_generation!, expectedToken: deltaUser.token)
        guard case .object(let committedEnvelope) = try StateDelta.decode(confirmedSnapshot.payload),
              case .object(let committedRaw)? = committedEnvelope["state"] else { fatalError("committed snapshot missing") }
        precondition(confirmed == committedRaw)
        var concurrent = committed.state!
        concurrent.cards["cherry"] = CardState(stage: 1, due: nil, lt: nil, pos: 3, fsrs: nil)
        try await api.pushState(concurrent, expectedToken: deltaUser.token)
        let priorRevision = try await api.committedStateDelta(batch, receipt: receipt, baseline: base, expectedToken: deltaUser.token)
        precondition(priorRevision == confirmed)
        let latest = try await api.pullState(expectedToken: deltaUser.token)
        let latestSnapshot = try await api.storedStateSnapshot(expectedRevision: latest.state_revision!, generation: latest.sync_generation!, expectedToken: deltaUser.token)
        guard case .object(let latestEnvelope) = try StateDelta.decode(latestSnapshot.payload),
              case .object(let latestBase)? = latestEnvelope["state"] else { fatalError("latest snapshot missing") }
        let bulk = StateDeltaBatch(generation: latestSnapshot.generation, base_revision: latestSnapshot.revision, restore_epoch: latestSnapshot.restoreEpoch,
            batch_id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            ops: [.init(op: "set", path: ["cards"], value: .object(largeCards))])
        let bulkReceipt = try await api.submitStateDelta(bulk, expectedToken: deltaUser.token)
        _ = try await fixture("api/v1/__ui_fixture/change-corrupt-page", ["page": 1])
        do {
            _ = try await api.committedStateDelta(bulk, receipt: bulkReceipt, baseline: latestBase, expectedToken: deltaUser.token)
            fatalError("corrupt later journal page unexpectedly accepted")
        } catch let error as APIError { precondition(error.message.contains("校验")) }
        let bulkConfirmed = try await api.committedStateDelta(bulk, receipt: bulkReceipt, baseline: latestBase, expectedToken: deltaUser.token)
        guard case .object(let bulkCards)? = bulkConfirmed["cards"] else { fatalError("bulk cards missing") }
        precondition(bulkCards.count >= 5000)
        let stale = StateDeltaBatch(generation: batch.generation, base_revision: batch.base_revision, restore_epoch: batch.restore_epoch,
                                    batch_id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), ops: ops)
        do { _ = try await api.submitStateDelta(stale, expectedToken: deltaUser.token); fatalError("stale delta unexpectedly accepted") }
        catch let error as APIError { precondition(error.statusCode == 409 && error.code == "BASE_REVISION_CONFLICT") }
        let wrongGeneration = batch.generation == String(repeating: "0", count: 32) ? String(repeating: "1", count: 32) : String(repeating: "0", count: 32)
        let fenced = StateDeltaBatch(generation: wrongGeneration, base_revision: receipt.state_revision, restore_epoch: batch.restore_epoch,
                                     batch_id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), ops: ops)
        do { _ = try await api.submitStateDelta(fenced, expectedToken: deltaUser.token); fatalError("wrong-generation delta unexpectedly accepted") }
        catch let error as APIError { precondition(error.statusCode == 409 && error.code == nil) }
        let tooLarge = StateDeltaBatch(generation: batch.generation, base_revision: batch.base_revision, restore_epoch: batch.restore_epoch,
            batch_id: batch.batch_id, ops: [.init(op: "set", path: ["large"], value: .string(String(repeating: "x", count: 2_000_000)))])
        do { _ = try await api.submitStateDelta(tooLarge, expectedToken: deltaUser.token); fatalError("oversized batch unexpectedly sent") }
        catch let error as APIError { precondition(error.message.contains("过大")) }
        let beforeReset = try await api.pullState(expectedToken: deltaUser.token)
        _ = try await api.checkpointState(expectedUpdatedAt: beforeReset.updated_at!, expectedToken: deltaUser.token)
        do {
            _ = try await api.committedStateDelta(bulk, receipt: bulkReceipt, baseline: latestBase, expectedToken: deltaUser.token)
            fatalError("pre-checkpoint journal unexpectedly accepted")
        } catch let error as APIError { precondition(error.statusCode == 409) }
        let coordinatorUser = try await api.register(username: "ic_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased(), password: "test_password_123", nickname: "")
        await api.setToken(coordinatorUser.token)
        var coordinatorInitial = LearningState()
        coordinatorInitial.cards["apple"] = CardState(stage: 1, due: nil, lt: nil, pos: 1, fsrs: nil)
        try await api.pushState(coordinatorInitial, expectedToken: coordinatorUser.token)
        let coordinatorHead = try await api.pullState(expectedToken: coordinatorUser.token)
        let syncDirectory = temp.appendingPathComponent("coordinator")
        let coordinator = DeltaSyncCoordinator(directory: syncDirectory)
        let account = coordinatorUser.user.account_id!, token = coordinatorUser.token
        try await coordinator.prime(account: account, token: token, remote: coordinatorHead, local: coordinatorHead.state!)
        var a = coordinatorHead.state!
        a.cards["banana"] = CardState(stage: 1, due: nil, lt: nil, pos: 2, fsrs: nil)
        var b = a
        b.cards["kiwi"] = CardState(stage: 1, due: nil, lt: nil, pos: 3, fsrs: nil)
        let firstTarget = a, secondTarget = b
        _ = try await fixture("api/v1/__ui_fixture/delta-hold-response", [:])
        let firstPush = Task { try await coordinator.push(account: account, token: token, target: firstTarget) }
        var firstHeld = false
        for _ in 0..<200 {
            let url = Config.apiBase!.appendingPathComponent("api/v1/__ui_fixture/delta-hold-status")
            let (data, _) = try await URLSession.shared.data(from: url)
            let status = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            if status["started"] as? Bool == true { firstHeld = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        precondition(firstHeld)
        let secondPush = Task { try await coordinator.push(account: account, token: token, target: secondTarget) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let whileHeld = try await api.pullState(expectedToken: token)
        precondition(whileHeld.state?.cards["banana"] != nil && whileHeld.state?.cards["kiwi"] == nil)
        _ = try await fixture("api/v1/__ui_fixture/delta-release-response", [:])
        try await firstPush.value; try await secondPush.value
        let serialResult = try await api.pullState(expectedToken: token)
        precondition(serialResult.state?.cards["banana"] != nil && serialResult.state?.cards["kiwi"] != nil)
        var remoteEdit = serialResult.state!
        remoteEdit.cards["date"] = CardState(stage: 1, due: nil, lt: nil, pos: 4, fsrs: nil)
        try await api.pushState(remoteEdit, expectedToken: token)
        var localEditAfterRace = secondTarget
        localEditAfterRace.cards["elder"] = CardState(stage: 1, due: nil, lt: nil, pos: 5, fsrs: nil)
        try await coordinator.push(account: account, token: token, target: localEditAfterRace)
        let mergedResult = try await api.pullState(expectedToken: token)
        precondition(mergedResult.state?.cards["date"] != nil && mergedResult.state?.cards["elder"] != nil)
        _ = try await fixture("api/v1/__ui_fixture/change-corrupt-page", ["page": 0])
        var lostTarget = localEditAfterRace
        lostTarget.cards["fig"] = CardState(stage: 1, due: nil, lt: nil, pos: 6, fsrs: nil)
        do { try await coordinator.push(account: account, token: token, target: lostTarget); fatalError("corrupt coordinator change unexpectedly accepted") }
        catch let error as APIError { precondition(error.message.contains("校验")) }
        let coordinatorStore = DeltaStateStore(directory: syncDirectory, accountID: account)
        let pendingAfterFailure = try coordinatorStore.load()!
        precondition(pendingAfterFailure.pending != nil)
        var newest = lostTarget
        newest.cards["grape"] = CardState(stage: 1, due: nil, lt: nil, pos: 7, fsrs: nil)
        try await coordinator.push(account: account, token: token, target: newest)
        let resumed = try await api.pullState(expectedToken: token)
        precondition(resumed.state?.cards["date"] != nil && resumed.state?.cards["fig"] != nil && resumed.state?.cards["grape"] != nil)
        let recordAfterResume = try coordinatorStore.load()!
        precondition(recordAfterResume.pending == nil)
        _ = try await api.checkpointState(expectedUpdatedAt: resumed.updated_at!, expectedToken: token)
        _ = try await fixture("api/v1/__ui_fixture/state-changes-prune", ["token": token])
        do { try await coordinator.push(account: account, token: token, target: newest); fatalError("pruned restore unexpectedly acknowledged") }
        catch let error as APIError { precondition(error.statusCode == 409) }
        let pendingAfterRestore = try coordinatorStore.load()!
        precondition(pendingAfterRestore.pending?.merge == true)
        let preserved = temp.appendingPathComponent("coordinator-archives")
        do {
            _ = try await coordinator.restoreAndClear(account: account, token: token, state: newest,
                expectedUpdatedAt: 0, revision: resumed.state_revision, generation: resumed.sync_generation, archiveDirectory: preserved)
            fatalError("stale restore unexpectedly succeeded")
        } catch let error as APIError { precondition(error.statusCode == 409) }
        let afterFailedRestore = try coordinatorStore.load()!
        precondition(afterFailedRestore.pending?.merge == true)
        let currentForRestore = try await api.pullState(expectedToken: token)
        let blockedPreArchive = temp.appendingPathComponent("blocked-pre-archive")
        try Data("file".utf8).write(to: blockedPreArchive)
        do {
            _ = try await coordinator.restoreAndClear(account: account, token: token, state: newest,
                expectedUpdatedAt: currentForRestore.updated_at, revision: currentForRestore.state_revision,
                generation: currentForRestore.sync_generation, archiveDirectory: blockedPreArchive)
            fatalError("restore continued after archival failure")
        } catch { }
        do {
            _ = try await coordinator.checkpointAndClear(account: account, token: token,
                expectedUpdatedAt: currentForRestore.updated_at!, revision: currentForRestore.state_revision,
                generation: currentForRestore.sync_generation, archiveDirectory: blockedPreArchive)
            fatalError("checkpoint continued after archival failure")
        } catch { }
        let afterArchiveFailure = try await api.pullState(expectedToken: token)
        precondition(afterArchiveFailure.state_revision == currentForRestore.state_revision && afterArchiveFailure.updated_at == currentForRestore.updated_at)
        let preservedOnArchiveFailure = try coordinatorStore.load()!
        precondition(preservedOnArchiveFailure.pending?.merge == true)
        do {
            try await coordinator.reloadCheckAndClear(account: account, token: token, updatedAt: currentForRestore.updated_at,
                revision: currentForRestore.state_revision, generation: String(repeating: "0", count: 32), archiveDirectory: preserved)
            fatalError("stale reload unexpectedly cleared its baseline")
        } catch let error as APIError { precondition(error.message.contains("服务器进度已变化")) }
        let afterFailedReload = try coordinatorStore.load()!
        precondition(afterFailedReload.pending?.merge == true)
        do {
            try await coordinator.reloadCheckAndClear(account: account, token: token, updatedAt: currentForRestore.updated_at,
                revision: currentForRestore.state_revision, generation: currentForRestore.sync_generation, archiveDirectory: preserved) { _ in
                throw APIError(message: "本机进度已变化，请重试")
            }
            fatalError("local change unexpectedly cleared its baseline")
        } catch let error as APIError { precondition(error.message.contains("本机进度已变化")) }
        let afterChangedLocal = try coordinatorStore.load()!
        precondition(afterChangedLocal.pending?.merge == true)
        let restoredByCoordinator = try await coordinator.restoreAndClear(account: account, token: token, state: newest,
            expectedUpdatedAt: currentForRestore.updated_at, revision: currentForRestore.state_revision,
            generation: currentForRestore.sync_generation, archiveDirectory: preserved)
        precondition(restoredByCoordinator.state?.cards["grape"] != nil)
        let clearedByRestore = try coordinatorStore.load()
        precondition(clearedByRestore == nil)
        let savedTargets = try FileManager.default.contentsOfDirectory(at: preserved, includingPropertiesForKeys: nil)
        precondition(savedTargets.count == 2) // stale and successful attempts both retain the pending target
        for file in savedTargets {
            let savedState = try JSONDecoder().decode(LearningState.self, from: Data(contentsOf: file))
            precondition(savedState.cards["grape"] != nil)
        }
        let afterReset = try await api.pullState(expectedToken: token)
        try await coordinator.prime(account: account, token: token, remote: afterReset, local: afterReset.state!)
        var switchTarget = afterReset.state!
        switchTarget.cards["honeydew"] = CardState(stage: 1, due: nil, lt: nil, pos: 8, fsrs: nil)
        _ = try await fixture("api/v1/__ui_fixture/delta-hold-response", [:])
        let switchPush = Task { try await coordinator.push(account: account, token: token, target: switchTarget) }
        var switchHeld = false
        for _ in 0..<200 {
            let url = Config.apiBase!.appendingPathComponent("api/v1/__ui_fixture/delta-hold-status")
            let (data, _) = try await URLSession.shared.data(from: url)
            let status = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            if status["started"] as? Bool == true { switchHeld = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        precondition(switchHeld)
        await api.setToken("other-session-token")
        _ = try await fixture("api/v1/__ui_fixture/delta-release-response", [:])
        do { try await switchPush.value; fatalError("old account response crossed sessions") }
        catch let error as APIError { precondition(error.message.contains("账号已切换")) }
        let preservedSwitch = try coordinatorStore.load()!
        precondition(preservedSwitch.pending != nil)
        await api.setToken(token)
        try await coordinator.push(account: account, token: token, target: switchTarget)
        var hugeTarget = switchTarget
        for i in 0..<2100 {
            hugeTarget.cards[String(format: "coordinator_word_%05d", i)] = CardState(stage: 1, due: nil, lt: nil, pos: i, fsrs: nil)
        }
        func stagedCount() async throws -> Int {
            let url = Config.apiBase!.appendingPathComponent("api/v1/__ui_fixture/state-upload-status")
            let (data, _) = try await URLSession.shared.data(from: url)
            return (try JSONSerialization.jsonObject(with: data) as! [String: Any])["stage_successes"] as! Int
        }
        let stagesBefore = try await stagedCount()
        try await coordinator.push(account: account, token: token, target: hugeTarget)
        let stagesAfter = try await stagedCount(); precondition(stagesAfter > stagesBefore)
        let afterHuge = try await api.pullState(expectedToken: token)
        precondition(afterHuge.state!.cards.count >= 2100)
        try await coordinator.verifyPulled(account: account, token: token, remote: afterHuge)
        let coordinatorPath = syncDirectory.appendingPathComponent("delta-\(account).json")
        let displacedCoordinator = temp.appendingPathComponent("displaced-coordinator.json")
        try FileManager.default.moveItem(at: coordinatorPath, to: displacedCoordinator)
        var missingRecordTarget = hugeTarget
        missingRecordTarget.cards["missing_record"] = CardState(stage: 1, due: nil, lt: nil, pos: 4, fsrs: nil)
        do { try await coordinator.push(account: account, token: token, target: missingRecordTarget); fatalError("missing baseline unexpectedly uploaded") }
        catch let error as APIError { precondition(error.message.contains("缺失")) }
        let afterMissing = try await api.pullState(expectedToken: token)
        precondition(afterMissing.state_revision == afterHuge.state_revision && afterMissing.state?.cards["missing_record"] == nil)
        let reportsMissing = try await coordinator.hasMissingRecord(account: account)
        precondition(reportsMissing)
        do {
            try await coordinator.reloadCheckAndClear(account: account, token: token, updatedAt: afterMissing.updated_at,
                revision: afterMissing.state_revision, generation: String(repeating: "0", count: 32), archiveDirectory: preserved, allowMissingRecord: true)
            fatalError("stale reload unexpectedly discarded missing-record guard")
        } catch let error as APIError { precondition(error.message.contains("服务器进度已变化")) }
        let stillMissing = try await coordinator.hasMissingRecord(account: account)
        precondition(stillMissing)
        try await coordinator.reloadCheckAndClear(account: account, token: token, updatedAt: afterMissing.updated_at,
            revision: afterMissing.state_revision, generation: afterMissing.sync_generation, archiveDirectory: preserved, allowMissingRecord: true)
        let clearedMissing = try await coordinator.hasMissingRecord(account: account)
        precondition(!clearedMissing)
        try FileManager.default.moveItem(at: displacedCoordinator, to: coordinatorPath)
        _ = try coordinatorStore.load() // a restored old record reinstates the guard
        _ = try await fixture("api/v1/__ui_fixture/reset-sync-generation", [:])
        let rotatedRemote = try await api.pullState(expectedToken: token)
        do { try await coordinator.verifyPulled(account: account, token: token, remote: rotatedRemote); fatalError("rotated pull unexpectedly accepted") }
        catch let error as APIError { precondition(error.message.contains("代次")) }
        do { try await coordinator.prime(account: account, token: token, remote: rotatedRemote, local: rotatedRemote.state!); fatalError("rotated baseline unexpectedly accepted") }
        catch let error as APIError { precondition(error.message.contains("代次")) }
        var oldGenerationTarget = hugeTarget
        oldGenerationTarget.cards["jicama"] = CardState(stage: 1, due: nil, lt: nil, pos: 9, fsrs: nil)
        for i in 0..<2050 {
            oldGenerationTarget.cards[String(format: "after_rotation_%05d", i)] = CardState(stage: 1, due: nil, lt: nil, pos: i, fsrs: nil)
        }
        do { try await coordinator.push(account: account, token: token, target: oldGenerationTarget); fatalError("old database generation unexpectedly accepted") }
        catch let error as APIError { precondition(error.statusCode == 409) }
        let preservedGeneration = try coordinatorStore.load()!
        precondition(preservedGeneration.pending?.stagedPayload != nil)
        try await coordinator.clear(account: account, archiveDirectory: preserved)
        let savedAfterGeneration = try FileManager.default.contentsOfDirectory(at: preserved, includingPropertiesForKeys: nil)
        precondition(savedAfterGeneration.count == 3)
        _ = try await fixture("api/v1/__ui_fixture/snapshots-disabled", ["disabled": true])
        let legacyUser = try await api.register(username: "il_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased(), password: "test_password_123", nickname: "")
        await api.setToken(legacyUser.token)
        var legacyTarget = LearningState()
        legacyTarget.cards["apple"] = CardState(stage: 1, due: nil, lt: nil, pos: 1, fsrs: nil)
        let legacyAccount = legacyUser.user.account_id!
        try await coordinator.push(account: legacyAccount, token: legacyUser.token, target: legacyTarget)
        legacyTarget.cards["banana"] = CardState(stage: 1, due: nil, lt: nil, pos: 2, fsrs: nil)
        try await coordinator.push(account: legacyAccount, token: legacyUser.token, target: legacyTarget)
        let legacyResult = try await api.pullState(expectedToken: legacyUser.token)
        let legacyRecord = try DeltaStateStore(directory: syncDirectory, accountID: legacyAccount).load()
        precondition(legacyResult.state?.cards["banana"] != nil && legacyRecord == nil)
        _ = try await fixture("api/v1/__ui_fixture/snapshots-disabled", ["disabled": false])
        let readSnapshot = try await api.storedStateSnapshot(expectedRevision: legacyResult.state_revision!, generation: legacyResult.sync_generation!, expectedToken: legacyUser.token)
        guard case .object(let readEnvelope) = try StateDelta.decode(readSnapshot.payload),
              case .object(let readBase)? = readEnvelope["state"] else { fatalError("stored baseline missing") }
        var nextRead = legacyResult.state!
        nextRead.cards["cherry"] = CardState(stage: 1, due: nil, lt: nil, pos: 3, fsrs: nil)
        try await api.pushState(nextRead, expectedToken: legacyUser.token)
        nextRead.cards["date"] = CardState(stage: 1, due: nil, lt: nil, pos: 4, fsrs: nil)
        try await api.pushState(nextRead, expectedToken: legacyUser.token)
        let readHead = try await api.pullState(expectedToken: legacyUser.token)
        let materialized = try await api.readStateChanges(baseline: readBase, revision: readSnapshot.revision,
            generation: readSnapshot.generation, restoreEpoch: readSnapshot.restoreEpoch, expectedToken: legacyUser.token)
        guard case .object(let readCards)? = materialized.state["cards"] else { fatalError("journal cards missing") }
        precondition(materialized.revision == readHead.state_revision && readCards["cherry"] != nil && readCards["date"] != nil)
        let pullDirectory = temp.appendingPathComponent("pull-records")
        let pullStore = DeltaStateStore(directory: pullDirectory, accountID: legacyAccount)
        guard case .object(let priorView) = try StateDelta.decode(JSONEncoder().encode(legacyResult.state!)) else { fatalError("local baseline missing") }
        try pullStore.install(generation: readSnapshot.generation, revision: readSnapshot.revision,
                              restoreEpoch: readSnapshot.restoreEpoch, server: readBase, local: priorView)
        let pullCoordinator = DeltaSyncCoordinator(directory: pullDirectory, api: api)
        let installedFile = temp.appendingPathComponent("interrupted-pull-state.json")
        try JSONEncoder().encode(legacyResult.state!).write(to: installedFile, options: .atomic)
        let pullChild = Process()
        pullChild.executableURL = Bundle.main.executableURL!.standardizedFileURL
        pullChild.arguments = ["--stage-pull", pullDirectory.path, legacyAccount, installedFile.path]
        var pullEnvironment = ProcessInfo.processInfo.environment
        pullEnvironment["VOCAB_FIXTURE_TOKEN"] = legacyUser.token
        pullChild.environment = pullEnvironment
        try pullChild.run()
        defer { if pullChild.isRunning { pullChild.terminate(); pullChild.waitUntilExit() } }
        var installed = false
        for _ in 0..<200 {
            if let bytes = try? Data(contentsOf: installedFile), let saved = try? JSONDecoder().decode(LearningState.self, from: bytes), saved.cards["date"] != nil {
                installed = true; break
            }
            if !pullChild.isRunning { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(installed, "child did not persist the downloaded state")
        pullChild.terminate(); pullChild.waitUntilExit()
        let stagedPull = try pullStore.load()!
        precondition(stagedPull.pull != nil && stagedPull.revision == readSnapshot.revision)
        let stagedRepresentation = try JSONSerialization.jsonObject(with:pullStore.rawRecord()!) as! [String:Any]
        precondition(stagedRepresentation["compactPull"] != nil, "interrupted pull did not use compact representation")
        // A confirmed server reload after the main slot was installed must
        // preserve both views, even when it clears the pending pull record.
        let reloadDir = temp.appendingPathComponent("pull-reload-records")
        try FileManager.default.createDirectory(at: reloadDir, withIntermediateDirectories: true)
        for suffix in ["json", "guard"] {
            let name = "delta-\(legacyAccount).\(suffix)"
            try FileManager.default.copyItem(at: pullDirectory.appendingPathComponent(name), to: reloadDir.appendingPathComponent(name))
        }
        let reloadArchive = temp.appendingPathComponent("pull-reload-archive")
        try await DeltaSyncCoordinator(directory: reloadDir, api: api).reloadCheckAndClear(
            account: legacyAccount, token: legacyUser.token, updatedAt: readHead.updated_at,
            revision: readHead.state_revision, generation: readHead.sync_generation, archiveDirectory: reloadArchive)
        let savedViews = try FileManager.default.contentsOfDirectory(at: reloadArchive, includingPropertiesForKeys: nil).map { try Data(contentsOf: $0) }
        precondition(savedViews.count == 2 && savedViews.contains(stagedPull.pull!.previous) && savedViews.contains(stagedPull.pull!.target))
        let reloadStore = DeltaStateStore(directory: reloadDir, accountID: legacyAccount)
        let reloadRaw = try reloadStore.rawRecord()
        precondition(reloadRaw == nil)
        let recoverablePrior = try await pullCoordinator.pendingPullPrevious(account: legacyAccount)
        let decodedPrior = try recoverablePrior.map { try JSONDecoder().decode(LearningState.self, from: $0) }
        precondition(decodedPrior == legacyResult.state)
        do { try await pullCoordinator.push(account: legacyAccount, token: legacyUser.token, target: legacyResult.state!); fatalError("push bypassed staged pull") }
        catch let error as APIError { precondition(error.message.contains("未完成")) }
        let reopenedPullCoordinator = DeltaSyncCoordinator(directory: pullDirectory, api: api)
        let resumedPull = try await reopenedPullCoordinator.resumePull(account: legacyAccount, token: legacyUser.token) { _, target in
            let saved = try JSONDecoder().decode(LearningState.self, from: Data(contentsOf: installedFile))
            precondition(saved == target)
        }
        let finishedPull = try pullStore.load()!
        precondition(resumedPull && finishedPull.pull == nil && finishedPull.revision == readHead.state_revision)
        print("PASS iOS staged incremental read resumes after process termination")
        let installedBytes = try Data(contentsOf: installedFile)
        try pullStore.stagePull(PendingStatePull(revision: finishedPull.revision, server: finishedPull.server,
                                                 previous: installedBytes, target: installedBytes))
        do {
            _ = try await reopenedPullCoordinator.resumePull(account: legacyAccount, token: legacyUser.token) { _, _ in
                throw APIError(message: "本机进度已变化")
            }
            fatalError("changed local state unexpectedly acknowledged")
        } catch let error as APIError { precondition(error.message.contains("本机进度已变化")) }
        let afterLocalChange = try pullStore.load()!
        precondition(afterLocalChange.pull != nil)
        _ = try await fixture("api/v1/__ui_fixture/state-changes-prune", ["token": legacyUser.token])
        do {
            _ = try await api.readStateChanges(baseline: readBase, revision: readSnapshot.revision,
                generation: readSnapshot.generation, restoreEpoch: readSnapshot.restoreEpoch, expectedToken: legacyUser.token)
            fatalError("pruned journal unexpectedly accepted")
        } catch let error as APIError { precondition(error.statusCode == 410) }
        _ = try await fixture("api/v1/__ui_fixture/reset-sync-generation", [:])
        do {
            _ = try await api.readStateChanges(baseline: readBase, revision: readSnapshot.revision,
                generation: readSnapshot.generation, restoreEpoch: readSnapshot.restoreEpoch, expectedToken: legacyUser.token)
            fatalError("rotated journal unexpectedly accepted")
        } catch let error as APIError { precondition(error.statusCode == 409) }
        do {
            _ = try await reopenedPullCoordinator.resumePull(account: legacyAccount, token: legacyUser.token) { _, _ in
                fatalError("stale staged download was installed")
            }
            fatalError("rotated staged download unexpectedly accepted")
        } catch let error as APIError { precondition(error.statusCode == 409) }
        let stillStaged = try pullStore.load()!
        precondition(stillStaged.pull != nil)
        // Simulate failure to install the server result on the main actor.
        // With no baseline a guard must prevent a later legacy upload; with a
        // baseline, the exact original record must remain until installation.
        let fenceUser = try await api.register(username: "if_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased(), password: "test_password_123", nickname: "")
        await api.setToken(fenceUser.token)
        let fenceAccount = fenceUser.user.account_id!
        let fenceDir = temp.appendingPathComponent("mutation-install-fence")
        let fenceCoordinator = DeltaSyncCoordinator(directory: fenceDir, api: api)
        let fenceStore = DeltaStateStore(directory: fenceDir, accountID: fenceAccount)
        var fenceState = LearningState()
        fenceState.cards["apple"] = CardState(stage: 1, due: nil, lt: nil, pos: 1, fsrs: nil)
        try await api.pushState(fenceState, expectedToken: fenceUser.token)
        let beforeFenceRestore = try await api.pullState(expectedToken: fenceUser.token)
        do {
            _ = try await fenceCoordinator.restoreAndClear(account: fenceAccount, token: fenceUser.token, state: fenceState,
                expectedUpdatedAt: beforeFenceRestore.updated_at, revision: beforeFenceRestore.state_revision,
                generation: beforeFenceRestore.sync_generation, archiveDirectory: preserved) { _, _, _ in
                throw APIError(message: "injected local installation failure")
            }
            fatalError("failed local restore unexpectedly succeeded")
        } catch let error as APIError { precondition(error.message.contains("injected local")) }
        let afterFenceRestore = try await api.pullState(expectedToken: fenceUser.token)
        precondition(afterFenceRestore.state_revision != beforeFenceRestore.state_revision)
        let missingAfterRestore = try fenceStore.hasMissingRecord()
        precondition(missingAfterRestore)
        do { try await fenceCoordinator.push(account: fenceAccount, token: fenceUser.token, target: fenceState); fatalError("missing guard bypassed") }
        catch { }
        try fenceStore.archivePendingAndClear(to: preserved, allowMissingRecord: true)
        fenceState = afterFenceRestore.state!
        try await fenceCoordinator.prime(account: fenceAccount, token: fenceUser.token, remote: afterFenceRestore, local: fenceState)
        let beforeCheckpointRecord = try fenceStore.rawRecord()
        let beforeFenceCheckpoint = try await api.pullState(expectedToken: fenceUser.token)
        do {
            _ = try await fenceCoordinator.checkpointAndClear(account: fenceAccount, token: fenceUser.token,
                expectedUpdatedAt: beforeFenceCheckpoint.updated_at!, revision: beforeFenceCheckpoint.state_revision,
                generation: beforeFenceCheckpoint.sync_generation, archiveDirectory: preserved) { _, _, _ in
                throw APIError(message: "injected local installation failure")
            }
            fatalError("failed local checkpoint unexpectedly succeeded")
        } catch let error as APIError { precondition(error.message.contains("injected local")) }
        let afterFenceCheckpoint = try await api.pullState(expectedToken: fenceUser.token)
        precondition(afterFenceCheckpoint.state_revision != beforeFenceCheckpoint.state_revision)
        let afterCheckpointRecord = try fenceStore.rawRecord()
        precondition(beforeCheckpointRecord == afterCheckpointRecord)
        print("PASS iOS restore and checkpoint retain mutation fences on local installation failure")
        print("PASS iOS bounded multi-revision journal read and generation fence")
        print("PASS iOS coordinator serial uploads, concurrent merge, pending replay and pruned restore fencing")
        print("PASS iOS durable pending replay after process termination, storage failure and account isolation")
        print("PASS iOS delta diff, receipt replay, verified multi-page changes, reset fencing and size validation")
        print("PASS iOS checkpoint baseline, retained backup and stale-device fencing over HTTP")
        print("PASS iOS independent knowledge events merge once over HTTP")
        print("PASS iOS personalized version survives HTTP deletion and stale uploads")
        print("PASS iOS API restore CAS, epoch decoding and stale-device rejection")
    }
}
