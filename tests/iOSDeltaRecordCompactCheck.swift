import Foundation
import CryptoKit

enum Config { static let apiBase: URL? = URL(string: "http://127.0.0.1:18765") }

@main struct CompactRecordCheck {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-compact-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = String(repeating: "a", count: 32), generation = String(repeating: "b", count: 32)
        let store = DeltaStateStore(directory: dir, accountID: account)
        let old: [String: DeltaJSON] = ["restoreEpoch": .integer(0), "blob": .string(String(repeating: "x", count: 6 * 1024 * 1024))]
        let target: [String: DeltaJSON] = ["restoreEpoch": .integer(0), "blob": .string(String(repeating: "y", count: 6 * 1024 * 1024))]
        let targetBytes = try JSONEncoder().encode(target)
        let bigOld: [String: DeltaJSON] = ["restoreEpoch": .integer(0), "blob": .string(String(repeating:"x",count: 7 * 1024 * 1024 + 512 * 1024))]
        let bigTarget: [String: DeltaJSON] = ["restoreEpoch": .integer(0), "blob": .string(String(repeating:"y",count: 7 * 1024 * 1024 + 512 * 1024))]
        let bigTargetBytes = try JSONEncoder().encode(bigTarget)
        let ops = StateDelta.diff(local: bigOld, target: bigTarget, server: bigOld)!
        let bytes = try JSONEncoder().encode(ops)
        let batch = StateDeltaBatch(generation: generation, base_revision: "1", restore_epoch: 0,
                                    batch_id: String(repeating: "c", count: 32), ops: ops)
        try store.install(generation: generation, revision: "1", restoreEpoch: 0, server: bigOld, local: bigOld)
        try store.stage(PendingStateDelta(batch: batch, target: bigTargetBytes, stagedPayload: bytes))
        let raw = try store.rawRecord()!
        precondition(raw.count < 32 * 1024 * 1024)
        let restored = try store.load()!
        precondition(restored.pending?.batch == batch && restored.pending?.stagedPayload == bytes)
        var disk = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        precondition(disk["local"] == nil && disk["localFromServer"] != nil)
        disk.removeValue(forKey: "localFromServer"); disk["local"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bigOld))
        let previousCompactFormat = try JSONSerialization.data(withJSONObject: disk)
        precondition(previousCompactFormat.count > 32 * 1024 * 1024)
        var pending = disk["pending"] as! [String: Any]
        var header = pending["batch"] as! [String: Any]
        precondition(pending["payloadOps"] as? Bool == true && header["ops"] == nil)
        header["ops"] = try JSONSerialization.jsonObject(with: bytes)
        pending["batch"] = header; pending.removeValue(forKey: "payloadOps"); disk["pending"] = pending
        let legacy = try JSONSerialization.data(withJSONObject: disk)
        precondition(legacy.count > 32 * 1024 * 1024)
        let largePullAccount=String(repeating:"7",count:32)
        let largePullStore=DeltaStateStore(directory:dir,accountID:largePullAccount)
        try largePullStore.install(generation:generation,revision:"1",restoreEpoch:0,server:bigOld,local:bigOld)
        var largePullNext=bigOld; largePullNext["tag"] = .string("词\n🙂")
        let largePrevious=try JSONEncoder().encode(bigOld), largeTarget=try JSONEncoder().encode(largePullNext)
        try largePullStore.stagePull(PendingStatePull(revision:"2",server:largePullNext,previous:largePrevious,target:largeTarget))
        let largePullRaw=try largePullStore.rawRecord()!, largePull=try largePullStore.load()!
        precondition(largePullRaw.count < 32*1024*1024 && largePull.pull?.previous == largePrevious && largePull.pull?.target == largeTarget && largePull.pull?.server == largePullNext)
        var largePullDisk=try JSONSerialization.jsonObject(with:largePullRaw) as! [String:Any]
        precondition(largePullDisk["compactPull"] != nil && largePullDisk["pull"] == nil)
        let packedPull=largePullDisk["compactPull"] as! [String:Any]
        var damagedPull=packedPull; damagedPull["targetDigest"]=String(repeating:"0",count:64)
        largePullDisk["compactPull"]=damagedPull
        let largePullPath=dir.appendingPathComponent("delta-\(largePullAccount).json")
        try JSONSerialization.data(withJSONObject:largePullDisk).write(to:largePullPath,options:.atomic)
        do { _ = try largePullStore.load(); fatalError("damaged compact pull target accepted") } catch {}
        damagedPull=packedPull
        var damagedServer=damagedPull["serverPatch"] as! [String:Any]; damagedServer["digest"]=String(repeating:"0",count:64)
        damagedPull["serverPatch"]=damagedServer; largePullDisk["compactPull"]=damagedPull
        try JSONSerialization.data(withJSONObject:largePullDisk).write(to:largePullPath,options:.atomic)
        do { _ = try largePullStore.load(); fatalError("damaged compact pull baseline accepted") } catch {}
        largePullDisk["compactPull"]=packedPull; largePullDisk["pull"] = [:]
        try JSONSerialization.data(withJSONObject:largePullDisk).write(to:largePullPath,options:.atomic)
        do { _ = try largePullStore.load(); fatalError("conflicting compact pull accepted") } catch {}
        largePullDisk.removeValue(forKey:"compactPull")
        largePullDisk["pull"] = ["revision":"2","server":try JSONSerialization.jsonObject(with:JSONEncoder().encode(largePullNext)),
                                 "previous":largePrevious.base64EncodedString(),"target":largeTarget.base64EncodedString()]
        let legacyLargePull=try JSONSerialization.data(withJSONObject:largePullDisk)
        precondition(legacyLargePull.count > 32*1024*1024)
        // Exercise the old full batch format on a smaller, otherwise identical record.
        let small: [String: DeltaJSON] = ["blob": .string("old")]
        let next: [String: DeltaJSON] = ["blob": .string("new")]
        let patchAccount = String(repeating:"9",count:32)
        let patchStore = DeltaStateStore(directory:dir, accountID:patchAccount)
        let patchServer: [String:DeltaJSON] = ["blob":.string(String(repeating:"x",count:4096)),"cards":.object(["server":.integer(1)])]
        let patchLocal: [String:DeltaJSON] = ["blob":.string(String(repeating:"x",count:4096)),"cards":.object(["local":.integer(2)])]
        var patchTarget=patchLocal; patchTarget["extra"] = .bool(true)
        try patchStore.install(generation:generation,revision:"1",restoreEpoch:0,server:patchServer,local:patchLocal)
        let patchOps=StateDelta.diff(local:patchLocal,target:patchTarget,server:patchServer)!
        let patchBatch=StateDeltaBatch(generation:generation,base_revision:"1",restore_epoch:0,batch_id:String(repeating:"8",count:32),ops:patchOps)
        try patchStore.stage(PendingStateDelta(batch:patchBatch,target:JSONEncoder().encode(patchTarget)))
        let patchPath=dir.appendingPathComponent("delta-\(patchAccount).json")
        let patchData=try patchStore.rawRecord()!
        var patchDisk=try JSONSerialization.jsonObject(with:patchData) as! [String:Any]
        precondition(patchDisk["local"] == nil && patchDisk["localFromServer"] != nil)
        let compactLocalRecord = try patchStore.load()!; precondition(compactLocalRecord.local == patchLocal)
        var altered=patchDisk["localFromServer"] as! [String:Any]; altered["digest"]=String(repeating:"0",count:64)
        patchDisk["localFromServer"]=altered
        try JSONSerialization.data(withJSONObject:patchDisk).write(to:patchPath,options:.atomic)
        do { _ = try patchStore.load(); fatalError("invalid local baseline digest accepted") } catch {}
        patchDisk=try JSONSerialization.jsonObject(with:patchData) as! [String:Any]
        patchDisk["local"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(patchLocal))
        try JSONSerialization.data(withJSONObject:patchDisk).write(to:patchPath,options:.atomic)
        do { _ = try patchStore.load(); fatalError("conflicting local baseline representations accepted") } catch {}
        patchDisk.removeValue(forKey:"localFromServer")
        try JSONSerialization.data(withJSONObject:patchDisk).write(to:patchPath,options:.atomic)
        let legacyLocalRecord = try patchStore.load()!; precondition(legacyLocalRecord.local == patchLocal)
        let smallStore = DeltaStateStore(directory: dir, accountID: String(repeating: "d", count: 32))
        try smallStore.install(generation: generation, revision: "1", restoreEpoch: 0, server: small, local: small)
        let smallOps = StateDelta.diff(local: small, target: next, server: small)!
        let smallBytes = try JSONEncoder().encode(smallOps)
        let smallBatch = StateDeltaBatch(generation: generation, base_revision: "1", restore_epoch: 0,
                                         batch_id: String(repeating: "e", count: 32), ops: smallOps)
        try smallStore.stage(PendingStateDelta(batch: smallBatch, target: JSONEncoder().encode(next), stagedPayload: smallBytes))
        var oldDisk = try JSONSerialization.jsonObject(with: smallStore.rawRecord()!) as! [String: Any]
        let compactDisk = oldDisk
        var oldPending = oldDisk["pending"] as! [String: Any]
        var oldHeader = oldPending["batch"] as! [String: Any]
        oldHeader["ops"] = try JSONSerialization.jsonObject(with: smallBytes)
        oldPending["batch"] = oldHeader; oldPending.removeValue(forKey: "payloadOps"); oldDisk["pending"] = oldPending
        let smallPath = dir.appendingPathComponent("delta-\(String(repeating: "d", count: 32)).json")
        try JSONSerialization.data(withJSONObject: oldDisk).write(to: smallPath, options: .atomic)
        let legacyRecord = try smallStore.load()!
        precondition(legacyRecord.pending?.batch == smallBatch)
        // Ambiguous JSON in the preserved payload must not be replayed.
        oldPending["stagedPayload"] = Data("[{\"op\":\"set\",\"op\":\"remove\",\"path\":[\"blob\"],\"value\":\"new\"}]".utf8).base64EncodedString()
        oldDisk["pending"] = oldPending
        try JSONSerialization.data(withJSONObject: oldDisk).write(to: smallPath, options: .atomic)
        do { _ = try smallStore.load(); fatalError("duplicate staged key accepted") } catch {}
        var badCompact = compactDisk
        var compactPending = badCompact["pending"] as! [String: Any]
        compactPending["stagedPayload"] = Data("[{\"op\":\"set\",\"op\":\"remove\",\"path\":[\"blob\"],\"value\":\"new\"}]".utf8).base64EncodedString()
        badCompact["pending"] = compactPending
        try JSONSerialization.data(withJSONObject: badCompact).write(to: smallPath, options: .atomic)
        do { _ = try smallStore.load(); fatalError("duplicate compact staged key accepted") } catch {}
        compactPending = compactDisk["pending"] as! [String: Any]
        compactPending["stagedPayload"] = Data("[{\"op\":\"set\",\"path\":[\"blob\"],\"value\":\"wrong\"}]".utf8).base64EncodedString()
        badCompact["pending"] = compactPending
        try JSONSerialization.data(withJSONObject: badCompact).write(to: smallPath, options: .atomic)
        do { _ = try smallStore.load(); fatalError("mismatched compact operations accepted") } catch {}
        compactPending = compactDisk["pending"] as! [String: Any]
        var conflict = compactPending["batch"] as! [String: Any]
        conflict["ops"] = []; compactPending["batch"] = conflict; badCompact["pending"] = compactPending
        try JSONSerialization.data(withJSONObject: badCompact).write(to: smallPath, options: .atomic)
        do { _ = try smallStore.load(); fatalError("conflicting compact operations accepted") } catch {}
        let pullAccount = String(repeating: "f", count: 32)
        let pullStore = DeltaStateStore(directory: dir, accountID: pullAccount)
        try pullStore.install(generation: generation, revision: "1", restoreEpoch: 0, server: old, local: old)
        let previousBytes = try JSONEncoder().encode(old)
        try pullStore.stagePull(PendingStatePull(revision: "2", server: target, previous: previousBytes, target: targetBytes))
        let pullRaw = try pullStore.rawRecord()!
        precondition(pullRaw.count < 32 * 1024 * 1024)
        let pullRecord = try pullStore.load()!
        precondition(pullRecord.local == old && pullRecord.pull?.previous == previousBytes && pullRecord.pull?.target == targetBytes)
        var pullDisk = try JSONSerialization.jsonObject(with: pullRaw) as! [String: Any]
        precondition((pullDisk["localFromPull"] as? String)?.count == 64 && pullDisk["local"] == nil)
        pullDisk.removeValue(forKey: "localFromPull")
        pullDisk["local"] = try JSONSerialization.jsonObject(with: previousBytes)
        let legacyPullBytes = try JSONSerialization.data(withJSONObject: pullDisk)
        precondition(legacyPullBytes.count > 32 * 1024 * 1024)
        let smallPullAccount = String(repeating: "1", count: 32)
        let smallPull = DeltaStateStore(directory: dir, accountID: smallPullAccount)
        try smallPull.install(generation: generation, revision: "1", restoreEpoch: 0, server: small, local: small)
        let smallPrevious = try JSONEncoder().encode(small), smallTarget = try JSONEncoder().encode(next)
        try smallPull.stagePull(PendingStatePull(revision: "2", server: next, previous: smallPrevious, target: smallTarget))
        let smallPullPath = dir.appendingPathComponent("delta-\(smallPullAccount).json")
        var smallPullDisk = try JSONSerialization.jsonObject(with: smallPull.rawRecord()!) as! [String: Any]
        let compactPullDisk = smallPullDisk
        smallPullDisk.removeValue(forKey: "localFromPull"); smallPullDisk["local"] = try JSONSerialization.jsonObject(with: smallPrevious)
        try JSONSerialization.data(withJSONObject: smallPullDisk).write(to: smallPullPath, options: .atomic)
        let legacyPull = try smallPull.load()!
        precondition(legacyPull.local == small && legacyPull.pull?.previous == smallPrevious)
        var badPull = compactPullDisk
        badPull["local"] = ["blob":"other"]
        try JSONSerialization.data(withJSONObject: badPull).write(to: smallPullPath, options: .atomic)
        do { _ = try smallPull.load(); fatalError("conflicting compact baseline accepted") } catch {}
        badPull = compactPullDisk
        var badPullBody = badPull["pull"] as! [String: Any]
        let ambiguous = Data("{\"blob\":\"old\",\"blob\":\"wrong\"}".utf8)
        badPullBody["previous"] = ambiguous.base64EncodedString()
        badPull["localFromPull"] = SHA256.hash(data: ambiguous).map { String(format: "%02x", $0) }.joined()
        badPull["pull"] = badPullBody
        try JSONSerialization.data(withJSONObject: badPull).write(to: smallPullPath, options: .atomic)
        do { _ = try smallPull.load(); fatalError("ambiguous compact baseline accepted") } catch {}
        badPull = compactPullDisk; badPullBody = badPull["pull"] as! [String: Any]
        badPullBody["previous"] = Data("{\"blob\":\"wrong\"}".utf8).base64EncodedString()
        badPull["pull"] = badPullBody
        try JSONSerialization.data(withJSONObject: badPull).write(to: smallPullPath, options: .atomic)
        do { _ = try smallPull.load(); fatalError("altered compact baseline accepted") } catch {}
        try JSONSerialization.data(withJSONObject: compactPullDisk).write(to: smallPullPath, options: .atomic)
        let blockedArchive = dir.appendingPathComponent("archive-is-a-file")
        try Data("file".utf8).write(to: blockedArchive)
        do { try smallPull.archivePendingAndClear(to: blockedArchive); fatalError("failed archive cleared the pull") } catch {}
        let preserved = try smallPull.load()!
        precondition(preserved.pull?.previous == smallPrevious && preserved.pull?.target == smallTarget)
        let fenceArchive = dir.appendingPathComponent("fence-archive")
        let prepared = try smallPull.prepareArchive(to: fenceArchive)
        try Data("{}".utf8).write(to: smallPullPath, options: .atomic)
        do { try smallPull.clearPreparedArchive(prepared); fatalError("changed record was cleared") } catch {}
        let changedBytes = try Data(contentsOf: smallPullPath)
        precondition(changedBytes == Data("{}".utf8))
        try JSONSerialization.data(withJSONObject: compactPullDisk).write(to: smallPullPath, options: .atomic)
        let archive = dir.appendingPathComponent("archives")
        try smallPull.archivePendingAndClear(to: archive)
        let archived = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
        precondition(archived.count == 2 && archived.allSatisfy { $0.lastPathComponent.hasPrefix("unverified-a\(smallPullAccount)-") })
        let views = try archived.map { try Data(contentsOf: $0) }
        precondition(views.contains(smallPrevious) && views.contains(smallTarget))
        let clearedPull = try smallPull.load()
        precondition(clearedPull == nil)
        // Values are skipped by the key scanner but still validated by JSONDecoder.
        let validText = #"{"value":"escaped \"quote\" and \\ slash","nested":{"a":1}}"#
        let padded = Data(("x" + validText + "y").utf8)
        let sliced = padded.dropFirst().dropLast()
        guard case .object = try StateDelta.decode(sliced) else { fatalError("sliced escaped value rejected") }
        for malformed in [#"{"value":"bad\q"}"#, "{\"value\":\"line\nfeed\"}", #"{"a":1,"\u0061":2}"#, #"{"value":"bad\uZZZZ"}"#] {
            do { _ = try StateDelta.decode(Data(malformed.utf8)); fatalError("invalid JSON accepted") } catch {}
        }
        do { _ = try StateDelta.decode(Data(#"{"é":1,"e\u0301":2}"#.utf8)); fatalError("canonical duplicate accepted") } catch {}
        let invalidUTF8 = Data([123,34,120,34,58,34,0xFF,34,125])
        do { _ = try StateDelta.decode(invalidUTF8); fatalError("invalid UTF-8 accepted") } catch {}
        print("PASS compact staged records, legacy decoding, corruption rejection and pull view archival")
    }
}
