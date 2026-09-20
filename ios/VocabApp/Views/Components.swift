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
    static let bad = Color(.sRGB, red: 0.860, green: 0.290, blue: 0.290, opacity: 1)
    static let muted = Color(.sRGB, red: 0.480, green: 0.520, blue: 0.580, opacity: 1)
    static let text = Color(.sRGB, red: 0.910, green: 0.930, blue: 0.960, opacity: 1)
}

// MARK: - 通用组件

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
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(color)
                .foregroundStyle(.white)
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
                .font(.system(size: 15, weight: .medium))
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
            .font(.system(size: 38, weight: .bold))
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
    var recallNote: String? = nil
    var onSwap: (SentenceItem?) -> Void

    @State private var swapping = false

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
                    Task {
                        let fresh = await app.swapSentence(word: word, oldText: sentence.text, kind: kind)
                        await MainActor.run {
                            onSwap(fresh)
                            swapping = false
                        }
                    }
                } label: {
                    if swapping {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .buttonStyle(.plain)
                .disabled(swapping)
            }
            if let recallNote {
                Text(recallNote).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            if let zh = sentence.zh, !zh.isEmpty {
                Text(zh).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        }
        .opacity(swapping ? 0.35 : 1)
    }
}

/// 4 选 1 选项按钮（答题后高亮对错）
struct QuizOptionsView: View {
    let options: [QuizOption]
    let onPick: (Bool) -> Void
    @State private var picked: Int? = nil

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                Button {
                    guard picked == nil else { return }
                    picked = i
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                        onPick(o.ok)
                        picked = nil
                    }
                } label: {
                    Text(o.text)
                        .font(.system(size: 16))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12).padding(.horizontal, 14)
                        .background(bg(for: i, ok: o.ok))
                        .foregroundStyle(Theme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(picked != nil)
            }
        }
    }

    private func bg(for i: Int, ok: Bool) -> Color {
        guard let p = picked else { return Theme.cardDeep }
        if ok { return Theme.ok.opacity(0.35) }
        if p == i { return Theme.bad.opacity(0.35) }
        return Theme.cardDeep.opacity(0.5)
    }
}
