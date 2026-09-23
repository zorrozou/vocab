import AVFoundation
import Foundation

/// 播放会话恢复：任何"可能被别人改过会话"后的播放前都必须调用。
/// （跟读会把会话切成 .record；若在 .record 下播 AVAudioPlayer 就是全局失声——
/// 这是"跟读后没声音"的根因。幂等且廉价，每次播放前断言一次。）
enum PlaybackSession {
    static func activate() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default)
        try? s.setActive(true)
        #endif
    }
}

/// 朗读服务：TTS 音频（服务器 edge-tts 神经语音）+ App 本地磁盘缓存 + 流式连播链
/// - 首次播放某文本：从服务器取 mp3（服务端自己也有缓存，命中 ~0.1s，新生成 ~2s），写入本地缓存
/// - 再次播放同一文本：直接读本地文件，零网络、离线可用
/// - 连播规则（与 web 一致）：单词 → 停顿（=下一句时长，留给跟读）→ 例句1 → 停顿 → …
///   流式启动：第一条就绪就立刻开播，其余后台并行下载（不再傻等全部下完）
@MainActor
@Observable
final class AudioService {
    private(set) var playingText: String?
    private var current: AVAudioPlayer?
    private var chainTask: Task<Void, Never>?

    // MARK: 本地磁盘缓存（Documents/tts_audio/<sha1>.mp3）

    private static var cacheDir: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tts_audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func cacheFile(_ text: String, voice: String?) -> URL {
        // FNV-1a 64bit 哈希，零依赖（不需要 CryptoKit）
        var h: UInt64 = 0xcbf29ce484222325
        for b in Data("\(voice ?? "default")|\(text)".utf8) {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return cacheDir.appendingPathComponent("\(String(format: "%016llx", h)).mp3")
    }

    // MARK: 音频会话（每次播放前都断言 .playback——跟读会把会话切成 .record）

    private func configureSession() {
        PlaybackSession.activate()
    }

    // MARK: 取音频（本地缓存优先，未命中走服务器并写缓存）

    private func audioData(_ text: String, voice: String?) async throws -> Data {
        let file = Self.cacheFile(text, voice: voice)
        if let cached = try? Data(contentsOf: file), cached.count > 500 {
            return cached
        }
        guard let url = await APIClient.shared.ttsURL(text, voice: voice) else {
            throw APIError(message: "TTS URL 构建失败")
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200, data.count > 500 else {
            throw APIError(message: "TTS 拉取失败")
        }
        try? data.write(to: file, options: .atomic)
        return data
    }

    private func makePlayer(_ text: String, voice: String?) async -> AVAudioPlayer? {
        do {
            let data = try await audioData(text, voice: voice)
            return try AVAudioPlayer(data: data)
        } catch {
            print("[VocabApp] 音频获取失败: \(text.prefix(30))… \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: 播放控制

    func stop() {
        chainTask?.cancel()
        chainTask = nil
        current?.stop()
        current = nil
        playingText = nil
    }

    /// 单条朗读（点按 ▶）
    func play(_ text: String, voice: String?) {
        stop()
        chainTask = Task {
            configureSession()
            guard let p = await makePlayer(text, voice: voice), !Task.isCancelled else { return }
            current = p
            playingText = text
            p.play()
            try? await Task.sleep(nanoseconds: UInt64((p.duration + 0.2) * 1e9))
            if !Task.isCancelled { playingText = nil }
        }
    }

    /// 自动连播链：第一条就绪立刻开播，后续并行预取、按序接上
    /// 句间停顿 = 下一句时长（跟读留白，与 web 一致）
    func playSequence(word: String, sentences: [String], voice: String?) {
        stop()
        let items = ([word] + sentences).filter { !$0.isEmpty }
        guard !items.isEmpty else { return }
        chainTask = Task {
            configureSession()
            // 并行发起全部下载（共享本地缓存与服务端缓存）
            async let all = withTaskGroup(of: (Int, AVAudioPlayer?).self) { group in
                for (i, t) in items.enumerated() {
                    group.addTask { [self] in (i, await makePlayer(t, voice: voice)) }
                }
                var arr = [(Int, AVAudioPlayer?)]()
                for await r in group { arr.append(r) }
                return arr.sorted { $0.0 < $1.0 }
            }
            // 但第一条单独先取，开播不等其余
            guard let first = await makePlayer(items[0], voice: voice), !Task.isCancelled else { return }
            let sorted = await all
            var byIndex: [Int: AVAudioPlayer] = [:]
            for (i, p) in sorted { byIndex[i] = p }
            byIndex[0] = first
            for i in 0..<items.count {
                if Task.isCancelled { return }
                guard let p = byIndex[i] else { continue }   // 该条拉取失败则跳过
                current = p
                playingText = items[i]
                p.play()
                let gap = (i + 1 < items.count) ? max(0.6, byIndex[i + 1]?.duration ?? 1.2) : 0
                try? await Task.sleep(nanoseconds: UInt64((p.duration + gap) * 1e9))
            }
            if !Task.isCancelled { playingText = nil }
        }
    }
}
