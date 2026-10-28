import Foundation
import Darwin

enum Config {
    static let apiBase: URL? = {
        let value = ProcessInfo.processInfo.environment["VOCAB_TEST_BASE"] ?? "http://127.0.0.1:18765"
        guard let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
              (url.path.isEmpty || url.path == "/"), url.user == nil, url.password == nil else { fatalError("fixture must be loopback") }
        return url
    }()
}

@main struct IOSStagedUploadCheck {
    static func syncSlot(_ slot: URL) throws {
        for url in [slot,slot.deletingLastPathComponent()] {
            let fd=open(url.path,O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw APIError(message:"slot sync open failed") }
            let result=fsync(fd);close(fd)
            guard result == 0 else { throw APIError(message:"slot sync failed") }
        }
    }
    static func fixture(_ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: Config.apiBase!.appendingPathComponent("api/v1/__ui_fixture/" + path))
        if let body { req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw APIError(message: "fixture failed") }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func waitForHold() async throws {
        for _ in 0..<400 {
            if try await fixture("delta-hold-status")["started"] as? Bool == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw APIError(message: "fixture hold timed out")
    }
    static func main() async throws {
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--restore-capability" {
            let api=APIClient.shared
            let user=try await api.register(username:"cap_"+UUID().uuidString.prefix(8).lowercased(),password:"test_password_123",nickname:"")
            await api.setToken(user.token)
            _ = try await fixture("experimental-large-deltas",["enabled":false])
            let disabled=try await api.supportsExperimentalLargeRestore(expectedToken:user.token);precondition(!disabled)
            _ = try await fixture("experimental-large-deltas",["enabled":true])
            let enabled=try await api.supportsExperimentalLargeRestore(expectedToken:user.token);precondition(enabled)
            _ = try await fixture("experimental-large-deltas",["enabled":false])
            print("PASS large restore capability respects the server switch")
            return
        }
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--experimental-large" {
            let api = APIClient.shared
            let user = try await api.register(username:"big_" + UUID().uuidString.prefix(8).lowercased(), password:"test_password_123", nickname:"")
            let token=user.token, account=user.user.account_id!
            await api.setToken(token)
            var initial=LearningState(); initial.personalizedWeak=String(repeating:"x",count:7*1024*1024)
            initial.cards["apple"] = CardState(stage:1,due:nil,lt:nil,pos:1,fsrs:nil)
            try await api.pushState(initial,expectedToken:token)
            let remote=try await api.pullState(expectedToken:token)
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent("vocab-ios-large-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:directory) }
            let coordinator=DeltaSyncCoordinator(directory:directory), store=DeltaStateStore(directory:directory,accountID:account)
            try await coordinator.prime(account:account,token:token,remote:remote,local:initial)
            let start=try store.load()!
            var target=initial; target.personalized["apple"] = PersonalizedSentence(text:String(repeating:"y",count:2100*1024))
            let targetBytes=try JSONEncoder().encode(target); precondition(targetBytes.count>8*1024*1024)
            do { try await coordinator.push(account:account,token:token,target:target); fatalError("disabled large service accepted") }
            catch let error as APIError { precondition(error.message.contains("未启用")) }
            let disabled=try store.load()!; precondition(disabled.pending == nil && disabled.revision==start.revision)
            _ = try await fixture("experimental-large-deltas",["enabled":true])
            let file=directory.appendingPathComponent("large-target.json");try targetBytes.write(to:file,options:.atomic)
            _ = try await fixture("delta-hold-response",[:])
            let child=Process(); child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0],relativeTo:URL(fileURLWithPath:FileManager.default.currentDirectoryPath,isDirectory:true)).standardizedFileURL
            child.arguments=["--child",directory.path,account,file.path]
            child.environment=ProcessInfo.processInfo.environment.merging(["VOCAB_FIXTURE_TOKEN":token]) { _,new in new }
            try child.run(); try await waitForHold()
            kill(child.processIdentifier,SIGKILL);child.waitUntilExit()
            _ = try await fixture("delta-release-response",[:])
            let pending=try store.load()!; precondition(pending.pending?.experimentalLarge == true && pending.pending?.stagedPayload != nil)
            _ = try await fixture("experimental-large-deltas",["enabled":false])
            do { try await coordinator.push(account:account,token:token,target:target); fatalError("disabled replay accepted") } catch {}
            let preserved=try store.load()!; precondition(preserved.pending?.batch.batch_id == pending.pending?.batch.batch_id)
            _ = try await fixture("experimental-large-deltas",["enabled":true])
            try await coordinator.push(account:account,token:token,target:target)
            let recovered=try store.load()!, committed=String(Int(start.revision)!+1)
            precondition(recovered.pending == nil && recovered.revision == committed)
            let snapshot=try await api.storedStateSnapshot(expectedRevision:committed,generation:start.generation,expectedToken:token)
            guard case .object(let envelope)=try StateDelta.decode(snapshot.payload), case .object(let state)?=envelope["state"],
                  case .object(let personal)?=state["personalized"],case .object(let apple)?=personal["apple"],
                  case .string(let sentence)?=apple["text"] else { fatalError("large snapshot incomplete") }
            precondition(sentence.count==2100*1024)
            _ = try await fixture("experimental-large-deltas",["enabled":false])
            do { _ = try await api.pullState(expectedToken:token); fatalError("disabled service read oversized state") }
            catch let error as APIError { precondition(error.statusCode==413) }
            _ = try await fixture("experimental-large-deltas",["enabled":true])
            _ = try await fixture("snapshot-corrupt-page",["page":1])
            do { _ = try await api.pullState(expectedToken:token); fatalError("corrupt large snapshot accepted") } catch {}
            let fresh=try await api.pullState(expectedToken:token)
            precondition(fresh.fromLargeSnapshot && fresh.state_revision==committed && fresh.state?.personalized["apple"]?.text.count==2100*1024)
            let freshDirectory=directory.appendingPathComponent("new-device",isDirectory:true)
            let freshCoordinator=DeltaSyncCoordinator(directory:freshDirectory)
            try await freshCoordinator.prime(account:account,token:token,remote:fresh,local:fresh.state!)
            target.cards["banana"] = CardState(stage:1,due:nil,lt:nil,pos:2,fsrs:nil)
            try await coordinator.push(account:account,token:token,target:target)
            let next=try store.load()!;precondition(next.revision==String(Int(committed)!+1) && next.pending==nil)
            let installed=try await freshCoordinator.readAndApply(account:account,token:token,local:fresh.state!) { _, value in
                precondition(value.cards["banana"] != nil && value.personalized["apple"]?.text.count==2100*1024)
            }
            precondition(installed)
            let remoteBatch=StateDeltaBatch(generation:next.generation,base_revision:next.revision,restore_epoch:next.restore_epoch,
                batch_id:UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),ops:[.init(op:"set",path:["cards","remote"],value:.object(["pos":.integer(3)]))])
            _ = try await api.submitStateDelta(remoteBatch,expectedToken:token,experimentalLarge:true)
            target.cards["local"] = CardState(stage:1,due:nil,lt:nil,pos:4,fsrs:nil)
            do { try await coordinator.push(account:account,token:token,target:target);fatalError("stale large branch accepted") }
            catch let error as APIError { precondition(error.statusCode==409 && error.code=="BASE_REVISION_CONFLICT") }
            let conflict=try store.load()!;precondition(conflict.pending?.experimentalLarge == true && conflict.pending?.merge == false)
            _ = try await fixture("snapshot-hold-page",["page":1])
            let racingRead=Task { try await api.pullState(expectedToken:token) }
            var snapshotHeld=false
            for _ in 0..<400 {
                if try await fixture("snapshot-hold-status")["started"] as? Bool == true { snapshotHeld=true;break }
                try await Task.sleep(nanoseconds:50_000_000)
            }
            precondition(snapshotHeld)
            let racingBatch=StateDeltaBatch(generation:next.generation,base_revision:String(Int(next.revision)!+1),restore_epoch:next.restore_epoch,
                batch_id:UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),ops:[.init(op:"set",path:["cards","race"],value:.object(["pos":.integer(5)]))])
            _ = try await api.submitStateDelta(racingBatch,expectedToken:token,experimentalLarge:true)
            _ = try await fixture("snapshot-release-page",[:])
            do { _ = try await racingRead.value;fatalError("stale bootstrap snapshot accepted") }
            catch let error as APIError { precondition(error.statusCode==409) }
            _ = try await fixture("experimental-large-deltas",["enabled":false])
            print("PASS iOS experimental large staged replay, verified snapshot, direct update and conflict preservation")
            return
        }
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--compact-retention" {
            let api = APIClient.shared
            let user = try await api.register(username: "retain_" + UUID().uuidString.prefix(8).lowercased(), password: "test_password_123", nickname: "")
            let token = user.token, account = user.user.account_id!
            await api.setToken(token)
            var initial = LearningState()
            initial.log = (0..<500).map { LogEntry(d:"2026-10-27", word:String(format:"word%04d",$0), rating:3, kind:"review", eventId:String(format:"%032x",$0)) }
            try await api.pushState(initial, expectedToken: token)
            let remote = try await api.pullState(expectedToken: token)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-retention-" + UUID().uuidString, isDirectory:true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let coordinator = DeltaSyncCoordinator(directory: directory)
            try await coordinator.prime(account: account, token: token, remote: remote, local: remote.state!)
            let record = try DeltaStateStore(directory: directory, accountID: account).load()!
            _ = try await fixture("state-changes-byte-limit", ["limit":1800])
            for i in 0..<3 {
                let event: DeltaJSON = .object(["eventId":.string(String(format:"%032x",1000+i)),"d":.string("2099-01-01"),"word":.string("new\(i)"),"kind":.string("review"),"rating":.integer(4)])
                let batch = StateDeltaBatch(generation:record.generation, base_revision:String(Int(record.revision)!+i), restore_epoch:record.restore_epoch,
                    batch_id:UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(), ops:[.init(op:"append_log",path:["log"],value:.array([event]))])
                _ = try await api.submitStateDelta(batch, expectedToken:token)
            }
            var components = URLComponents(url:Config.apiBase!.appendingPathComponent("api/v1/me/state/changes"), resolvingAgainstBaseURL:false)!
            components.queryItems = [URLQueryItem(name:"after",value:record.revision),URLQueryItem(name:"generation",value:record.generation)]
            var request = URLRequest(url:components.url!); request.setValue("Bearer " + token, forHTTPHeaderField:"Authorization")
            let (_, response) = try await URLSession.shared.data(for:request)
            precondition((response as! HTTPURLResponse).statusCode == 410)
            try await api.checkDeltaHead(revision:record.revision, generation:record.generation, expectedToken:token)
            let result = try await api.readStateChanges(baseline:record.server, revision:record.revision, generation:record.generation, restoreEpoch:record.restore_epoch, expectedToken:token)
            guard case .array(let entries)? = result.state["log"] else { fatalError("missing logs") }
            precondition((0..<3).allSatisfy { i in entries.contains { entry in if case .object(let fields) = entry { return fields["word"] == .string("new\(i)") }; return false } })
            _ = try await fixture("state-changes-byte-limit", ["limit":16*1024*1024])
            print("PASS iOS incremental read survives legacy journal eviction")
            return
        }
        if CommandLine.arguments.count == 6 && CommandLine.arguments[1] == "--large-restore-child" {
            guard let token = ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing token") }
            let intent=try JSONDecoder().decode(ExperimentalLargeRestoreIntent.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])))
            let directory=URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true),account=CommandLine.arguments[4]
            let previous=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[5]))
            let api=APIClient.shared;await api.setToken(token)
            _ = try await DeltaSyncCoordinator(directory:directory).beginExperimentalLargeRestore(account:account,token:token,intent:intent,previous:previous)
            return
        }
        if CommandLine.arguments.count == 6 && CommandLine.arguments[1] == "--large-restore-install-child" {
            guard let token=ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing token") }
            let directory=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true),account=CommandLine.arguments[3]
            let previous=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[4]))
            let slot=URL(fileURLWithPath:CommandLine.arguments[5])
            await APIClient.shared.setToken(token)
            try await DeltaSyncCoordinator(directory:directory).installExperimentalLargeRestoreSlot(account:account,token:token,previous:previous) { old,target in
                let current=try JSONDecoder().decode(LearningState.self,from:Data(contentsOf:slot))
                guard current == old else { throw APIError(message:"slot changed") }
                try JSONEncoder().encode(target).write(to:slot,options:.atomic)
                kill(getpid(),SIGKILL)
                throw APIError(message:"termination failed")
            }
            fatalError("installation child did not terminate")
        }
        if CommandLine.arguments.count == 6 && CommandLine.arguments[1] == "--large-restore-baseline-child" {
            guard let token=ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing token") }
            let directory=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true),account=CommandLine.arguments[3]
            let previous=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[4]))
            let slot=URL(fileURLWithPath:CommandLine.arguments[5])
            await APIClient.shared.setToken(token)
            try await DeltaSyncCoordinator(directory:directory).installExperimentalLargeRestoreBaseline(account:account,token:token,previous:previous) { target in
                guard try JSONDecoder().decode(LearningState.self,from:Data(contentsOf:slot)) == target else { throw APIError(message:"slot changed") }
            }
            kill(getpid(),SIGKILL);fatalError("termination failed")
        }
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--large-restore-cleanup-child" {
            let directory=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true),account=CommandLine.arguments[3]
            let step=Int(CommandLine.arguments[4])!, store=ExperimentalLargeRestoreStore(directory:directory,accountID:account)
            guard let record=try store.load(),let plan=try store.loadInstallation(record:record) else { fatalError("missing cleanup inputs") }
            try DeltaStateStore(directory:directory,accountID:account).requireExperimentalRestoreBaseline(plan:plan)
            let final=try store.stageFinalization(record:record,plan:plan)
            try store.finishFinalization(final) { index in if index == step { kill(getpid(),SIGKILL) } }
            fatalError("cleanup child did not terminate")
        }
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--large-restore-interop" {
            guard let token = ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing token") }
            let api=APIClient.shared; await api.setToken(token)
            let snapshot=try await api.storedStateSnapshot(expectedRevision:nil,generation:nil,expectedToken:token)
            let envelope=try JSONSerialization.jsonObject(with:snapshot.payload) as! [String:Any]
            var state=envelope["state"] as! [String:Any], cards=state["cards"] as! [String:Any]
            cards["swift_restored"]=["pos":77];state["cards"]=cards
            let payload=try JSONSerialization.data(withJSONObject:state,options:[.sortedKeys])
            let intent=ExperimentalLargeRestoreIntent(batchID:UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),
                generation:snapshot.generation,baseRevision:snapshot.revision,restoreEpoch:snapshot.restoreEpoch,payload:payload)
            let remote=try await api.pullState(expectedToken:token)
            guard let local=remote.state,let account=ProcessInfo.processInfo.environment["VOCAB_FIXTURE_ACCOUNT"] else { fatalError("missing local state or account") }
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent("vocab-restore-test-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:directory) }
            let syncDirectory=directory.appendingPathComponent("sync",isDirectory:true),coordinator=DeltaSyncCoordinator(directory:syncDirectory)
            try await coordinator.prime(account:account,token:token,remote:remote,local:local)
            let previous=try JSONEncoder().encode(local),previousFile=directory.appendingPathComponent("previous.json")
            var unsynced=local;unsynced.pointer += 1
            do { _ = try await coordinator.beginExperimentalLargeRestore(account:account,token:token,intent:intent,previous:try JSONEncoder().encode(unsynced));fatalError("unsynced view accepted") } catch {}
            let prematureFence=try ExperimentalLargeRestoreStore(directory:syncDirectory,accountID:account).hasFence();precondition(!prematureFence)
            try previous.write(to:previousFile,options:.atomic)
            let file=directory.appendingPathComponent("intent.json");try JSONEncoder().encode(intent).write(to:file,options:.atomic)
            _ = try await fixture("delta-hold-response",[:])
            let child=Process();child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0],relativeTo:URL(fileURLWithPath:FileManager.default.currentDirectoryPath,isDirectory:true)).standardizedFileURL
            child.arguments=["--large-restore-child",file.path,syncDirectory.path,account,previousFile.path];child.environment=ProcessInfo.processInfo.environment.merging(["VOCAB_FIXTURE_TOKEN":token]) { _,new in new }
            try child.run();try await waitForHold();kill(child.processIdentifier,SIGKILL);child.waitUntilExit();_ = try await fixture("delta-release-response",[:])
            let saved=try await coordinator.pendingExperimentalLargeRestore(account:account);precondition(saved?.intent==intent && saved?.previous==previous)
            let initialPhase=try await coordinator.experimentalLargeRestoreResume(account:account);precondition(initialPhase?.phase == .installSlot && initialPhase?.previous == previous)
            do { _ = try DeltaStateStore(directory:syncDirectory,accountID:account).load();fatalError("unresolved restore did not fence sync") } catch {}
            do { try await coordinator.push(account:account,token:token,target:local);fatalError("pending restore allowed ordinary sync") }
            catch let error as APIError { precondition(error.message.contains("未完成")) }
            let otherFenced=try ExperimentalLargeRestoreStore(directory:syncDirectory,accountID:String(repeating:"f",count:32)).hasFence();precondition(!otherFenced)
            let different=previous+Data(" ".utf8)
            do { _ = try await coordinator.resumeExperimentalLargeRestore(account:account,token:token,previous:different);fatalError("changed local state accepted") } catch {}
            let baselineURL=syncDirectory.appendingPathComponent("delta-\(account).json"),baseline=try Data(contentsOf:baselineURL)
            try (baseline+Data(" ".utf8)).write(to:baselineURL,options:.atomic)
            do { _ = try await coordinator.resumeExperimentalLargeRestore(account:account,token:token,previous:previous);fatalError("changed sync baseline accepted") } catch {}
            try baseline.write(to:baselineURL,options:.atomic)
            let first=try await coordinator.resumeExperimentalLargeRestore(account:account,token:token,previous:previous)
            await api.releaseStagedStateDelta(batchID:intent.batchID,expectedToken:token)
            let retry=try await coordinator.resumeExperimentalLargeRestore(account:account,token:token,previous:previous);precondition(first==retry)
            var changed=state;changed["probeCount"]=999
            let altered=ExperimentalLargeRestoreIntent(batchID:intent.batchID,generation:intent.generation,baseRevision:intent.baseRevision,
                restoreEpoch:intent.restoreEpoch,payload:try JSONSerialization.data(withJSONObject:changed,options:[.sortedKeys]))
            do { _ = try await api.submitExperimentalLargeRestore(altered,expectedToken:token); fatalError("wrong payload accepted") } catch {}
            let verified=try await coordinator.verifyExperimentalLargeRestore(account:account,token:token,previous:previous)
            precondition(verified.receipt == first && verified.local.cards["swift_restored"] != nil && (verified.local.restoreEpoch ?? 0) == first.restore_epoch)
            let exported=try await coordinator.rawExperimentalLargeRestoreRecord(account:account)
            guard let exported else { fatalError("missing recovery export") }
            let exportedRecord=try JSONDecoder().decode(ExperimentalLargeRestoreRecord.self,from:exported)
            precondition(exportedRecord.intent == intent)
            let recoveryURL=syncDirectory.appendingPathComponent("large-restore-\(account).json")
            let damaged=Data("{damaged".utf8);try damaged.write(to:recoveryURL,options:.atomic)
            do { _ = try await coordinator.pendingExperimentalLargeRestore(account:account);fatalError("corrupt restore record accepted") } catch {}
            let damagedExport=try await coordinator.rawExperimentalLargeRestoreRecord(account:account);precondition(damagedExport == damaged)
            try exported.write(to:recoveryURL,options:.atomic)
            let slot=directory.appendingPathComponent("slot.json");try previous.write(to:slot,options:.atomic)
            let installChild=Process(); installChild.executableURL=child.executableURL
            installChild.arguments=["--large-restore-install-child",syncDirectory.path,account,previousFile.path,slot.path]
            installChild.environment=ProcessInfo.processInfo.environment.merging(["VOCAB_FIXTURE_TOKEN":token]) { _,new in new }
            try installChild.run();installChild.waitUntilExit()
            precondition(installChild.terminationReason == .uncaughtSignal && installChild.terminationStatus == SIGKILL)
            let installStore=ExperimentalLargeRestoreStore(directory:syncDirectory,accountID:account)
            guard let pendingRecord=try installStore.load(),let plan=try installStore.loadInstallation(record:pendingRecord) else { fatalError("missing installation journal") }
            precondition(plan.revision == first.state_revision && plan.restoreEpoch == first.restore_epoch)
            let newCoordinator=DeltaSyncCoordinator(directory:syncDirectory)
            try await newCoordinator.installExperimentalLargeRestoreSlot(account:account,token:token,previous:previous) { old,target in
                let current=try JSONDecoder().decode(LearningState.self,from:Data(contentsOf:slot))
                guard current == old || current == target else { throw APIError(message:"slot changed") }
                if current == old { try JSONEncoder().encode(target).write(to:slot,options:.atomic) }
            }
            let installed=try JSONDecoder().decode(LearningState.self,from:Data(contentsOf:slot))
            precondition(installed.cards["swift_restored"] != nil)
            let planURL=syncDirectory.appendingPathComponent("large-restore-\(account).install"),planBytes=try Data(contentsOf:planURL)
            try Data("corrupt".utf8).write(to:planURL,options:.atomic)
            do { _ = try installStore.loadInstallation(record:pendingRecord);fatalError("damaged installation accepted") } catch {}
            try planBytes.write(to:planURL,options:.atomic)
            do { _ = try DeltaStateStore(directory:syncDirectory,accountID:account).load();fatalError("unfinished installation released fence") } catch {}
            // A changed primary slot cannot authorize a baseline replacement.
            try previous.write(to:slot,options:.atomic)
            do {
                try await newCoordinator.installExperimentalLargeRestoreBaseline(account:account,token:token,previous:previous) { target in
                    guard try JSONDecoder().decode(LearningState.self,from:Data(contentsOf:slot)) == target else { throw APIError(message:"slot changed") }
                }
                fatalError("changed slot authorized baseline replacement")
            } catch let error as APIError { precondition(error.message == "slot changed") }
            let unchangedBaseline=try Data(contentsOf:baselineURL);precondition(unchangedBaseline == baseline)
            try JSONEncoder().encode(installed).write(to:slot,options:.atomic)
            try (baseline+Data(" ".utf8)).write(to:baselineURL,options:.atomic)
            do { try DeltaStateStore(directory:syncDirectory,accountID:account).installExperimentalRestoreBaseline(record:pendingRecord,plan:plan);fatalError("changed baseline accepted") } catch {}
            try baseline.write(to:baselineURL,options:.atomic)
            let baselineChild=Process();baselineChild.executableURL=child.executableURL
            baselineChild.arguments=["--large-restore-baseline-child",syncDirectory.path,account,previousFile.path,slot.path]
            baselineChild.environment=ProcessInfo.processInfo.environment.merging(["VOCAB_FIXTURE_TOKEN":token]) { _,new in new }
            try baselineChild.run();baselineChild.waitUntilExit()
            precondition(baselineChild.terminationReason == .uncaughtSignal && baselineChild.terminationStatus == SIGKILL)
            let baselinePhase=try await newCoordinator.experimentalLargeRestoreResume(account:account);precondition(baselinePhase?.phase == .finalize && baselinePhase?.previous == previous)
            let newRaw=try Data(contentsOf:baselineURL)
            let newRecord=try JSONDecoder().decode(StoredDeltaRecord.self,from:newRaw)
            precondition(newRecord.revision == first.state_revision && newRecord.restore_epoch == first.restore_epoch && newRecord.server == plan.server)
            try await DeltaSyncCoordinator(directory:syncDirectory).installExperimentalLargeRestoreBaseline(account:account,token:token,previous:previous) { target in
                guard try JSONDecoder().decode(LearningState.self,from:Data(contentsOf:slot)) == target else { throw APIError(message:"slot changed") }
            }
            let retriedBaseline=try Data(contentsOf:baselineURL);precondition(retriedBaseline == newRaw)
            for step in 1...3 {
                let copy=directory.appendingPathComponent("cleanup-\(step)",isDirectory:true)
                try FileManager.default.copyItem(at:syncDirectory,to:copy)
                let cleanupChild=Process();cleanupChild.executableURL=child.executableURL
                cleanupChild.arguments=["--large-restore-cleanup-child",copy.path,account,String(step)]
                try cleanupChild.run();cleanupChild.waitUntilExit()
                precondition(cleanupChild.terminationReason == .uncaughtSignal && cleanupChild.terminationStatus == SIGKILL)
                let copyStore=ExperimentalLargeRestoreStore(directory:copy,accountID:account)
                guard let journal=try copyStore.loadFinalization(),try copyStore.hasFence() else { fatalError("cleanup lost fence") }
                do { _ = try DeltaStateStore(directory:copy,accountID:account).load();fatalError("interrupted cleanup allowed sync") } catch {}
                try DeltaStateStore(directory:copy,accountID:account).requireExperimentalRestoreBaseline(plan:journal.plan)
                if step == 1 {
                    let recoveredPhase=try await DeltaSyncCoordinator(directory:copy).experimentalLargeRestoreResume(account:account)
                    precondition(recoveredPhase?.phase == .finalize && recoveredPhase?.previous == previous)
                    let finalExport=try await DeltaSyncCoordinator(directory:copy).rawExperimentalLargeRestoreRecord(account:account)
                    guard let finalExport else { fatalError("missing partial-cleanup export") }
                    let decodedFinal=try JSONDecoder().decode(ExperimentalLargeRestoreFinalization.self,from:finalExport)
                    precondition(decodedFinal == journal)
                    try await DeltaSyncCoordinator(directory:copy).finalizeExperimentalLargeRestore(account:account,token:token,previous:previous) { target in
                        guard try JSONDecoder().decode(LearningState.self,from:Data(contentsOf:slot)) == target else { throw APIError(message:"slot changed") }
                        try syncSlot(slot)
                    }
                } else { try copyStore.finishFinalization(journal) }
                let copyFenced=try copyStore.hasFence();precondition(!copyFenced)
                let complete=try DeltaStateStore(directory:copy,accountID:account).load()
                precondition(complete?.revision == first.state_revision)
            }
            // Changing a journal, archive, or already-removed file between
            // cleanup steps must fail closed and retain the recovery fence.
            for kind in ["final","archive","record"] {
                let copy=directory.appendingPathComponent("tamper-\(kind)",isDirectory:true)
                try FileManager.default.copyItem(at:syncDirectory,to:copy)
                let copyStore=ExperimentalLargeRestoreStore(directory:copy,accountID:account)
                guard let copyRecord=try copyStore.load(),let copyPlan=try copyStore.loadInstallation(record:copyRecord) else { fatalError("missing tamper setup") }
                let final=try copyStore.stageFinalization(record:copyRecord,plan:copyPlan)
                let name: String
                switch kind {
                case "final": name="large-restore-\(account).final"
                case "archive": name="before-large-restore-\(account)-\(intent.batchID).json"
                default: name="large-restore-\(account).json"
                }
                do {
                    try copyStore.finishFinalization(final) { index in
                        if index == 1 { try Data("changed".utf8).write(to:copy.appendingPathComponent(name),options:.atomic) }
                    }
                    fatalError("changed cleanup input accepted")
                } catch {}
                let fenced=try copyStore.hasFence();precondition(fenced)
                do { _ = try DeltaStateStore(directory:copy,accountID:account).load();fatalError("tampered cleanup allowed sync") } catch {}
            }
            do {
                try await newCoordinator.finalizeExperimentalLargeRestore(account:account,token:token,previous:previous) { _ in throw APIError(message:"slot changed") }
                fatalError("changed slot finalized")
            } catch let error as APIError { precondition(error.message == "slot changed") }
            let beforeFinalFence=try installStore.hasFence();precondition(beforeFinalFence)
            try await newCoordinator.finalizeExperimentalLargeRestore(account:account,token:token,previous:previous) { target in
                guard try JSONDecoder().decode(LearningState.self,from:Data(contentsOf:slot)) == target else { throw APIError(message:"slot changed") }
                try syncSlot(slot)
            }
            let afterFinalFence=try installStore.hasFence();precondition(!afterFinalFence)
            let finishedPhase=try await newCoordinator.experimentalLargeRestoreResume(account:account);precondition(finishedPhase == nil)
            let archive=syncDirectory.appendingPathComponent("before-large-restore-\(account)-\(intent.batchID).json")
            let archived=try Data(contentsOf:archive);precondition(archived == previous)
            let finalized=try DeltaStateStore(directory:syncDirectory,accountID:account).load()
            precondition(finalized?.revision == first.state_revision && finalized?.restore_epoch == first.restore_epoch)
            let advance=StateDeltaBatch(generation:first.generation,base_revision:first.state_revision,restore_epoch:first.restore_epoch,
                batch_id:UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),ops:[StateDeltaOperation(op:"set",path:["probeCount"],value:.integer(7))])
            _ = try await api.submitStateDelta(advance,expectedToken:token,experimentalLarge:true)
            // A stale revision is still detectable after finalization.
            do { try await api.checkDeltaHead(revision:first.state_revision,generation:first.generation,expectedToken:token,requireCurrent:true);fatalError("historical receipt accepted as current head") }
            catch let error as APIError { precondition(error.statusCode == 409 || error.message.contains("变化")) }
            let result=try await api.storedStateSnapshot(expectedRevision:nil,generation:nil,expectedToken:token)
            let restored=(try JSONSerialization.jsonObject(with:result.payload) as! [String:Any])["state"] as! [String:Any]
            precondition((restored["cards"] as! [String:Any])["swift_restored"] != nil && result.restoreEpoch==first.restore_epoch)
            print("PASS Swift staged large restore, retained receipt and payload mismatch fence")
            return
        }
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--write-normal-prepared" {
            guard let token = ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing token") }
            let api = APIClient.shared; await api.setToken(token)
            let batch = StateDeltaBatch(generation:CommandLine.arguments[2], base_revision:CommandLine.arguments[3], restore_epoch:0,
                batch_id:UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),
                ops:[StateDeltaOperation(op:"set",path:["cards","banana"],value:.object(["pos":.integer(2),"stage":.integer(1),"due":.string("2099-01-01T00:00:00Z")]))])
            let receipt = try await api.submitStateDelta(batch,expectedToken:token)
            print("PASS Swift writes ordinary delta \(receipt.state_revision)")
            return
        }
        if CommandLine.arguments.count == 4 && ["--verify-large-roundtrip", "--verify-large-rebase", "--verify-web-restore", "--verify-web-restore-removed", "--verify-web-large-checkpoint", "--verify-web-checkpoint-cancel", "--verify-web-restore-cancel", "--verify-normal-prepared-upload"].contains(CommandLine.arguments[1]) {
            guard let token = ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing token") }
            let api = APIClient.shared; await api.setToken(token)
            let snapshot = try await api.storedStateSnapshot(expectedRevision:CommandLine.arguments[2], generation:CommandLine.arguments[3], expectedToken:token)
            let envelope = try JSONSerialization.jsonObject(with:snapshot.payload) as! [String:Any]
            let state = envelope["state"] as! [String:Any], cards = state["cards"] as! [String:Any]
            if CommandLine.arguments[1] == "--verify-normal-prepared-upload" {
                precondition(snapshot.restoreEpoch == 0 && cards["apple"] != nil && cards["pear"] != nil)
                print("PASS Swift verifies ordinary prepared Web upload")
            } else if CommandLine.arguments[1] == "--verify-web-restore-cancel" {
                precondition(snapshot.restoreEpoch == 0 && cards["apple"] != nil && cards["web_restore"] == nil)
                print("PASS Swift verifies preserved Web restore cancellation state")
            } else if CommandLine.arguments[1] == "--verify-web-checkpoint-cancel" {
                precondition(snapshot.restoreEpoch == 0 && snapshot.payload.count > 8 * 1024 * 1024 && cards["apple"] != nil && (state["fixtureLarge"] as? String)?.count == 8 * 1024 * 1024 + 65536)
                print("PASS Swift verifies preserved Web checkpoint cancellation state")
            } else if CommandLine.arguments[1] == "--verify-web-large-checkpoint" {
                let evidence = (state["knowledgeEvidence"] as? [String:Any])?["checkpointcase"] as? [String:Any]
                let events = evidence?["events"] as? [String:Any]
                precondition(snapshot.restoreEpoch == 1 && snapshot.payload.count > 8 * 1024 * 1024 && events?.isEmpty == true)
                print("PASS Swift verifies Web large checkpoint")
            } else if CommandLine.arguments[1] == "--verify-web-restore-removed" {
                precondition(cards["web_restore"] == nil && snapshot.restoreEpoch == 2 && snapshot.payload.count > 8 * 1024 * 1024)
                print("PASS Swift verifies Web file restore after browser restart")
            } else if CommandLine.arguments[1] == "--verify-web-restore" {
                precondition(cards["web_restore"] != nil && snapshot.restoreEpoch == 1 && snapshot.payload.count > 8 * 1024 * 1024)
                print("PASS Swift verifies Web large restore")
            } else if CommandLine.arguments[1] == "--verify-large-rebase" {
                let kiwi = cards["kiwi"] as? [String:Any]
                precondition(cards["swift_large"] != nil && kiwi?["fsrs"] != nil && kiwi?["pendingFsrs"] == nil && snapshot.payload.count > 8 * 1024 * 1024)
                print("PASS Swift verifies rebased large-state changes")
            } else {
                precondition(cards["swift_large"] != nil && cards["web_large"] != nil && snapshot.payload.count > 8 * 1024 * 1024)
                print("PASS Swift verifies Web and Swift large-state changes")
            }
            return
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--large-web-interop" {
            guard let token = ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing token") }
            let account = CommandLine.arguments[2], api = APIClient.shared
            await api.setToken(token)
            let remote = try await api.pullState(expectedToken: token)
            guard remote.fromLargeSnapshot, var target = remote.state else { fatalError("missing oversized baseline") }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-large-web-" + UUID().uuidString, isDirectory:true)
            defer { try? FileManager.default.removeItem(at:directory) }
            let coordinator = DeltaSyncCoordinator(directory:directory)
            try await coordinator.prime(account:account, token:token, remote:remote, local:target)
            target.cards["swift_large"] = CardState(stage:1,due:nil,lt:nil,pos:10,fsrs:nil)
            try await coordinator.push(account:account,token:token,target:target)
            print("PASS Swift uploads into Web-origin large state")
            return
        }
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--read-web-large" {
            guard let token = ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing token") }
            let api = APIClient.shared; await api.setToken(token)
            let snapshot = try await api.storedStateSnapshot(expectedRevision: CommandLine.arguments[2], generation: CommandLine.arguments[3], expectedToken: token)
            let envelope = try JSONSerialization.jsonObject(with: snapshot.payload) as! [String: Any]
            let state = envelope["state"] as! [String: Any], cards = state["cards"] as! [String: Any]
            let card = cards["large_test"] as! [String: Any]
            precondition((card["extra"] as? String)?.count == 9 * 1024 * 1024)
            print("PASS iOS verifies Web experimental large upload")
            return
        }
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--read-large" {
            guard let token = ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing token") }
            let api = APIClient.shared; await api.setToken(token)
            let snapshot = try await api.storedStateSnapshot(expectedRevision: CommandLine.arguments[2], generation: CommandLine.arguments[3], expectedToken: token)
            precondition(snapshot.payload.count > 8 * 1024 * 1024)
            let envelope = try JSONSerialization.jsonObject(with: snapshot.payload) as! [String: Any]
            let state = envelope["state"] as! [String: Any]
            precondition((state["fixtureLarge"] as? String)?.count == 8 * 1024 * 1024 + 65536)
            print("PASS iOS transport verifies a paged oversized stored snapshot")
            return
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--seed-server-large" {
            guard let token=ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing token") }
            let account=CommandLine.arguments[2], api=APIClient.shared
            await api.setToken(token)
            let prior=try await api.pullState(expectedToken:token)
            guard var initial=prior.state else { fatalError("missing fixture state") }
            initial.personalizedWeak=String(repeating:"x",count:7*1024*1024)
            try await api.pushState(initial,expectedToken:token)
            let remote=try await api.pullState(expectedToken:token)
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent("vocab-seed-large-"+UUID().uuidString,isDirectory:true)
            defer { try? FileManager.default.removeItem(at:directory) }
            let coordinator=DeltaSyncCoordinator(directory:directory)
            try await coordinator.prime(account:account,token:token,remote:remote,local:initial)
            var target=initial;target.personalized["apple"]=PersonalizedSentence(text:String(repeating:"y",count:2100*1024))
            try await coordinator.push(account:account,token:token,target:target)
            print("PASS seeded large server state for a fresh device")
            return
        }
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--seed-ui-large-restore" {
            guard let token=ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing token") }
            let documents=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true),account=CommandLine.arguments[3],api=APIClient.shared
            await api.setToken(token)
            let prior=try await api.pullState(expectedToken:token)
            guard var initial=prior.state else { fatalError("missing fixture state") }
            initial.personalizedWeak=String(repeating:"x",count:7*1024*1024)
            try await api.pushState(initial,expectedToken:token)
            let remote=try await api.pullState(expectedToken:token)
            let directory=documents.appendingPathComponent("VocabDelta",isDirectory:true),coordinator=DeltaSyncCoordinator(directory:directory)
            try await coordinator.prime(account:account,token:token,remote:remote,local:initial)
            var local=initial;local.personalized["apple"]=PersonalizedSentence(text:String(repeating:"y",count:2100*1024))
            try await coordinator.push(account:account,token:token,target:local)
            let previous=try JSONEncoder().encode(local)
            guard previous.count > 8*1024*1024, let record=try DeltaStateStore(directory:directory,accountID:account).load() else { fatalError("missing large baseline") }
            var restored=local;restored.cards["restore_ui_marker"]=CardState(stage:1,due:nil,lt:nil,pos:77,fsrs:nil)
            let payload=try JSONEncoder().encode(restored)
            let intent=ExperimentalLargeRestoreIntent(batchID:UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),generation:record.generation,baseRevision:record.revision,restoreEpoch:record.restore_epoch,payload:payload)
            try FileManager.default.createDirectory(at:documents,withIntermediateDirectories:true)
            try previous.write(to:documents.appendingPathComponent("vocab_state_a\(account).json"),options:.atomic)
            try account.write(to:documents.appendingPathComponent("vocab_state_a\(account).user"),atomically:true,encoding:.utf8)
            _ = try await coordinator.beginExperimentalLargeRestore(account:account,token:token,intent:intent,previous:previous)
            print("PASS seeded committed large restore and original signed slot")
            return
        }
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--seed-ui-large" {
            guard let token = ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing token") }
            let documents=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true), account=CommandLine.arguments[3], api=APIClient.shared
            await api.setToken(token)
            let prior=try await api.pullState(expectedToken:token)
            guard var initial=prior.state else { fatalError("missing fixture state") }
            initial.personalizedWeak=String(repeating:"x",count:7*1024*1024)
            try await api.pushState(initial,expectedToken:token)
            let remote=try await api.pullState(expectedToken:token)
            let directory=documents.appendingPathComponent("VocabDelta",isDirectory:true)
            let coordinator=DeltaSyncCoordinator(directory:directory)
            try await coordinator.prime(account:account,token:token,remote:remote,local:initial)
            var target=initial;target.personalized["apple"]=PersonalizedSentence(text:String(repeating:"y",count:2100*1024))
            let data=try JSONEncoder().encode(target)
            guard case .object(let value)=try StateDelta.decode(data) else { fatalError("invalid target") }
            let store=DeltaStateStore(directory:directory,accountID:account), record=try store.load()!
            let operations=StateDelta.diff(local:record.local,target:value,server:record.server)!
            let batch=StateDeltaBatch(generation:record.generation,base_revision:record.revision,restore_epoch:record.restore_epoch,
                batch_id:UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),ops:operations)
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
            let bytes=try encoder.encode(operations);precondition(data.count>8*1024*1024 && bytes.count>1900*1024)
            try store.stage(PendingStateDelta(batch:batch,target:data,stagedPayload:bytes,experimentalLarge:true))
            try FileManager.default.createDirectory(at:documents,withIntermediateDirectories:true)
            try data.write(to:documents.appendingPathComponent("vocab_state_a\(account).json"),options:.atomic)
            try account.write(to:documents.appendingPathComponent("vocab_state_a\(account).user"),atomically:true,encoding:.utf8)
            print("PASS seeded experimental large pending upload")
            return
        }
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--seed-ui" {
            guard let token = ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing token") }
            let documents = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true), account = CommandLine.arguments[3]
            let api = APIClient.shared; await api.setToken(token)
            let remote = try await api.pullState(expectedToken: token)
            guard let initial = remote.state else { fatalError("missing fixture state") }
            let directory = documents.appendingPathComponent("VocabDelta", isDirectory: true)
            let coordinator = DeltaSyncCoordinator(directory: directory)
            try await coordinator.prime(account: account, token: token, remote: remote, local: initial)
            var target = initial; target.personalizedDay = "2099-01-01"; target.personalizedWeak = String(repeating: "s", count: 2100 * 1024)
            for i in 0..<2100 { target.cards[String(format:"ui_bulk_%04d", i)] = CardState(stage:1, due:nil, lt:nil, pos:i+2, fsrs:nil) }
            let data = try JSONEncoder().encode(target)
            guard case .object(let object) = try StateDelta.decode(data) else { fatalError("target") }
            let store = DeltaStateStore(directory: directory, accountID: account), record = try store.load()!
            let operations = StateDelta.diff(local: record.local, target: object, server: record.server)!
            let batch = StateDeltaBatch(generation: record.generation, base_revision: record.revision, restore_epoch: record.restore_epoch,
                                        batch_id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), ops: operations)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let bytes = try encoder.encode(operations); precondition(bytes.count > 1900 * 1024 && operations.count > 2048)
            try store.stage(PendingStateDelta(batch: batch, target: data, stagedPayload: bytes))
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            try data.write(to: documents.appendingPathComponent("vocab_state_a\(account).json"), options: .atomic)
            try account.write(to: documents.appendingPathComponent("vocab_state_a\(account).user"), atomically: true, encoding: .utf8)
            print("PASS seeded staged upload in disposable simulator container")
            return
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--interop-multiops" {
            guard let token = ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing token") }
            let account = CommandLine.arguments[2], api = APIClient.shared
            await api.setToken(token)
            let remote = try await api.pullState(expectedToken: token)
            guard var next = remote.state, next.cards.count >= 2501 else { fatalError("Web cards missing") }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-ios-multiops-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let coordinator = DeltaSyncCoordinator(directory: directory)
            try await coordinator.prime(account: account, token: token, remote: remote, local: next)
            for i in 0..<2100 { next.cards[String(format:"swift_bulk_%04d", i)] = CardState(stage:1, due:nil, lt:nil, pos:i+4000, fsrs:nil) }
            try await coordinator.push(account: account, token: token, target: next)
            let result = try await api.pullState(expectedToken: token)
            precondition((result.state?.cards.count ?? 0) >= 4601)
            print("PASS iOS uploads 2100 Web-origin changes through staging")
            return
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--interop" {
            guard let token = ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing token") }
            let account = CommandLine.arguments[2], api = APIClient.shared
            await api.setToken(token)
            let remote = try await api.pullState(expectedToken: token)
            guard var next = remote.state, next.personalizedWeak?.first == "x" else { fatalError("Web state missing") }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-ios-interop-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let coordinator = DeltaSyncCoordinator(directory: directory)
            try await coordinator.prime(account: account, token: token, remote: remote, local: next)
            next.personalizedDay = "2099-01-02"; next.personalizedWeak = String(repeating: "y", count: 2100 * 1024)
            next.log.append(LogEntry(d: "2026-10-27", word: "swift-interop", rating: 4, kind: "review"))
            try await coordinator.push(account: account, token: token, target: next)
            next.log.append(LogEntry(d: "2026-10-27", word: "swift-compact", rating: 3, kind: "review"))
            try await coordinator.push(account: account, token: token, target: next)
            let result = try await api.pullState(expectedToken: token)
            precondition(result.state?.personalizedWeak == next.personalizedWeak)
            print("PASS iOS uploads Web-origin state with staged delta")
            return
        }
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--child" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let account = CommandLine.arguments[3], file = URL(fileURLWithPath: CommandLine.arguments[4])
            guard let token = ProcessInfo.processInfo.environment["VOCAB_FIXTURE_TOKEN"] else { fatalError("missing token") }
            await APIClient.shared.setToken(token)
            let target = try JSONDecoder().decode(LearningState.self, from: Data(contentsOf: file))
            try await DeltaSyncCoordinator(directory: directory).push(account: account, token: token, target: target)
            return
        }
        let api = APIClient.shared
        let user = try await api.register(username: "is_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased(), password: "test_password_123", nickname: "")
        let account = user.user.account_id!, token = user.token
        await api.setToken(token)
        try await api.pushState(LearningState(), expectedToken: token)
        let initial = try await api.pullState(expectedToken: token)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-ios-stage-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DeltaSyncCoordinator(directory: root)
        try await coordinator.prime(account: account, token: token, remote: initial, local: initial.state!)
        var first = initial.state!; first.personalizedDay = "2099-01-01"; first.personalizedWeak = String(repeating: "x", count: 2100 * 1024)
        let targetData = try JSONEncoder().encode(first)
        guard case .object(let target) = try StateDelta.decode(targetData) else { fatalError("target") }
        let store = DeltaStateStore(directory: root, accountID: account), record = try store.load()!
        let ops = StateDelta.diff(local: record.local, target: target, server: record.server)!
        let batch = StateDeltaBatch(generation: record.generation, base_revision: record.revision, restore_epoch: record.restore_epoch,
                                    batch_id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), ops: ops)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(ops); precondition(bytes.count > 1900 * 1024)
        let invalidBytes = try encoder.encode([StateDeltaOperation(op: "set", path: ["cards", "bad"], value: .object([:]))])
        do { try store.stage(PendingStateDelta(batch: batch, target: targetData, stagedPayload: invalidBytes)); fatalError("corrupt staged bytes accepted") }
        catch { let unchanged = try store.load()!; precondition(unchanged.pending == nil) }
        try store.stage(PendingStateDelta(batch: batch, target: targetData, stagedPayload: bytes))
        let targetFile = root.appendingPathComponent("target.json"); try targetData.write(to: targetFile, options: .atomic)
        _ = try await fixture("delta-hold-response", [:])
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)).standardizedFileURL; child.arguments = ["--child", root.path, account, targetFile.path]
        child.environment = ProcessInfo.processInfo.environment.merging(["VOCAB_FIXTURE_TOKEN":token]) { _, new in new }
        try child.run(); try await waitForHold()
        let committed = try await api.pullState(expectedToken: token)
        precondition(committed.state?.personalizedWeak?.count == 2100 * 1024)
        kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
        _ = try await fixture("delta-release-response", [:])
        let durable = try store.load()!; precondition(durable.pending?.batch.batch_id == batch.batch_id && durable.pending?.stagedPayload == bytes)
        try await coordinator.push(account: account, token: token, target: first)
        let recovered = try await api.pullState(expectedToken: token)
        precondition(recovered.state_revision == committed.state_revision && recovered.state?.personalizedWeak == first.personalizedWeak)
        let afterReplay = try store.load()!; precondition(afterReplay.pending == nil)
        let appendSupported = try await api.supportsLogAppend(expectedToken: token)
        precondition(appendSupported)
        first.log.append(LogEntry(d: "2026-10-27", word: "apple", rating: 4, kind: "review"))
        guard case .object(let logTarget) = try StateDelta.decode(JSONEncoder().encode(first)) else { fatalError("target") }
        let logOps = StateDelta.diff(local: afterReplay.local, target: logTarget, server: afterReplay.server, appendLog: true)!
        precondition(logOps.contains { $0.op == "append_log" && $0.path == ["log"] })
        precondition(StateDelta.diff(local: afterReplay.local, target: logTarget, server: afterReplay.server)!.contains { $0.op == "set" && $0.path == ["log"] })
        let spliceBase: [String:DeltaJSON] = ["log":.array([.integer(1),.integer(3)])]
        let splice = StateDeltaOperation(op:"splice_log", path:["log"], value:.object(["index":.integer(1),"delete":.integer(0),"items":.array([.integer(2)])]))
        let spliced = try StateDelta.apply([splice], to: spliceBase)
        precondition(spliced["log"] == .array([.integer(1),.integer(2),.integer(3)]))
        let invalidSplice = StateDeltaOperation(op:"splice_log", path:["log"], value:.object(["index":.integer(3),"delete":.integer(1),"items":.array([])]))
        do { _ = try StateDelta.apply([invalidSplice], to: spliceBase); fatalError("invalid splice accepted") } catch {}
        try await coordinator.push(account: account, token: token, target: first)
        let logResult = try await api.pullState(expectedToken: token)
        precondition(logResult.state?.log.contains { $0.eventId == first.log.last?.eventId } == true)
        _ = try await fixture("delta-capabilities-disabled", ["disabled":true])
        let legacySupportsAppend = try await api.supportsLogAppend(expectedToken: token)
        precondition(!legacySupportsAppend)
        first.log.append(LogEntry(d: "2026-10-27", word: "pear", rating: 3, kind: "review"))
        try await coordinator.push(account: account, token: token, target: first)
        _ = try await fixture("delta-capabilities-disabled", ["disabled":false])
        let legacyLogResult = try await api.pullState(expectedToken: token)
        precondition(legacyLogResult.state?.log.contains { $0.eventId == first.log.last?.eventId } == true)
        // Old servers lack the staged endpoint; fallback still uses the generation fence.
        _ = try await fixture("delta-stages-disabled", ["disabled":true])
        var fallback = first; fallback.personalizedDay = "2099-01-02"; fallback.personalizedWeak = String(repeating: "y", count: 2100 * 1024)
        try await coordinator.push(account: account, token: token, target: fallback)
        _ = try await fixture("delta-stages-disabled", ["disabled":false])
        let fallbackResult = try await api.pullState(expectedToken: token)
        precondition(fallbackResult.state?.personalizedWeak == fallback.personalizedWeak)
        // A committed response arriving after account switch cannot acknowledge
        // the old account; replay must not create a second server revision.
        var next = fallback; next.personalizedDay = "2099-01-03"; next.personalizedWeak = String(repeating: "z", count: 2100 * 1024)
        _ = try await fixture("delta-hold-response", [:])
        let operation = Task { try await coordinator.push(account: account, token: token, target: next) }
        try await waitForHold(); let afterCommit = try await api.pullState(expectedToken: token)
        _ = try await fixture("delta-held-error", [:])
        await api.setToken("other-session-token")
        _ = try await fixture("delta-release-response", [:])
        do { try await operation.value; fatalError("switched session accepted") } catch let error as APIError { precondition(error.message.contains("账号已切换")) }
        let afterSwitch = try store.load()!; precondition(afterSwitch.pending?.stagedPayload != nil)
        let pendingDisk = try JSONSerialization.jsonObject(with: store.rawRecord()!) as! [String:Any]
        precondition(pendingDisk["localFromServer"] != nil && pendingDisk["local"] == nil)
        await api.setToken(token); try await coordinator.push(account: account, token: token, target: next)
        let final = try await api.pullState(expectedToken: token)
        precondition(final.state_revision == afterCommit.state_revision && final.state?.personalizedWeak == next.personalizedWeak)
        // A previous staging server has no operation-capability field. More
        // than 2048 operations must fall back before sending any parts.
        var oldCapacityTarget = next
        for i in 0..<2100 {
            oldCapacityTarget.cards[String(format:"legacy_cap_%04d", i)] = CardState(stage:1, due:nil, lt:nil, pos:i+2, fsrs:nil)
        }
        let beforeCapacity = try await fixture("state-upload-status")
        _ = try await fixture("delta-stage-legacy-cap", ["enabled":true])
        try await coordinator.push(account: account, token: token, target: oldCapacityTarget)
        _ = try await fixture("delta-stage-legacy-cap", ["enabled":false])
        let afterCapacity = try await fixture("state-upload-status")
        precondition((afterCapacity["stage_successes"] as! Int) == (beforeCapacity["stage_successes"] as! Int))
        precondition((afterCapacity["guarded_successes"] as! Int) > (beforeCapacity["guarded_successes"] as! Int))
        let oldCapacityResult = try await api.pullState(expectedToken: token)
        precondition((oldCapacityResult.state?.cards.count ?? 0) >= 2100)
        var excessCards: [String: DeltaJSON] = [:]
        for i in 0..<8193 { excessCards["excess_\(i)"] = .object(["pos":.integer(Int64(i))]) }
        let emptyCards: [String: DeltaJSON] = ["cards":.object([:])]
        let excessTarget: [String: DeltaJSON] = ["cards":.object(excessCards)]
        precondition(StateDelta.diff(local: emptyCards, target: excessTarget, server: emptyCards) == nil)
        print("PASS iOS staged upload process death, session fencing and old-service fallback")
    }
}
