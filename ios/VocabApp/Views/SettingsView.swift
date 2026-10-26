import SwiftUI

/// 设置：每日新词 / 每日上限 / 朗读嗓音（与 web 设置项一致）
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var showReplaceConfirm = false

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

                Card {
                    Text("定级").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GhostButton(title: "重新定级（30 题重测词汇边界）") {
                        showReplaceConfirm = true
                    }
                    Text("随时可测。已学单词、复习进度、连续天数全部保留，只更新词汇边界和后续新词起点。")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Card {
                    Text("估值校验").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GhostButton(title: "独立水平校验（24 题，不影响学习计划）") {
                        Task { await app.startValidation() }
                    }
                    if let r = app.S.evalReport {
                        Text("上次 \(r.date)：独立 ≈\(r.mean)，当前 ≈\(r.appMean)，差值 \(r.delta > 0 ? "+" : "")\(r.delta)")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("用独立题目检验当前估值偏差，不修改后验、卡片或发词位置。")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Card {
                    Text("复习提醒").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Text("每日提醒").font(.system(size: 15)).foregroundStyle(Theme.text)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { app.S.settings.notifyEnabled },
                            set: { v in
                                app.S.settings.notifyEnabled = v
                                app.save()
                                Task { await NotificationService.apply(settings: app.S.settings) }
                            }
                        ))
                        .labelsHidden()
                    }
                    if app.S.settings.notifyEnabled {
                        Text("提醒时间").font(.system(size: 13)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            ForEach([20, 21, 22], id: \.self) { h in
                                Button {
                                    app.S.settings.notifyHour = h
                                    app.save()
                                    Task { await NotificationService.apply(settings: app.S.settings) }
                                } label: {
                                    Text("\(h):00")
                                        .font(.system(size: 15, weight: app.S.settings.notifyHour == h ? .semibold : .regular))
                                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                                        .foregroundStyle(app.S.settings.notifyHour == h ? Theme.accentLight : Theme.text)
                                        .overlay(RoundedRectangle(cornerRadius: 8)
                                            .stroke(app.S.settings.notifyHour == h ? Theme.accent : Theme.muted.opacity(0.4)))
                                }
                            }
                        }
                        Text("纯本地通知，不联网。如果当天已完成学习，忽略提醒即可。")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .alert("重新定级？", isPresented: $showReplaceConfirm) {
            Button("开始重测") { app.startReplacement() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("重新回答最多 30 道词义选择题（自适应难度、全新随机卷），更新词汇边界和新词起点。已学单词与进度全部保留。")
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

/// 独立留出水平校验：单独后验，不影响学习计划；正反题交替，正向猜测率 0.25、反向为 0
struct ValidationView: View {
    @Environment(AppState.self) private var app
    @State private var quiz: Quiz?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            if let v = app.validation {
                if v.idx >= v.words.count, let r = app.S.evalReport {
                    resultView(r)
                } else {
                    SessionHeader(title: "独立水平校验 \(v.idx + 1)/\(v.words.count)",
                                  progress: Double(v.idx) / Double(max(1, v.words.count)))
                    if loading {
                        Spacer()
                        ProgressView()
                        Spacer()
                    } else {
                        VStack(spacing: 0) {
                            Spacer()
                            VStack(spacing: 12) {
                                let reverse = v.idx % 2 == 1
                                if reverse, let prompt = quiz?.prompt {
                                    Text(prompt).font(.system(size: 30, weight: .bold))
                                        .foregroundStyle(Theme.text).multilineTextAlignment(.center)
                                    Text("回想它的英文单词").font(.system(size: 14)).foregroundStyle(Theme.muted)
                                } else {
                                    HStack(spacing: 10) {
                                        BigWord(word: v.words[v.idx].word)
                                        PlayButton(text: v.words[v.idx].word)
                                    }
                                    Text("选出正确词义").font(.system(size: 14)).foregroundStyle(Theme.muted)
                                }
                                Text("只用于检验估值偏差，不影响学习计划")
                                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .onAppear {
                            if v.idx % 2 == 0 { app.audio.play(v.words[v.idx].word, voice: app.S.settings.voice) }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if let q = quiz, let v = app.validation, v.idx < v.words.count {
                    QuizOptionsView(options: q.options) { ok in
                        app.answerValidation(ok: ok)
                        quiz = nil
                        loading = true
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10).background(.regularMaterial)
        }
        .task(id: app.validation?.idx) { await loadQuiz() }
    }

    private func loadQuiz() async {
        guard let v = app.validation, v.idx < v.words.count else { return }
        let w = v.words[v.idx]
        let reverse = v.idx % 2 == 1
        if let q = try? await APIClient.shared.quiz(pos: w.pos, seed: Int(Date().timeIntervalSince1970) % 99991,
                                                    mode: reverse ? "reverse" : "forward"),
           q.options.count >= 4 {
            quiz = q
            loading = false
        } else {
            app.answerValidation(ok: false, countEvidence: false)   // 出题失败仅跳过，不产生校验证据
        }
    }

    private func resultView(_ r: EvalReport) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Text("独立校验结果").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
            Text("≈\(r.mean)").font(.system(size: 44, weight: .bold)).foregroundStyle(Theme.accentLight)
            Text("独立估值（±\(r.std)） · 答对 \(r.correct)/\(r.count)")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            Text("当前学习系统估值：\(r.appMean)\n差值（当前 − 独立）：\(r.delta > 0 ? "+" : "")\(r.delta)")
                .font(.system(size: 16)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            Text(abs(r.delta) <= 500 ? "与当前估值基本一致" : (r.delta > 0 ? "当前估值可能偏高" : "当前估值可能偏低"))
                .font(.system(size: 14)).foregroundStyle(Theme.warn)
            Text("本次校验没有修改你的后验、卡片或后续发词位置。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer()
            PrimaryButton(title: "返回设置") { app.closeValidation() }
            GhostButton(title: "重新校验") { Task { await app.startValidation() } }
        }
        .padding(.horizontal, 16)
    }
}
