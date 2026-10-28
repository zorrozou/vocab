import Foundation
import Darwin

enum Config { static let apiBase: URL? = URL(string:"http://127.0.0.1:18765") }
@main struct Check {
 static func main() throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent("vocab-restore-store-"+UUID().uuidString,isDirectory:true)
  defer { try? FileManager.default.removeItem(at:dir) }
  let account=String(repeating:"a",count:32),other=String(repeating:"b",count:32)
  let previous=Data("{\"v\":1,\"cards\":{},\"log\":[],\"pendingNew\":[],\"settings\":{}}".utf8)
  let payload=Data("{\"v\":1,\"cards\":{\"apple\":{\"pos\":1}},\"log\":[],\"pendingNew\":[],\"settings\":{}}".utf8)
  let intent=ExperimentalLargeRestoreIntent(batchID:String(repeating:"c",count:32),generation:String(repeating:"d",count:32),baseRevision:"1",restoreEpoch:0,payload:payload)
  let store=ExperimentalLargeRestoreStore(directory:dir,accountID:account),baseline=Data("baseline".utf8)
  guard try store.rawRecord() == nil, try store.load() == nil, try !store.hasFence() else { fatalError("missing restore record was not treated as absent") }
  try store.stage(intent:intent,previous:previous,baseline:baseline)
  guard let saved=try store.load(),saved.intent==intent,saved.previous==previous,store.matchesBaseline(baseline,record:saved) else { fatalError("missing staged intent") }
  guard try !ExperimentalLargeRestoreStore(directory:dir,accountID:other).hasFence() else { fatalError("cross-account fence") }
  do { _ = try DeltaStateStore(directory:dir,accountID:account).load();fatalError("ordinary sync not fenced") } catch {}
  do { try DeltaStateStore(directory:dir,accountID:account).fenceMutation(nil);fatalError("ordinary mutation bypassed restore fence") } catch {}
  do { try store.stage(intent:intent,previous:previous,baseline:baseline);fatalError("overwrote pending intent") } catch {}
  let path=dir.appendingPathComponent("large-restore-\(account).json"),raw=try Data(contentsOf:path)
  try Data(repeating:65,count:40 * 1024 * 1024 + 1).write(to:path,options:.atomic)
  do { _ = try store.rawRecord();fatalError("oversized recovery record accepted") } catch {}
  try raw.write(to:path,options:.atomic)
  var corrupted=try JSONSerialization.jsonObject(with:raw) as! [String:Any];corrupted["payloadSHA256"]=String(repeating:"0",count:64)
  try JSONSerialization.data(withJSONObject:corrupted).write(to:path,options:.atomic)
  do { _ = try store.load();fatalError("corrupt intent accepted") } catch {}
  guard let corruptRaw=try store.rawRecord(),!corruptRaw.isEmpty,try store.hasFence() else { fatalError("corrupt record lost") }
  var changedMetadata=try JSONSerialization.jsonObject(with:raw) as! [String:Any]
  var changedIntent=changedMetadata["intent"] as! [String:Any];changedIntent["baseRevision"]="2";changedMetadata["intent"]=changedIntent
  try JSONSerialization.data(withJSONObject:changedMetadata).write(to:path,options:.atomic)
  do { _ = try store.load();fatalError("corrupt intent metadata accepted") } catch {}
  try raw.write(to:path,options:.atomic)
  let marker=dir.appendingPathComponent("large-restore-\(account).guard");try FileManager.default.removeItem(at:marker)
  guard try store.hasFence() else { fatalError("unguarded record not fenced") }
  do { _ = try store.load();fatalError("missing guard accepted") } catch {}
  do { _ = try DeltaStateStore(directory:dir,accountID:account).load();fatalError("unguarded record allowed sync") } catch {}
  try Data(repeating:65,count:129).write(to:marker,options:.atomic)
  do { _ = try store.load();fatalError("oversized guard accepted") } catch {}
  try Data("vocab-large-restore-guard-v1\n".utf8).write(to:marker,options:.atomic)
  try FileManager.default.removeItem(at:path)
  do { _ = try store.load();fatalError("missing record accepted") } catch {}
  do { _ = try DeltaStateStore(directory:dir,accountID:account).hasMissingRecord();fatalError("guard bypassed") } catch {}
  try FileManager.default.removeItem(at:marker)
  let installation=dir.appendingPathComponent("large-restore-\(account).install")
  try Data("damaged".utf8).write(to:installation,options:.atomic)
  guard try store.hasFence() else { fatalError("orphaned installation did not fence") }
  do { _ = try store.load();fatalError("orphaned installation accepted") } catch {}
  do { _ = try DeltaStateStore(directory:dir,accountID:account).load();fatalError("orphaned installation allowed ordinary sync") } catch {}
  try FileManager.default.removeItem(at:installation)
  let final=dir.appendingPathComponent("large-restore-\(account).final")
  try Data("damaged".utf8).write(to:final,options:.atomic)
  guard try store.hasFence() else { fatalError("orphaned finalization did not fence") }
  do { _ = try store.loadFinalization();fatalError("corrupt finalization accepted") } catch {}
  do { _ = try DeltaStateStore(directory:dir,accountID:account).load();fatalError("corrupt finalization allowed sync") } catch {}
  do { _ = try ExperimentalLargeRestoreStore(directory:dir,accountID:"../invalid").hasFence();fatalError("invalid account accepted") } catch {}
  let cleanupStore=ExperimentalLargeRestoreStore(directory:dir,accountID:other)
  try cleanupStore.stage(intent:intent,previous:previous,baseline:baseline)
  guard let cleanupRecord=try cleanupStore.load() else { fatalError("missing cleanup record") }
  let receiptBytes=try JSONSerialization.data(withJSONObject:["ok":true,"batch_id":intent.batchID,"generation":intent.generation,"base_revision":"1","state_revision":"2","payload_sha256":String(repeating:"a",count:64),"restore_epoch":1,"updated_at":1])
  let receipt=try JSONDecoder().decode(ExperimentalLargeRestoreReceipt.self,from:receiptBytes)
  let cleanupPlan=try cleanupStore.stageInstallation(record:cleanupRecord,receipt:receipt,server:["restoreEpoch":.integer(1)],target:Data("{\"restoreEpoch\":1}".utf8))
  let cleanup=try cleanupStore.stageFinalization(record:cleanupRecord,plan:cleanupPlan)
  let archive=dir.appendingPathComponent("before-large-restore-\(other)-\(intent.batchID).json")
  do {
   try cleanupStore.finishFinalization(cleanup) { index in if index == 1 { try Data("changed".utf8).write(to:archive,options:.atomic) } }
   fatalError("changed archive accepted")
  } catch {}
  guard try cleanupStore.hasFence() else { fatalError("changed archive lost fence") }
  try previous.write(to:archive,options:.atomic)
  try cleanupStore.finishFinalization(cleanup)
  guard try !cleanupStore.hasFence() else { fatalError("valid cleanup did not finish") }
  let checkpointAccount=String(repeating:"c",count:32), checkpointStore=ExperimentalLargeRestoreStore(directory:dir,accountID:checkpointAccount)
  let checkpoint=ExperimentalLargeRestoreIntent(batchID:String(repeating:"d",count:32),generation:intent.generation,
      baseRevision:"1",restoreEpoch:0,payload:previous,kind:"checkpoint")
  try checkpointStore.stage(intent:checkpoint,previous:previous,baseline:baseline)
  guard let stagedCheckpoint=try checkpointStore.load(), stagedCheckpoint.intent==checkpoint else { fatalError("checkpoint intent lost") }
  let checkpointPath=dir.appendingPathComponent("large-restore-\(checkpointAccount).json")
  let checkpointBytes=try Data(contentsOf:checkpointPath)
  var changed=try JSONSerialization.jsonObject(with:checkpointBytes) as! [String:Any]
  var changedCheckpoint=changed["intent"] as! [String:Any];changedCheckpoint.removeValue(forKey:"kind");changed["intent"]=changedCheckpoint
  try JSONSerialization.data(withJSONObject:changed).write(to:checkpointPath,options:.atomic)
  do { _ = try checkpointStore.load();fatalError("checkpoint changed into restore") } catch {}
  for step in 1...2 {
   let isolated=dir.appendingPathComponent("cancel-\(step)",isDirectory:true)
   let cancellationStore=ExperimentalLargeRestoreStore(directory:isolated,accountID:checkpointAccount)
   try cancellationStore.stage(intent:checkpoint,previous:previous,baseline:baseline)
   guard let record=try cancellationStore.load() else { fatalError("missing checkpoint intent") }
   let receipt=ExperimentalLargeCheckpointCancelReceipt(ok:true,cancelled:true,batch_id:checkpoint.batchID,
      generation:checkpoint.generation,base_revision:checkpoint.baseRevision,head_revision:"2",restore_epoch:0)
   let invalidReceipt=ExperimentalLargeCheckpointCancelReceipt(ok:true,cancelled:true,batch_id:checkpoint.batchID,
      generation:checkpoint.generation,base_revision:checkpoint.baseRevision,head_revision:"1",restore_epoch:0)
   do { _ = try cancellationStore.stageCancellation(record:record,receipt:invalidReceipt);fatalError("non-advancing cancellation accepted") } catch {}
   guard try cancellationStore.hasFence(), try cancellationStore.load() == record else { fatalError("invalid receipt lost checkpoint fence") }
   let cancellation=try cancellationStore.stageCancellation(record:record,receipt:receipt)
   do { try cancellationStore.finishCancellation(cancellation) { index in if index == step { throw APIError(message:"injected interruption") } }; fatalError("interruption not injected") } catch {}
   guard try cancellationStore.hasFence(), try cancellationStore.loadCancellation() == cancellation,
         try cancellationStore.rawRecoveryRecord() != nil else { fatalError("interrupted cancellation was not fenced and exportable") }
   do { _ = try DeltaStateStore(directory:isolated,accountID:checkpointAccount).load();fatalError("interrupted cancellation allowed sync") } catch {}
   try cancellationStore.finishCancellation(cancellation)
   guard try !cancellationStore.hasFence() else { fatalError("cancellation fence was not cleared") }
  }
  let restoreDir=dir.appendingPathComponent("cancel-restore",isDirectory:true)
  let restoreCancel=ExperimentalLargeRestoreStore(directory:restoreDir,accountID:checkpointAccount)
  try restoreCancel.stage(intent:intent,previous:previous,baseline:baseline)
  guard let restoreRecord=try restoreCancel.load() else { fatalError("missing restore intent") }
  let missingDigest=ExperimentalLargeCheckpointCancelReceipt(ok:true,cancelled:true,batch_id:intent.batchID,
      generation:intent.generation,base_revision:intent.baseRevision,head_revision:"2",restore_epoch:0)
  do { _ = try restoreCancel.stageCancellation(record:restoreRecord,receipt:missingDigest);fatalError("restore cancellation without digest accepted") } catch {}
  let restoreReceipt=ExperimentalLargeCheckpointCancelReceipt(ok:true,cancelled:true,batch_id:intent.batchID,
      generation:intent.generation,base_revision:intent.baseRevision,head_revision:"2",restore_epoch:0,payload_sha256:restoreRecord.payloadSHA256)
  let cancelledRestore=try restoreCancel.stageCancellation(record:restoreRecord,receipt:restoreReceipt)
  do { try restoreCancel.finishCancellation(cancelledRestore) { index in if index == 1 { throw APIError(message:"injected interruption") } };fatalError("interruption not injected") } catch {}
  guard try restoreCancel.hasFence(), try restoreCancel.loadCancellation() == cancelledRestore else { fatalError("restore cancellation lost its fence") }
  try restoreCancel.finishCancellation(cancelledRestore)
  guard try !restoreCancel.hasFence() else { fatalError("restore cancellation fence was not cleared") }
  print("PASS iOS large restore intent is durable, fenced, account scoped and corruption preserving")
 }
}
