import Foundation
import CryptoKit

enum Config {
    static let apiBase:URL? = {
        let raw=ProcessInfo.processInfo.environment["VOCAB_TEST_BASE"] ?? "http://127.0.0.1:18770"
        guard let u=URL(string:raw),u.scheme=="http",u.host=="127.0.0.1",u.port != nil else { fatalError("loopback only") };return u
    }()
}
@main struct LibraryCacheCheck {
    static func main() async throws {
        precondition(LocalSentenceGenerator.validated(word:"apple",text:"The apple fell from the tree.",zh:"苹果从树上掉了下来。",scores:[5,4,5,5,5,5]))
        precondition(!LocalSentenceGenerator.validated(word:"app",text:"The apple fell from the tree.",zh:"苹果从树上掉了下来。",scores:[5,5,5,5,5,5]))
        precondition(!LocalSentenceGenerator.validated(word:"apple",text:"The apple fell from the tree.",zh:"English only",scores:[5,5,5,5,5,5]))
        precondition(!LocalSentenceGenerator.validated(word:"apple",text:"The apple fell from the tree.",zh:"苹果从树上掉了下来。",scores:[5,5,5,5,5]))
        let api=APIClient.shared,mode=CommandLine.arguments[1]
        if mode=="warm" {
            try await api.clearLibrary()
            _ = try await api.lexiconMetadata()
            do {_ = try await api.downloadLibrary { n,_,_ in n<256 };fatalError("cancel ignored")}
            catch is CancellationError {}
            let partial=await api.activeLibrary();precondition(partial==nil)
            let hash=SHA256.hash(data:Data(Config.apiBase!.absoluteString.utf8)).map { String(format:"%02x",$0) }.joined()
            let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VocabLibrary/"+hash)
            let revision=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).first!
            try Data("corrupt".utf8).write(to:revision.appendingPathComponent("0.json"))
            UserDefaults.standard.set(String(repeating:"0",count:64),forKey:"vocab_content_revision:"+Config.apiBase!.absoluteString)
            let m=try await api.downloadLibrary { _,_,_ in true }
            precondition(m.words==10986 && m.pages.count==86)
            let page=try await api.lexiconAt(pos:10987,n:10)
            precondition(page.lexicon_revision==m.revision && page.remaining_positions==0)
            let w=await api.cachedWord("shameful");precondition(w?.sentences?.count==3 && w?.sentences?.contains { $0.zh=="�" }==false)
            print("PASS native library cancel/resume, corrupt page redownload, 10986-word atomic activation")
        } else {
            let m=await api.activeLibrary();precondition(m?.words==10986)
            for word in ["apple","teen","temporal","shameful"] {
                let w=try await api.lexiconWord(word);precondition(w.word==word && w.sentences?.count==3)
                for mode in ["forward","reverse"] {let q=try await api.quiz(pos:w.pos,seed:99,mode:mode,word:word);precondition(q.matches(word:word))}
                let a=try await api.alternatives(word:word,tier:1);precondition(!a.sentences.isEmpty)
            }
            try await api.clearLibrary();let cleared=await api.activeLibrary();precondition(cleared==nil)
            print("PASS native library survives process restart, serves word/quiz/alternatives without server, removable independently of progress")
        }
    }
}
