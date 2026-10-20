import SwiftUI

/// 定级测试（CAT 自适应版）：每题出在当前后验边界上，收敛即停
/// - 起点 3000 位；每答一题后验更新，下一题位置 = 当前估值均值（信息量最大）
/// - 答错即时反馈为难度下降（惩罚）；答对上升（奖励）——双向自适应
/// - 收敛（std<400 且 ≥12 题）提前结束；30 题兜底；连错 8 题安全网（按均值下限收）
/// - 答错词自动进 pendingNew 优先补学（与旧版一致）
struct PlacementView: View {
    @Environment(AppState.self) private var app
    @State private var quiz: Quiz?
    @State private var loading = true
    @State private var loadFailed = false
    @State private var askedWords = Set<String>()
    @State private var catPos = 3000            // CAT 起始探测位（词库中段）
    @State private var finished: Int? = nil

    private var probeCount: Int { app.S.probeCount }
    private var probeMean: Int { Int(StudyEngine.postMean(app.S).rounded()) }

    var body: some View {
        VStack(spacing: 0) {
            if let f = finished {
                doneView(boundary: f)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("智能定级 · 第 \(probeCount + 1) 题")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        Spacer()
                        Button("退出") { app.route = .home }.foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    ProgressBar(value: min(1, Double(probeCount) / 24.0))   // 预期 12~24 题收敛
                        .padding(.horizontal, 16)
                    // 题干居中于上方剩余空间
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
                // 选项钉死底部拇指区
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        if let quiz, !loading {
                            QuizOptionsView(options: quiz.options) { ok in answer(quiz, ok: ok) }
                        }
                        Text(probeCount >= 4
                             ? "当前估计 ≈\(probeMean) 词 · 答错的词会自动加入学习计划"
                             : "答错的词会自动加入学习计划 · 收敛后自动结束")
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

    /// CAT 主循环的一步：在当前边界取一题
    private func loadNext() async {
        // 收敛判定：证据够窄就提前结束
        if probeCount >= 12, StudyEngine.postStd(app.S) < 400 {
            finish(boundary: max(1, probeMean))
            return
        }
        if probeCount >= 30 {   // 兜底上限
            finish(boundary: max(1, probeMean))
            return
        }
        loading = true
        loadFailed = false
        var q: Quiz? = nil
        for _ in 0..<3 {   // 位置无效/词重复时前移再试
            if let cand = try? await APIClient.shared.quiz(
                pos: catPos, seed: Int(Date().timeIntervalSince1970) % 99991),
               cand.options.count >= 4, !askedWords.contains(cand.word) {
                q = cand
                break
            }
            catPos = min(catPos + 25, 10987)
        }
        guard let q else {
            loadFailed = true
            loading = false
            return
        }
        askedWords.insert(q.word)
        quiz = q
        loading = false
        app.audio.play(q.word, voice: app.S.settings.voice)
    }

    private func answer(_ q: Quiz, ok: Bool) {
        StudyEngine.posteriorUpdate(&app.S, rank: q.pos, resp: ok ? 1 : 0)
        app.S.wrongStreak = ok ? 0 : app.S.wrongStreak + 1
        if !ok && !app.S.pendingNew.contains(where: { $0.word == q.word }) {
            app.S.pendingNew.append(NewWord(word: q.word, pos: q.pos))
        }
        app.save()
        if app.S.wrongStreak >= 8 {   // 安全网：纯新手直接收在低位
            finish(boundary: 1)
            return
        }
        // 下一题出在当前后验均值处（边界追踪）
        catPos = min(max(Int(StudyEngine.postMean(app.S).rounded()), 1), 10987)
        Task { await loadNext() }
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
                Text("你的词汇边界 ≈ \(boundary)（自适应探测 \(probeCount) 题）\n新词将从这个位置开始，\(app.S.pendingNew.count) 个探测生词会优先补学")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                PrimaryButton(title: "开始学习") { app.route = .home }
            }
            Spacer()
        }
    }
}
