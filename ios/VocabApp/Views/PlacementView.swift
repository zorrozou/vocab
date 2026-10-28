import SwiftUI

/// 定级测试共 30 题：前 12 题覆盖六个词汇量区间，后 18 题围绕当前估计探测。
/// 答完后根据各区间累计证据计算学习边界。
struct PlacementView: View {
    @Environment(AppState.self) private var app
    @State private var quiz: Quiz?
    @State private var loading = true
    @State private var loadFailed = false
    @State private var positions: [Int] = []
    @State private var recentMeans: [Double] = []
    @State private var finished: Int? = nil
    @State private var answering = false

    private let bands = [(1, 2000), (2001, 4000), (4001, 6000),
                         (6001, 8000), (8001, 10000), (10001, 10987)]
    private var probeCount: Int { app.S.probeCount }
    private var currentBand: Int {
        guard let quiz else { return 1 }
        return (bands.firstIndex { quiz.pos >= $0.0 && quiz.pos <= $0.1 } ?? 0) + 1
    }
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
                        Text("智能定级 · 第 \(probeCount + 1)/30 题 · 第 \(currentBand) 区间")
                            .accessibilityIdentifier("placement-progress")
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

    private func makePositions() -> [Int] {
        var out: [Int] = []
        for (index, (lo, hi)) in bands.enumerated() {
            let used = Set(app.S.bandEvidence?["\(index)"]?.events.values.map(\.pos) ?? [])
            var candidates = (lo...hi).filter { !used.contains($0) }
            if candidates.count < 2 { candidates = Array(lo...hi) }
            for _ in 0..<2 { out.append(candidates.remove(at: Int.random(in: 0..<candidates.count))) }
        }
        return out
    }

    private func posteriorAround(_ mean: Int, sd: Double = 500) -> [Double] {
        let raw = StudyEngine.grid.map { exp(-pow(($0 - Double(mean)) / sd, 2) / 2) }
        let sum = raw.reduce(0, +)
        return raw.map { $0 / sum }
    }

    private var scoreText: String {
        bands.enumerated().map { i, b in
            let stat = app.S.bandStats?["\(i)"]
            let known = stat?.a ?? 0, total = known + (stat?.b ?? 0)
            return "\(b.0)~\(b.1)：\(formatCount(known))/\(formatCount(total))"
        }.joined(separator: "　")
    }

    private func formatCount(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private func loadNext() async {
        answering = false
        if positions.isEmpty { positions = makePositions() }
        if probeCount >= 30 {
            finish(boundary: finalMean)
            return
        }
        loading = true
        loadFailed = false
        // 前 12 题每档 2 题覆盖全部级别；后 18 题在当前估计边界附近集中探测
        let pos = probeCount < positions.count
            ? positions[probeCount]
            : min(max(Int(StudyEngine.postMean(app.S).rounded()) + Int.random(in: -150...150), 1), 10987)
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
        guard !answering else { return }
        answering = true
        StudyEngine.recordKnowledge(&app.S, word: q.word, pos: q.pos, ok: ok, isPlacement: true)
        StudyEngine.posteriorUpdate(&app.S, rank: q.pos, resp: ok ? 1 : 0, guess: guessed ? 0.25 : 0)
        recentMeans.append(StudyEngine.postMean(app.S))
        app.S.log.append(LogEntry(d: DayUtil.today(), word: q.word, rating: ok ? 4 : 1, kind: "placement"))
        if !ok && !app.S.pendingNew.contains(where: { $0.word == q.word }) {
            app.S.pendingNew.append(NewWord(word: q.word, pos: q.pos))
        }
        app.save()
        Task { await loadNext() }
    }

    private func finish(boundary: Int) {
        app.S.calibrated = true
        app.S.frontier = StudyEngine.placementPointer(app.S)
        app.S.pointer = app.S.frontier
        // 保留 30 题形成的后验供每日追踪，不用单点估值重置它
        app.save()
        finished = app.S.frontier
    }

    private func doneView(boundary: Int) -> some View {
        VStack {
            Spacer()
            Card {
                Text("定级完成").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                Text("预计认识 \(StudyEngine.expectedKnown(app.S)) 词")
                    .font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.accentLight)
                Text("当前级别：\(levelDisplayName(levelForPos(boundary))) · 发词位置 \(boundary)\n\(scoreText)\n新词将从这个位置开始，\(app.S.pendingNew.count) 个答错词会优先补学")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                PrimaryButton(title: "开始学习") { app.route = .home }
            }
            Spacer()
        }
    }
}
