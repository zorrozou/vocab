import AVFoundation
import Foundation
import Speech

struct ShadowResult {
    let text: String
    let completeness: Int   // 词命中率 %（对齐 web 算法：目标句词被覆盖比例）
    let confidence: Int     // 识别置信度 %
}

/// 跟读评分（M1：SFSpeechRecognizer 设备端模式）
/// 限制：单次约 1 分钟、约 1000 次/小时/设备——跟读场景够用。
/// TODO(M1.5)：iOS 26+ 换 SpeechAnalyzer（无时长限制、词级时间戳，可算流利度子分）。
@MainActor
@Observable
final class SpeechService: NSObject {
    enum State: Equatable {
        case idle, listening, evaluating
    }
    private(set) var state: State = .idle
    private(set) var liveText = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var target = ""
    private var onResult: ((ShadowResult?) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    static func requestPermissions() async -> Bool {
        let speechOK = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { st in
                cont.resume(returning: st == .authorized)
            }
        }
        let micOK = await AVAudioApplication.requestRecordPermission()
        return speechOK && micOK
    }

    /// 开始监听；最多 15 秒自动收尾。结果通过 onResult 回调一次。
    func start(target: String, onResult: @escaping (ShadowResult?) -> Void) {
        guard state == .idle else { return }
        guard let recognizer, recognizer.isAvailable else { onResult(nil); return }
        self.target = target
        self.onResult = onResult
        finished = false
        liveText = ""
        state = .listening

        let eng = AVAudioEngine()
        engine = eng
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true   // 纯本机识别，不上传
        }
        request = req

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let input = eng.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in
            req.append(buf)
        }
        do {
            try eng.start()
        } catch {
            finish(with: nil)
            return
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.liveText = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.finish(with: result)
                    }
                } else if error != nil {
                    self.finish(with: nil)
                }
            }
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.stopCapture(finalize: true)
        }
    }

    /// 用户点「停止」或超时：结束收音，拿到最终结果
    func stopCapture(finalize: Bool) {
        guard state == .listening else { return }
        state = .evaluating
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        if !finalize {
            finish(with: nil)
        }
        // finalize=true 时等 recognitionTask 的 isFinal 回调（上面已注册）；
        // 兜底 2.5s 没回调就用已识别的 partial 文本评分
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.state == .evaluating, !self.finished else { return }
            let text = self.liveText
            self.deliver(text.isEmpty ? nil : self.score(text))
        }
    }

    private func finish(with result: SFSpeechRecognitionResult?) {
        guard !finished else { return }
        if let result {
            deliver(score(result.bestTranscription.formattedString,
                           segments: result.bestTranscription.segments))
        } else {
            deliver(nil)
        }
    }

    private func score(_ text: String,
                       segments: [SFTranscriptionSegment]? = nil) -> ShadowResult {
        // 完整度：与 web 一致（目标句词集合命中率）
        let exp = wordTokens(target)
        let got = Set(wordTokens(text))
        let hit = exp.filter { got.contains($0) }.count
        let pct = exp.isEmpty ? 0 : Int(Double(hit) / Double(exp.count) * 100)
        // 置信度：词级置信度均值（0~1）
        var conf = 70
        if let segments, !segments.isEmpty {
            let avg = segments.map { $0.confidence }.reduce(0, +) / Float(segments.count)
            conf = Int(avg * 100)
        }
        return ShadowResult(text: text, completeness: pct, confidence: conf)
    }

    private func deliver(_ r: ShadowResult?) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        task?.cancel()
        task = nil
        request = nil
        engine = nil
        state = .idle
        let cb = onResult
        onResult = nil
        cb?(r)
    }
}
