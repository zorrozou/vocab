import SwiftUI

/// 定级测试共 30 题：前 12 题覆盖六个词汇量区间，后 18 题围绕当前估计探测。
/// 答完后根据各区间累计证据计算学习边界。
struct PlacementView: View {
    @Environment(AppState.self) private var app
    @State private var quiz: Quiz?
    @State private var loading = true
    @State private var loadFailed = false
    @State private var unavailablePositions: Set<Int> = []
    @State private var requestID = UUID()
    @State private var recentMeans: [Double] = []
    @State private var finished: Int? = nil
    @State private var answering = false
    @State private var startingStudy = false
    @State private var startError = ""

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
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        Spacer()
                        NavigationAction(title: "退出") { app.route = .home }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    ProgressBar(value: min(1, Double(probeCount) / 30.0))
                        .padding(.horizontal, 16)
                    VStack(spacing: 12) {
                        if loading {
                            ProgressView()
                        } else if loadFailed {
                            Text("网络异常，请重试").foregroundStyle(Theme.muted)
                            GhostButton(title: "重试") { Task { await loadNext() } }
                        } else if let quiz {
                            HStack(alignment: .center, spacing: 10) {
                                BigWord(word: quiz.word).accessibilityIdentifier("placement-word")
                            }
                            Text("选出正确词义").font(.subheadline).foregroundStyle(Theme.muted)
                        }
                    }
                    if let quiz, !loading {
                        QuizOptionsView(options: quiz.options,spokenWord:quiz.word) { ok in answer(quiz, ok: ok) }.id(quiz.pos).disabled(answering)
                        GhostButton(title: "不认识") { answer(quiz, ok: false, guessed: false) }.disabled(answering)
                    }
                    Text("不确定请点「不认识」，不要猜")
                        .font(.caption).foregroundStyle(Theme.muted)
                }.padding(.horizontal, 14)
            }
        }
        .task { await loadNext() }
        .onDisappear { requestID = UUID(); app.audio.stop() }
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
        let id = UUID(); requestID = id
        let owner = app.auth, epoch = app.S.placementVersion, session = app.placementSession
        let count = probeCount
        func active() -> Bool {
            !Task.isCancelled && requestID == id && app.route == .placement &&
            app.auth == owner && app.S.placementVersion == epoch && app.placementSession == session
        }
        answering = false
        quiz = nil
        if probeCount >= 30 { finish(boundary: finalMean); return }
        loading = true
        loadFailed = false
        for _ in 0..<3 {
            guard active() else { return }
            if probeCount != count { await loadNext(); return }
            guard let pos = StudyEngine.placementCandidatePool(app.S, excluding: unavailablePositions).randomElement() else { break }
            do {
                let cand = try await APIClient.shared.quiz(pos: pos, seed: Int.random(in: 1...99990))
                guard active() else { return }
                if probeCount != count { await loadNext(); return }
                guard cand.pos == pos, cand.matches(word: cand.word),
                      !StudyEngine.placementUsedPositions(app.S).contains(cand.pos) else {
                    unavailablePositions.insert(pos); continue
                }
                quiz = cand
                loading = false
                app.audio.play(cand.word, voice: app.S.settings.voice)
                return
            } catch {
                // A network error does not make a word unavailable.
                guard active() else { return }
            }
        }
        guard active() else { return }
        loadFailed = true
        loading = false
    }

    private func answer(_ q: Quiz, ok: Bool, guessed: Bool = true) {
        guard !answering, !loading, app.route == .placement,
              quiz?.pos == q.pos, quiz?.word == q.word else { return }
        answering = true
        guard !StudyEngine.placementUsedPositions(app.S).contains(q.pos) else {
            Task { await loadNext() }; return
        }
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
        ScreenPages {
            Text("定级完成").font(.title2.weight(.bold)).foregroundStyle(Theme.text)
            Text(StudyEngine.placementAtCeiling(app.S) ? "接近词库上限" : "预计认识 \(StudyEngine.expectedKnown(app.S)) 词")
                .font(.largeTitle.weight(.bold)).foregroundStyle(Theme.accentLight)
            Text(
                "当前级别：\(levelDisplayName(levelForPos(boundary))) · 发词位置 \(boundary)\n\(scoreText)\n新词将从这个位置开始，\(app.S.pendingNew.count) 个答错词会优先补学"
            )
            .font(.subheadline).foregroundStyle(Theme.muted)
            .multilineTextAlignment(.center)
            Text(StudyEngine.placementAtCeiling(app.S)
                 ? "已接近词库测量上限，更高水平暂无法可靠区分；此结果仅为近似估计。"
                 : "这是近似估计，可随学习逐步调整。")
                .font(.footnote).foregroundStyle(Theme.muted)
            PrimaryButton(title: startingStudy ? "正在准备…" : "开始学习") {
                guard !startingStudy else { return }
                startingStudy = true
                startError = ""
                let generation = app.routeGeneration, owner = app.auth
                Task {
                    let ready = await app.buildQueue()
                    guard app.routeGeneration == generation, app.auth == owner else { return }
                    startingStudy = false
                    if ready {
                        if app.session.queue.isEmpty { app.markDayDone() }
                        app.route = .session
                    } else {
                        startError = "任务加载失败，请检查网络后重试。"
                    }
                }
            }.disabled(startingStudy)
            if !startError.isEmpty { Text(startError).foregroundStyle(Theme.warn) }
            GhostButton(title: "返回首页") { app.route = .home }
        }.padding(16)
    }
}