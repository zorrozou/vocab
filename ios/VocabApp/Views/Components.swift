import SwiftUI

// MARK: - 主题（对齐 web 深色卡片风）

enum Theme {
    static let bg = Color(.sRGB, red: 0.043, green: 0.055, blue: 0.075, opacity: 1)
    static let card = Color(.sRGB, red: 0.105, green: 0.125, blue: 0.165, opacity: 1)
    static let cardDeep = Color(.sRGB, red: 0.070, green: 0.082, blue: 0.102, opacity: 1)
    static let accent = Color(.sRGB, red: 0.184, green: 0.435, blue: 0.929, opacity: 1)   // #2f6fed
    static let accentLight = Color(.sRGB, red: 0.373, green: 0.612, blue: 0.925, opacity: 1) // #5f9cec
    static let ok = Color(.sRGB, red: 0.203, green: 0.780, blue: 0.540, opacity: 1)
    static let warn = Color(.sRGB, red: 0.910, green: 0.580, blue: 0.220, opacity: 1)
    static let bad = Color(.sRGB, red: 0.941, green: 0.467, blue: 0.467, opacity: 1)
    static let muted = Color(.sRGB, red: 0.580, green: 0.620, blue: 0.680, opacity: 1)
    static let text = Color(.sRGB, red: 0.910, green: 0.930, blue: 0.960, opacity: 1)
}

// MARK: - 跟读共享组件（学习卡/复习答案卡通用）

/// 微信式按住说话按钮：按下收音、松手评分
struct ShadowHoldButton: View {
    @Environment(AppState.self) private var app
    @State private var pressing = false
    @State private var ownsRecording = false
    @State private var requestID = UUID()
    let target: String          // 目标句（空则禁用提示）
    var onBusy: (String) -> Void = { _ in }
    var onResult: (ShadowResult?) -> Void

    var body: some View {
        Text(app.speech.state == .listening ? "🎤 松开结束" : "🎤 按住跟读")
            .font(.system(size: 15, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(app.speech.state == .listening ? .white : Theme.text)
            .background(app.speech.state == .listening ? Theme.warn : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.muted.opacity(0.5)))
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.15, perform: {}) { pressing in
                if pressing {
                    self.pressing = true
                    start()
                } else {
                    finish(finalize: true)
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(ownsRecording ? "结束跟读" : "开始跟读")
            .accessibilityHint("轻点开始或结束录音")
            .accessibilityAction {
                if ownsRecording || pressing { finish(finalize: true) }
                else { pressing = true; start() }
            }
            .onDisappear { finish(finalize: false) }
    }

    private func finish(finalize: Bool) {
        pressing = false
        requestID = UUID()
        if ownsRecording && app.speech.state == .listening {
            app.speech.stopCapture(finalize: finalize)
        }
        ownsRecording = false
    }

    private func start() {
        guard !target.isEmpty else { pressing = false; onBusy("例句还在生成，稍等"); return }
        let request = UUID()
        requestID = request
        app.audio.stop()
        Task {
            let allowed = await SpeechService.requestPermissions()
            guard pressing, requestID == request else { return }
            guard allowed else {
                pressing = false
                onBusy("需要麦克风和语音识别权限（设置 → 词航）")
                return
            }
            guard app.speech.onDeviceAvailable else {
                pressing = false
                onBusy("本机语音识别暂不可用；请检查设备语言与语音模型")
                return
            }
            guard app.speech.state == .idle else { pressing = false; return }
            ownsRecording = true
            app.speech.start(target: target) { result in
                ownsRecording = false
                pressing = false
                onResult(result)
            }
        }
    }
}

/// 跟读结果展示：总分 + 逐词置信度标色（绿≥0.7 橙0.4~0.7 红<0.4）
struct ShadowResultDisplay: View {
    let result: ShadowResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("完整度").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Text("\(result.completeness)%")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(result.completeness >= 80 ? Theme.ok : Theme.warn)
                Text("置信度").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Text("\(result.confidence)%")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(result.confidence >= 75 ? Theme.ok : Theme.warn)
                if result.completeness < 60 {
                    Text("已记入薄弱词").font(.system(size: 11)).foregroundStyle(Theme.bad)
                }
            }
            Text("完整度是识别到的目标词比例；识别置信度不代表发音准确度。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            if !result.words.isEmpty {
                result.words.reduce(Text("")) { acc, w in
                    acc + Text(w.text + " ").foregroundStyle(color(of: w.confidence))
                }
                .font(.system(size: 14))
            } else {
                Text(result.text).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(of c: Float) -> Color {
        c >= 0.7 ? Theme.ok : (c >= 0.4 ? Theme.warn : Theme.bad)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 14) { content }
            .padding(18)
            .frame(maxWidth: 560)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 14)
    }
}

struct PrimaryButton: View {
    let title: String
    var color: Color = Theme.accent
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(color)
                .foregroundStyle(color == Theme.ok || color == Theme.warn ? Theme.bg : .white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct GhostButton: View {
    let title: String
    var color: Color = Theme.text
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundStyle(color)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.muted.opacity(0.5)))
        }
    }
}

struct BigWord: View {
    let word: String
    var body: some View {
        Text(word)
            .font(.largeTitle.weight(.bold))
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .foregroundStyle(Theme.text)
    }
}

struct PlayButton: View {
    @Environment(AppState.self) private var app
    let text: String
    var body: some View {
        Button { app.audio.play(text, voice: app.S.settings.voice) } label: {
            Image(systemName: app.audio.playingText == text ? "speaker.wave.2.fill" : "play.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accentLight)
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("朗读：\(text)")
        .buttonStyle(.plain)
    }
}

struct ProgressBar: View {
    let value: Double   // 0~1
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.cardDeep).frame(height: 6)
                RoundedRectangle(cornerRadius: 3).fill(Theme.accent)
                    .frame(width: g.size.width * min(1, max(0, value)), height: 6)
            }
        }
        .frame(height: 6)
    }
}

struct TagLabel: View {
    let text: String
    var color: Color = Theme.muted
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.6)))
    }
}

/// 例句行：标签 + 句子 + ▶ + ↻换一句 + 中文
struct SentenceRow: View {
    @Environment(AppState.self) private var app
    let word: String
    let tag: String
    let tagColor: Color
    let sentence: SentenceItem
    let kind: String          // "static" / "personal" / "weave"
    var displayedSentences: [String] = []
    var recallNote: String? = nil
    var onSwap: (SentenceItem?) -> Void

    @State private var swapping = false
    @State private var swapError = false
    @State private var reportMessage=""
    @State private var reporting=false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                TagLabel(text: tag, color: tagColor)
                Text(sentence.text)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PlayButton(text: sentence.text)
                Button {
                    guard !swapping else { return }
                    swapping = true
                    swapError = false
                    Task {
                        let fresh = await app.swapSentence(word: word, oldText: sentence.text, kind: kind, tier: sentence.tier ?? 1, displayedSentences: displayedSentences)
                        await MainActor.run {
                            if kind == "static" && fresh == nil { swapError = true }
                            else { onSwap(fresh) }
                            swapping = false
                        }
                    }
                } label: {
                    Group {
                        if swapping {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("换一句：\(word)")
                .accessibilityIdentifier("swap-\(kind)-\(word)")
                .disabled(swapping)
            }
            Menu {
                ForEach([("meaning","词义不匹配"),("translation","翻译有误"),("grammar","语法问题"),("unnatural","表达不自然")],id:\.0) { reason,title in
                    Button(title) {
                        reporting=true
                        Task {
                            do { try await APIClient.shared.reportContent(word:word,text:sentence.text,kind:kind=="static" ? "static":"personal",reason:reason);reportMessage="已进入内容复核队列。" }
                            catch { reportMessage="未提交："+error.localizedDescription }
                            reporting=false
                        }
                    }
                }
            } label: { Text(reporting ? "正在提交…":"例句纠错").font(.caption).foregroundStyle(Theme.muted).frame(minHeight:32) }.disabled(reporting)
            if !reportMessage.isEmpty { Text(reportMessage).font(.caption).foregroundStyle(Theme.muted) }
            if let recallNote {
                Text(recallNote).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            if let zh = sentence.zh, !zh.isEmpty {
                Text(zh).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            if swapError {
                Text("暂时无法换句，请稍后重试。")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        }
        .opacity(swapping ? 0.35 : 1)
    }
}

/// 4 选 1 选项按钮（答题后高亮对错）
struct QuizOptionsView: View {
    let options: [QuizOption]
    let onPick: (Bool) -> Void
    @State private var feedback = QuizAnswerFeedback()

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                Button {
                    feedback.choose(i, correct: o.ok, commit: onPick)
                } label: {
                    Text(o.text)
                        .font(.system(size: 16))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12).padding(.horizontal, 14)
                        .background(bg(for: i, ok: o.ok))
                        .foregroundStyle(Theme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityIdentifier("quiz-option-\(i)")
                .disabled(feedback.picked != nil)
            }
        }
        .onChange(of: options) { _, _ in feedback.cancel() }
        .onDisappear { feedback.cancel() }
    }

    private func bg(for i: Int, ok: Bool) -> Color {
        guard let p = feedback.picked else { return Theme.cardDeep }
        if ok { return Theme.ok.opacity(0.35) }
        if p == i { return Theme.bad.opacity(0.35) }
        return Theme.cardDeep.opacity(0.5)
    }
}


struct MeaningFeedbackButton: View {
    let word:String
    let text:String
    @State private var message=""
    @State private var running=false
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            Button("报告词义问题") {
                running=true
                Task {
                    do { try await APIClient.shared.reportContent(word:word,text:String(text.prefix(500)),kind:"meaning",reason:"meaning");message="已进入内容复核队列。" }
                    catch { message="未提交："+error.localizedDescription }
                    running=false
                }
            }.font(.caption).foregroundStyle(Theme.muted).disabled(running)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(Theme.muted) }
        }
    }
}
