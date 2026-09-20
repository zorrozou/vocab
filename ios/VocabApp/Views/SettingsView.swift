import SwiftUI

/// 设置：每日新词 / 每日上限 / 朗读嗓音（与 web 设置项一致）
struct SettingsView: View {
    @Environment(AppState.self) private var app

    private let voices: [(String, String)] = [
        ("en-US-AriaNeural", "Aria 女声"),
        ("en-US-GuyNeural", "Guy 男声"),
        ("en-US-JennyNeural", "Jenny 女声"),
        ("en-GB-SoniaNeural", "Sonia 英音"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                Button("返回") { app.route = .home }.foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            ScrollView {
                Card {
                    settingSection(title: "每日新词数",
                                   options: [5, 10, 15, 20],
                                   current: app.S.settings.newPerDay) { n in
                        app.S.settings.newPerDay = n; app.save()
                    }
                    settingSection(title: "每日总上限（复习+新词）",
                                   options: [30, 60, 100, 130],
                                   current: app.S.settings.dailyCap) { n in
                        app.S.settings.dailyCap = n; app.save()
                    }
                    Text("朗读嗓音").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(voices, id: \.0) { v, name in
                            let selected = (app.S.settings.voice ?? "en-US-AriaNeural") == v
                            Button {
                                app.S.settings.voice = v
                                app.save()
                                app.audio.play("The quick brown fox jumps over the lazy dog.", voice: v)
                            } label: {
                                Text(name)
                                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .foregroundStyle(selected ? Theme.accentLight : Theme.text)
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(selected ? Theme.accent : Theme.muted.opacity(0.4)))
                            }
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    private func settingSection(title: String, options: [Int], current: Int,
                                onPick: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { n in
                    Button { onPick(n) } label: {
                        Text("\(n)")
                            .font(.system(size: 15, weight: n == current ? .semibold : .regular))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .foregroundStyle(n == current ? Theme.accentLight : Theme.text)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(n == current ? Theme.accent : Theme.muted.opacity(0.4)))
                    }
                }
            }
        }
    }
}
