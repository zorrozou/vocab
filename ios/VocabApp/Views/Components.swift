import SwiftUI

enum AppAppearance:String,CaseIterable,Identifiable {
    static let storageKey = "vocab.appearance.v1"
    case system, light, dark
    var id:Self { self }
    var label:String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
    var interfaceStyle:UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

enum Theme {
    private static func adaptive(light:UInt32,dark:UInt32) -> Color {
        func rgb(_ hex:UInt32) -> UIColor {
            UIColor(red:CGFloat((hex >> 16) & 255)/255,green:CGFloat((hex >> 8) & 255)/255,
                    blue:CGFloat(hex & 255)/255,alpha:1)
        }
        let day=rgb(light),night=rgb(dark)
        return Color(uiColor:UIColor { traits in traits.userInterfaceStyle == .dark ? night:day })
    }

    static let bg = adaptive(light:0xf5f4eb,dark:0x101b20)
    static let card = adaptive(light:0xfffdf7,dark:0x19282e)
    static let cardDeep = adaptive(light:0xedf1e9,dark:0x132126)
    static let edge = adaptive(light:0xc1cbc1,dark:0x37494e)
    static let accent = adaptive(light:0x17644f,dark:0x9be6cf)
    static let accentLight = accent
    static let onAccent = adaptive(light:0xffffff,dark:0x102a26)
    static let onAccentCaption = adaptive(light:0xe2f4e8,dark:0x254b42)
    static let ok = adaptive(light:0x236241,dark:0x34c78a)
    static let warn = adaptive(light:0x795013,dark:0xe89438)
    static let bad = adaptive(light:0x8a302f,dark:0xf07777)
    static let muted = adaptive(light:0x51645b,dark:0xafc0c1)
    static let text = adaptive(light:0x20332e,dark:0xf4f1e9)
    static let heroStart = adaptive(light:0xdceee1,dark:0x123833)
    static let heroEnd = adaptive(light:0xf4efdf,dark:0x142126)
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
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10).frame(minHeight:44)
            .foregroundStyle(app.speech.state == .listening ? Theme.onAccent : Theme.text)
            .background(app.speech.state == .listening ? Theme.warn : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .background(Theme.cardDeep,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(Theme.edge))
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
        Group {
            HStack(spacing: 10) {
                Text("完整度").font(.caption).foregroundStyle(Theme.muted)
                Text("\(result.completeness)%")
                    .font(.body.weight(.bold))
                    .foregroundStyle(result.completeness >= 80 ? Theme.ok : Theme.warn)
                if let confidence=result.confidence {
                Text("置信度").font(.caption).foregroundStyle(Theme.muted)
                Text("\(confidence)%")
                    .font(.body.weight(.bold))
                    .foregroundStyle(confidence >= 75 ? Theme.ok : Theme.warn)
                }
            }
            Text("完整度是识别到的目标词比例；识别置信度不代表发音准确度。")
                .font(.caption).foregroundStyle(Theme.muted)
            if !result.words.isEmpty {
                // Keep word-level feedback together in short runs that the page layout can wrap.
                ForEach(Array(stride(from: 0, to: result.words.count, by: 6)), id: \.self) { start in
                    let end = min(start + 6, result.words.count)
                    result.words[start..<end].reduce(Text("")) { line, word in
                        line + Text(word.text + " ").foregroundStyle(color(of: word.confidence))
                    }.font(.subheadline)
                }
            } else {
                ReadingText(text: result.text, font: .footnote, title: "完整跟读记录").foregroundStyle(Theme.muted)
            }
        }
    }

    private func color(of c: Float) -> Color {
        c >= 0.7 ? Theme.ok : (c >= 0.4 ? Theme.warn : Theme.bad)
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
                .padding(.vertical, 12).frame(minHeight:48)
                .background(color)
                .foregroundStyle(Theme.onAccent)
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
                .padding(.vertical, 10).frame(minHeight:44)
                .foregroundStyle(color)
                .background(Theme.cardDeep,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(Theme.edge))
        }
    }
}

struct BigWord: View {
    let word: String
    var body: some View {
        Text(word)
            .font(.system(.largeTitle,design:.serif).weight(.semibold))
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
                .font(.title2)
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
            .font(.caption.weight(.medium))
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
        Group {
            HStack(alignment: .top, spacing: 8) {
                TagLabel(text: tag, color: tagColor)
                Spacer()
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
                                .font(.body)
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
            ReadingText(text: sentence.text, font: .body, title: "完整例句")
            if let zh = sentence.zh, !zh.isEmpty {
                ReadingText(text: zh, font: .footnote, title: "完整译文").foregroundStyle(Theme.muted)
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
            } label: { Text(reporting ? "正在提交…":"例句纠错").font(.caption).foregroundStyle(Theme.muted).frame(minHeight:44) }.disabled(reporting)
            if !reportMessage.isEmpty { Text(reportMessage).font(.caption).foregroundStyle(Theme.muted) }
            if let recallNote {
                Text(recallNote).font(.caption).foregroundStyle(Theme.muted)
            }

            if swapError {
                Text("暂时无法换句，请稍后重试。")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
        }
    }
}

/// 4 选 1 选项按钮（答题后高亮对错）
struct QuizOptionsView: View {
    let options: [QuizOption]
    let onPick: (Bool) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var reading: Int?
    @State private var feedback = QuizAnswerFeedback()

    var body: some View {
        ScreenPages(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                let long = o.text.count > (typeSize.isAccessibilitySize ? 30 : 100)
                Button {
                    if long { reading = i } else { feedback.choose(i, correct: o.ok, commit: onPick) }
                } label: {
                    HStack(spacing:12) {
                        Text(String(UnicodeScalar(65+i)!)).font(.caption.monospaced().bold())
                            .frame(minWidth:26,minHeight:26).background(Theme.card,in:RoundedRectangle(cornerRadius:7)).accessibilityHidden(true)
                        Text(o.text).font(.body).lineLimit(long ? 2 : nil)
                        if long { Image(systemName: "book.pages").accessibilityLabel("查看完整选项") }
                        if feedback.picked != nil && (o.ok || feedback.picked==i) {
                            Image(systemName:o.ok ? "checkmark.circle.fill":"xmark.circle").accessibilityLabel(o.ok ? "正确":"错误")
                        }
                    }
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
        .sheet(isPresented: Binding(get: { reading != nil }, set: { if !$0 { reading = nil } })) {
            if let i = reading, options.indices.contains(i) {
                FullTextReader(text: options[i].text, title: "选项 " + String(UnicodeScalar(65+i)!),
                               confirm: ("选择此项", { reading = nil; feedback.choose(i, correct: options[i].ok, commit: onPick) }))
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
            }.font(.caption).foregroundStyle(Theme.muted).frame(minHeight:44).disabled(running)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(Theme.muted) }
        }
    }
}

struct NavigationAction:View {
    let title:String
    let action:()->Void
    var body:some View {
        Button(action:action) {
            Label(title,systemImage:"chevron.backward").font(.subheadline.weight(.medium))
                .padding(.horizontal,12).frame(minWidth:44,minHeight:44)
                .background(Theme.cardDeep,in:RoundedRectangle(cornerRadius:12)).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(Theme.accent)
    }
}
