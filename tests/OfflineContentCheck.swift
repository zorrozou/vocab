import Foundation
@main struct OfflineContentCheck {
 static func main() async throws {
  guard Config.apiBase?.host == "127.0.0.1" else { fatalError("isolated fixture required") }
  let api=APIClient.shared
  if CommandLine.arguments.contains("warm") { _ = try await api.lexiconMetadata() }
  let w=try await api.lexiconWord("apple")
  let q=try await api.quiz(pos:w.pos,seed:CommandLine.arguments.contains("warm") ? 1 : 99999,mode:"forward",word:w.word)
  _ = try await api.quiz(pos:w.pos,seed:1,mode:"reverse",word:w.word)
  guard w.word=="apple",q.matches(word:"apple"),await api.offlineContentReady(word:"apple") else { fatalError("cache mismatch") }
  print("PASS native persistent word and forward/reverse quiz cache, seed-independent identity")
 }
}
