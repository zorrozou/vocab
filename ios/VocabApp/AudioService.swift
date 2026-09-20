import AVFoundation
import Foundation

/// 朗读服务：TTS 音频下载 + 自动连播链
/// 连播规则（与 web 一致）：单词 → 停顿（=下一句时长，留给跟读）→ 例句1 → 停顿 → 例句2 → …
@MainActor
@Observable
final class AudioService {
    private(set) var playingText: String?
    private var players: [AVAudioPlayer] = []
    private var chainTask: Task<Void, Never>?
    private var sessionConfigured = false

    private func configureSession() {
        guard !sessionConfigured else { return }
        sessionConfigured = true
        #if os(iOS)
        // .playback：静音开关下也能出声（学习 App 需要）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    func stop() {
        chainTask?.cancel()
        chainTask = nil
        players.forEach { $0.stop() }
        players = []
        playingText = nil
    }

    private func fetchPlayer(_ text: String, voice: String?) async throws -> AVAudioPlayer {
        guard let url = await APIClient.shared.ttsURL(text, voice: voice) else {
            throw APIError(message: "TTS URL 构建失败")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try AVAudioPlayer(data: data)
    }

    /// 单条朗读（点按 ▶）
    func play(_ text: String, voice: String?) {
        stop()
        chainTask = Task {
            configureSession()
            do {
                let p = try await fetchPlayer(text, voice: voice)
                guard !Task.isCancelled else { return }
                players = [p]
                playingText = text
                p.play()
                try? await Task.sleep(nanoseconds: UInt64((p.duration + 0.2) * 1e9))
                if !Task.isCancelled { playingText = nil }
            } catch {
                playingText = nil
            }
        }
    }

    /// 自动连播链：word → 例句们，句间停顿 = 下一句时长（与 web 的 autoPlaySequence 一致）
    func playSequence(word: String, sentences: [String], voice: String?) {
        stop()
        let items = ([word] + sentences).filter { !$0.isEmpty }
        guard !items.isEmpty else { return }
        chainTask = Task {
            configureSession()
            // 并发预取全部音频
            let fetched = await withTaskGroup(of: (Int, AVAudioPlayer?).self) { group in
                for (i, t) in items.enumerated() {
                    group.addTask { [self] in
                        (i, try? await fetchPlayer(t, voice: voice))
                    }
                }
                var arr = [(Int, AVAudioPlayer?)]()
                for await r in group { arr.append(r) }
                return arr.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
            guard !Task.isCancelled else { return }
            let ps = fetched.compactMap { $0 }
            guard !ps.isEmpty else { return }
            players = ps
            for (i, p) in ps.enumerated() {
                if Task.isCancelled { return }
                playingText = items[i]
                p.play()
                // 播完 + 停顿（=下一句时长，末句不停）
                var gap = 0.0
                if i + 1 < ps.count { gap = max(0.6, ps[i + 1].duration) }
                try? await Task.sleep(nanoseconds: UInt64((p.duration + gap) * 1e9))
            }
            if !Task.isCancelled { playingText = nil }
        }
    }
}
