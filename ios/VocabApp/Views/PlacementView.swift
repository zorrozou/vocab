import SwiftUI

/// 定级测试（加权升降梯）：从 4001~6000 起。
/// 每档先测 3 题：3 对升级、≤1 对降级、2 对补测 2 题；
/// 补到 5 题后：≥4 对升级、≤2 对降级、3 对定为当前边界。
/// 不用"一错就降"（正常波动会一路打回最低级），最终估值使用全部作答的概率模型。
struct PlacementView: View {
    @Environment(AppState.self) private var app
    @State private var quiz: Quiz?
    @State private var loading = true
    @State private var loadFailed = false
    @State private var ladderIdx = 2
    @State private var ladderScore = 0
    @State private var ladderCount = 0
    @State private var recentMeans: [Double] = []
    @State private var finished: Int? = nil

    private let bands = [(1, 2000), (2001, 4000), (4001, 6000),
                         (6001, 8000), (8001, 10000), (10001, 10987)]
    private var probeCount: Int { app.S.probeCount }
    private var finalMean: Int {
        let a = recentMeans.suffix(5).sorted()
        return a.isEmpty ? max(1, Int(StudyEngine.postMean(app.S).rounded())) : Int(a[a.count / 2].rounded())
    }

    var body: some View {
        VStack(spacing: 0) {
            if let f = finished {
                doneView(boundary: f)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("智能定级 · 第 \(probeCount + 1)/30 题 · 第 \(ladderIdx + 1) 区间")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        Spacer()
                        Button("退出") { app.route = .home }.foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    ProgressBar(value: min(1, Double(probeCount) / 30.0))
                        .padding(.horizontal, 16)
                    Spacer()
                    VStack(spacing: 12) {
                        if loading {
                            ProgressView()
                        } else if loadFailed {
                            Text("网络异常，请重试").foregroundStyle(Theme.muted)
                            GhostButton(title: "重试") { Task { await loadNext() } }
                        } else if let quiz {
                            HStack(alignment: .center, spacing: 10) {
                                BigWord(word: quiz.word)
                                PlayButton(text: quiz.word)
                            }
                            Text("选出正确词义").font(.system(size: 14)).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        if let quiz, !loading {
                            QuizOptionsView(options: quiz.options) { ok in answer(quiz, ok: ok) }
                            GhostButton(title: "不认识") { answer(quiz, ok: false, guessed: false) }
                        }
                        Text("不确定请点「不认识」，不要猜")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
                }
            }
        }
        .task { await loadNext() }
        .onDisappear { app.audio.stop() }
    }

    private func loadNext() async {
        if probeCount >= 30 {
            finish(boundary: finalMean)
            return
        }
        loading = true
        loadFailed = false
        let b = bands[ladderIdx]
        let pos = Int.random(in: b.0...b.1)
        for _ in 0..<3 {
            if let cand = try? await APIClient.shared.quiz(
                pos: pos, seed: Int(Date().timeIntervalSince1970) % 99991),
               cand.options.count >= 4 {
                quiz = cand
                loading = false
                app.audio.play(cand.word, voice: app.S.settings.voice)
                return
            }
        }
        loadFailed = true
        loading = false
    }

    private func answer(_ q: Quiz, ok: Bool, guessed: Bool = true) {
        StudyEngine.posteriorUpdate(&app.S, rank: q.pos, resp: ok ? 1 : 0, guess: guessed ? 0.25 : 0)
        recentMeans.append(StudyEngine.postMean(app.S))
        app.S.log.append(LogEntry(d: DayUtil.today(), word: q.word, rating: ok ? 4 : 1, kind: "placement"))
        app.S.probeCount += 1
        ladderCount += 1
        if ok { ladderScore += 1 }
        if !ok && !app.S.pendingNew.contains(where: { $0.word == q.word }) {
            app.S.pendingNew.append(NewWord(word: q.word, pos: q.pos))
        }
        app.save()

        if ladderCount < 3 {
            Task { await loadNext() }
            return
        }
        if ladderCount == 3 {
            if ladderScore == 3 {
                if ladderIdx == bands.count - 1 {
                    finish(boundary: bands[ladderIdx].1)
                } else {
                    ladderIdx += 1
                    ladderScore = 0
                    ladderCount = 0
                    Task { await loadNext() }
                }
                return
            }
            if ladderScore <= 1 {
                if ladderIdx == 0 {
                    finish(boundary: 1)
                } else {
                    ladderIdx -= 1
                    ladderScore = 0
                    ladderCount = 0
                    Task { await loadNext() }
                }
                return
            }
        }
        if ladderCount < 5 {
            Task { await loadNext() }   // 2 对补测 2 题
            return
        }
        if ladderScore >= 4 {
            if ladderIdx == bands.count - 1 {
                finish(boundary: bands[ladderIdx].1)
            } else {
                ladderIdx += 1
                ladderScore = 0
                ladderCount = 0
                Task { await loadNext() }
            }
            return
        }
        if ladderScore <= 2 {
            if ladderIdx == 0 {
                finish(boundary: 1)
            } else {
                ladderIdx -= 1
                ladderScore = 0
                ladderCount = 0
                Task { await loadNext() }
            }
            return
        }
        finish(boundary: finalMean)   // 3/5 即当前边界
    }

    private func finish(boundary: Int) {
        app.S.calibrated = true
        app.S.frontier = max(1, boundary)
        app.S.pointer = app.S.frontier
        app.save()
        finished = app.S.frontier
    }

    private func doneView(boundary: Int) -> some View {
        VStack {
            Spacer()
            Card {
                Text("定级完成").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                Text("\(boundary)")
                    .font(.system(size: 56, weight: .bold)).foregroundStyle(Theme.accentLight)
                Text("你的词汇边界 ≈ \(boundary)（\(levelDisplayName(levelForPos(boundary)))）\n从 4001~6000 起逐级升降，共 \(probeCount) 题\n新词将从这个位置开始，\(app.S.pendingNew.count) 个答错词会优先补学")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                PrimaryButton(title: "开始学习") { app.route = .home }
            }
            Spacer()
        }
    }
}
