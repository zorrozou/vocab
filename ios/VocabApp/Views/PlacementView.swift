import SwiftUI

/// 定级测试：30 道 4 选 1（一次拉取零网络答题），网格贝叶斯估计词汇边界
struct PlacementView: View {
    @Environment(AppState.self) private var app
    @State private var loadError = false
    @State private var finished: Int? = nil   // 定级结果边界

    private var set: PlacementSet? { app.placementSet }

    var body: some View {
        VStack(spacing: 0) {
            if let f = finished {
                doneView(boundary: f)
            } else if let set, app.S.probeCount < set.words.count {
                quizView(set: set)
            } else if let set, app.S.probeCount >= set.words.count {
                Color.clear.onAppear {
                    finish(boundary: max(1, Int(StudyEngine.postMean(app.S).rounded())))
                }
            } else {
                loadingView
            }
        }
        .task {
            if app.placementSet == nil { await loadSet() }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            Spacer()
            if loadError {
                Text("网络异常，请重试").foregroundStyle(Theme.muted)
                PrimaryButton(title: "重试") {
                    Task { await loadSet() }
                }
                .padding(.horizontal, 40)
            } else {
                ProgressView()
                Text("定级题库加载中…").foregroundStyle(Theme.muted)
            }
            Spacer()
        }
    }

    private func loadSet() async {
        loadError = false
        do {
            app.placementSet = try await APIClient.shared.placementSet(
                seed: app.deviceId() + "\(Int(Date().timeIntervalSince1970))")
        } catch {
            print("[VocabApp] placementSet 失败: \(error)")
            loadError = true
        }
    }

    private func quizView(set: PlacementSet) -> some View {
        let item = set.words[app.S.probeCount]
        return VStack(spacing: 0) {
            HStack {
                Text("定级测试 \(app.S.probeCount + 1)/\(set.words.count)")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button("退出") { app.route = .home }.foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            ScrollView {
                Card {
                    Text("选出正确词义").font(.system(size: 14)).foregroundStyle(Theme.muted)
                    HStack(alignment: .center, spacing: 10) {
                        BigWord(word: item.word)
                        PlayButton(text: item.word)
                    }
                    QuizOptionsView(options: item.options) { ok in
                        answer(item: item, ok: ok, total: set.words.count)
                    }
                    ProgressBar(value: Double(app.S.probeCount) / Double(set.words.count))
                    Text(app.S.probeCount >= 4
                         ? "当前估计 ≈\(Int(StudyEngine.postMean(app.S))) 词 · 答错的词会自动加入学习计划"
                         : "答错的词会自动加入学习计划")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
        }
        .onAppear { app.audio.play(item.word, voice: app.S.settings.voice) }
    }

    private func answer(item: PlacementItem, ok: Bool, total: Int) {
        StudyEngine.posteriorUpdate(&app.S, rank: item.pos, resp: ok ? 1 : 0)
        app.S.wrongStreak = ok ? 0 : app.S.wrongStreak + 1
        if !ok && !app.S.pendingNew.contains(where: { $0.word == item.word }) {
            app.S.pendingNew.append(NewWord(word: item.word, pos: item.pos))
        }
        app.save()
        if app.S.wrongStreak >= 8 {
            finish(boundary: 1)
        } else if app.S.probeCount >= total {
            finish(boundary: max(1, Int(StudyEngine.postMean(app.S).rounded())))
        }
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
                Text("你的词汇边界 ≈ \(boundary)（共探测 \(app.S.probeCount) 词）\n新词将从这个位置开始，\(app.S.pendingNew.count) 个探测生词会优先补学")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                PrimaryButton(title: "开始学习") { app.route = .home }
            }
            Spacer()
        }
    }
}
