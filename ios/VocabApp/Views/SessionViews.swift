import OSLog
import SwiftUI

/// 学习会话路由器：队列 → （学习卡/复习卡）→ 当日验收测试 → 完成页
struct SessionView: View {
    @Environment(AppState.self) private var app

    /// 今日已学新词（去重）——队列走完后验收
    private var learnedTodayWords: [String] {
        let today = DayUtil.today()
        var seen = Set<String>()
        return app.S.log.filter { $0.d == today && $0.kind == "learn" }
            .map(\.word).filter { seen.insert($0).inserted }
    }

    private var needsAcceptance: Bool {
        guard !learnedTodayWords.isEmpty else { return false }
        let today = DayUtil.today()
        if app.S.quizProgressDay == nil && app.S.quizDay == today { return false }
        let completed = app.S.quizProgressDay == today ? Set(app.S.quizCompleted ?? []) : []
        return learnedTodayWords.contains { !completed.contains($0) }
    }

    var body: some View {
        Group {
            if app.session.idx < app.session.queue.count {
                switch app.session.queue[app.session.idx] {
                case .learn(let w):
                    LearnCardView(item: w)
                        .id(w.word)
                case .review(let word):
                    ReviewQuizView(word: word)
                        .id(word)
                case .probe(let w, let reverse):
                    ProbeQuizView(item: w, reverse: reverse)
                        .id("probe-" + w.word)
                }
            } else if needsAcceptance {
                AcceptanceQuizView(words: learnedTodayWords)
            } else {
                DoneView()
            }
        }
        .onDisappear { app.audio.stop() }
    }
}

// MARK: - 新词学习卡

struct LearnCardView: View {
    @Environment(AppState.self) private var app
    let item: NewWord

    @State private var personal: PersonalizedSentence?
    @State private var sentences: [SentenceItem] = []
    @State private var weave: (text: String, zh: String?, weak: String)?
    @State private var shadowMsg = ""
    @State private var shadowResult: ShadowResult?
    @State private var acted = false
    @State private var detail: NewWord?
    @State private var detailError = ""
    @State private var trioLoading = false
    @State private var trioError = ""
    @State private var sideTasks: [Task<Void, Never>] = []   // 异步补句/织入任务，翻页即取消

    private var currentItem: NewWord { detail ?? item }
    private var hasMeaning: Bool {
        (currentItem.senses ?? []).contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ||
        !(currentItem.sense ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(title: "新词 \(app.session.idx + 1)/\(app.session.queue.count) · \(levelDisplayName(currentItem.level ?? levelForPos(currentItem.pos)))",
                          progress: Double(app.session.idx) / Double(max(1, app.session.queue.count)))
            // 内容区：可滚动，占满上方剩余空间
            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        HStack(alignment: .center, spacing: 10) {
                            BigWord(word: item.word)
                            PlayButton(text: item.word)
                        }
                        if let ph = currentItem.phonetic, !ph.isEmpty {
                            Text("/\(ph)/").font(.system(size: 15)).foregroundStyle(Theme.muted)
                        }
                        sensesView
                    }
                    Card { sentenceArea }
                    shadowArea
                }
                .padding(.vertical, 10)
            }
        }
        // 交互区：钉死在底部拇指区，不随内容长度浮动
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    ShadowHoldButton(target: shadowTarget(),
                                     onBusy: { shadowMsg = $0 },
                                     onResult: handleShadow)
                    PrimaryButton(title: "不熟悉", color: Theme.warn) { act(rating: 1) }.disabled(!hasMeaning || acted)
                    PrimaryButton(title: "学会了 →", color: Theme.ok) { act(rating: 3) }.disabled(!hasMeaning || acted)
                }
                if !hasMeaning { Button("稍后再学") { deferWord() }.disabled(acted) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .onAppear { setup() }
        // 卡片级不做 onDisappear stop：旧卡的 stop 可能晚于新卡开播触发，误杀新卡音频；新卡开播时会自行 stop 旧链
        // 但异步补句/织入任务要取消，防止翻页后旧卡内容晚到并开播
        .onDisappear { sideTasks.forEach { $0.cancel() } }
    }

    private var sensesView: some View {
        VStack(alignment: .leading, spacing: 6) {
            let senses = (currentItem.senses ?? []).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ForEach(Array(senses.enumerated()), id: \.offset) { _, s in
                HStack(alignment: .top, spacing: 6) {
                    Text(s.pos ?? "·").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accentLight)
                    Text(s.text).font(.system(size: 15)).foregroundStyle(Theme.text)
                }
            }
            if senses.isEmpty, let sense = currentItem.sense, !sense.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(sense).font(.system(size: 15)).foregroundStyle(Theme.text)
            } else if senses.isEmpty && detailError.isEmpty {
                HStack { Text("正在加载词义…"); ProgressView().scaleEffect(0.7) }
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
            if !detailError.isEmpty {
                Text(detailError).font(.system(size: 13)).foregroundStyle(Theme.bad)
                Button("重新加载词义") { loadDetail() }
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sentenceArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = personal {
                SentenceRow(word: item.word, tag: "个性化", tagColor: Theme.warn,
                            sentence: SentenceItem(tier: nil, text: p.text, zh: p.zh),
                            kind: "personal") { fresh in
                    if let fresh { personal = PersonalizedSentence(text: fresh.text, recall: nil, zh: fresh.zh) }
                    else { personal = nil }
                }
            }
            ForEach(Array(sentences.enumerated()), id: \.offset) { i, s in
                SentenceRow(word: item.word, tag: tierLabel(s.tier), tagColor: Theme.accentLight,
                            sentence: s, kind: "static", displayedSentences: sentences.map(\.text) + [personal?.text, weave?.text].compactMap { $0 }) { fresh in
                    if let fresh, sentences.contains(where: { $0.text == fresh.text }) { return }
                    sentences.replaceSentence(s, with: fresh)
                }
            }
            if let w = weave {
                SentenceRow(word: item.word, tag: "巩固", tagColor: Theme.accentLight,
                            sentence: SentenceItem(tier: nil, text: w.text, zh: w.zh),
                            kind: "weave", recallNote: "（复习词：\(w.weak)）") { _ in weave = nil }
            }
            if personal == nil && trioLoading {
                HStack {
                    TagLabel(text: "例句", color: Theme.muted)
                    Text("正在补充例句…").font(.system(size: 14)).foregroundStyle(Theme.muted)
                    ProgressView().scaleEffect(0.7)
                }
            } else if personal == nil && !trioError.isEmpty {
                Text(trioError).font(.system(size: 13)).foregroundStyle(Theme.muted)
                Button("重新加载例句") { loadTrio() }.font(.system(size: 14, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shadowArea: some View {
        Group {
            if app.speech.state == .listening {
                Text(app.speech.liveText.isEmpty ? "请朗读例句，读完松开手…" : app.speech.liveText)
                    .font(.system(size: 13)).foregroundStyle(Theme.accentLight)
            } else if let r = shadowResult {
                ShadowResultDisplay(result: r)
            } else if !shadowMsg.isEmpty {
                if shadowMsg.contains("权限") {
                    Button(shadowMsg + "（点我去开启）") {
                        #if canImport(UIKit)
                        if let u = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(u)
                        }
                        #endif
                    }
                    .font(.system(size: 13)).foregroundStyle(Theme.accentLight)
                } else {
                    Text(shadowMsg).font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func tierLabel(_ t: Int?) -> String {
        switch t { case 2: return "进阶"; case 3: return "挑战"; default: return "基础" }
    }

    private func setup() {
        personal = app.personalFor(item.word)
        if !hasMeaning { loadDetail() }
        if let s = currentItem.sentences, !s.isEmpty {
            sentences = s
        } else if let st = currentItem.static, !st.isEmpty {
            sentences = [SentenceItem(tier: 1, text: st, zh: nil)]
        }
        // 自动连播：单词 → 全部例句；同时记录薄弱词的真实展示/播放曝光
        let texts = [personal?.text].compactMap { $0 } + sentences.map { $0.text }
        if let p = personal { app.logSentenceExposures(p.text, source: "personal", played: true) }
        sentences.forEach { app.logSentenceExposures($0.text, source: "trio", played: true) }
        app.audio.playSequence(word: item.word, sentences: texts, voice: app.S.settings.voice)
        // 例句不足三条且非个性化：按需补三句套装。
        if personal == nil && sentences.count < 3 { loadTrio() }
        // 巩固句：40% 概率织入近期薄弱词
        if personal == nil {
            let t = Task {
                if let w = await app.maybeWeave(for: item.word), !Task.isCancelled {
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        weave = w
                        app.logExposure(word: w.weak, source: "weave", text: w.text, played: false)
                    }
                }
            }
            sideTasks.append(t)
        }
    }

    private func loadTrio() {
        guard !trioLoading else { return }
        trioLoading = true
        trioError = ""
        let t = Task {
            let weak = StudyEngine.recentWeakWords(app.S, today: DayUtil.today()).prefix(15).joined(separator: ",")
            do {
                let r = try await APIClient.shared.trio(word: item.word, weak: weak, cap: app.S.pointer + 10)
                guard !Task.isCancelled else { return }
                trioLoading = false
                guard !r.sentences.isEmpty else { trioError = "例句暂不可用。"; return }
                if personal == nil {
                    let had = !sentences.isEmpty
                    sentences = r.sentences
                    r.sentences.forEach { app.logSentenceExposures($0.text, source: "trio", played: true) }
                    if !had {
                        app.audio.playSequence(word: item.word, sentences: r.sentences.map { $0.text }, voice: app.S.settings.voice)
                    }
                    if r.sentences.count < 3 { trioError = "部分例句暂不可用。" }
                }
            } catch {
                guard !Task.isCancelled else { return }
                trioLoading = false
                trioError = "例句加载失败，请检查网络后重试。"
            }
        }
        sideTasks.append(t)
    }

    private func loadDetail() {
        detailError = ""
        let t = Task {
            do {
                let full = try await APIClient.shared.lexiconWord(item.word)
                guard !Task.isCancelled else { return }
                guard full.word.caseInsensitiveCompare(item.word) == .orderedSame else { throw APIError(message: "词条不匹配") }
                detail = full
                if !hasMeaning { detailError = "词义暂不可用，请重试或稍后再学。" }
                let hadSentences = !sentences.isEmpty
                if let fresh = full.sentences, !fresh.isEmpty {
                    sentences = fresh
                    if !hadSentences {
                        app.audio.playSequence(word: item.word, sentences: fresh.map { $0.text }, voice: app.S.settings.voice)
                    }
                }
            } catch {
                if !Task.isCancelled { detailError = "词义加载失败，请检查网络后重试" }
            }
        }
        sideTasks.append(t)
    }

    /// 跟读目标句：选最短的（挑战句 15~20 词一口气读不下来，基础句最适合跟读）
    private func shadowTarget() -> String {
        ([personal?.text].compactMap { $0 } + sentences.map { $0.text })
            .min { $0.count < $1.count } ?? ""
    }

    /// 跟读结果处理：展示逐词反馈 + 入档（<60% 记薄弱，当晚定制例句）
    private func handleShadow(_ res: ShadowResult?) {
        guard let res else { shadowMsg = "未听清，再试一次"; return }
        shadowMsg = ""
        shadowResult = res
        app.recordShadow(word: item.word, result: res)
    }

    private func deferWord() {
        guard !acted else { return }
        acted = true
        if app.S.cards[item.word] == nil && !app.S.pendingNew.contains(where: { $0.word == item.word }) {
            app.S.pendingNew.append(NewWord(word: item.word, pos: item.pos))
        }
        app.session.idx += 1
        app.save()
    }

    private func act(rating: Int) {
        guard !acted, hasMeaning else { return }
        acted = true
        let owner = app.auth, sessionID = app.session.id, index = app.session.idx, generation = app.routeGeneration
        Task {
            await app.learn(word: item.word, pos: item.pos, rating: rating, fromPending: item.fromPending == true)
            guard app.auth == owner else { return }
            if app.session.id == sessionID {
                app.session.learnedToday += 1
                if app.routeGeneration == generation && app.route == .session && app.session.idx == index {
                    app.session.idx += 1
                }
            }
            app.save()
        }
    }
}

// MARK: - 复习卡：先 4 选 1，再出答案卡

struct ReviewQuizView: View {
    @Environment(AppState.self) private var app
    let word: String

    @State private var quiz: Quiz?
    @State private var phase: Phase = .loading

    enum Phase { case loading, quizzing, flipping, answering(Bool) }

    private var card: CardState? { app.S.cards[word] }

    private var stageLabel: String {
        guard let c = card else { return "" }
        if c.pendingFsrs?.events.isEmpty == false { return "临时安排 · 待同步" }
        if StudyEngine.isMastered(c) { return "已掌握" }
        if let f = c.fsrs { return "稳定≈\(Int(f.stability))天" }
        if let s = c.stage { return s == 5 ? "长期池" : "D\(s)" }
        return ""
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(title: "复习 \(app.session.idx + 1)/\(app.session.queue.count) · \(stageLabel)",
                          progress: Double(app.session.idx) / Double(max(1, app.session.queue.count)))
            // 各阶段自己管理滚动与底部交互区
            switch phase {
            case .loading:
                Spacer()
                ProgressView()
                Spacer()
            case .quizzing:
                quizCard
            case .flipping:
                flipCard
            case .answering(let ok):
                AnswerCardView(word: word, quizOk: ok, verifiedPos: quiz?.pos, onNext: next, onUndo: {
                    app.undoReview()
                    // 撤销后直接回到本题选项；不能改成 loading——.task 不会再次执行，会永久卡住
                    phase = quiz == nil ? .loading : .quizzing
                })
            }
        }
        .task { await loadQuiz() }
        // 卡片级不做 onDisappear stop：旧卡的 stop 可能晚于新卡开播触发，误杀新卡音频；新卡开播时会自行 stop 旧链
    }

    /// 测验卡：单词居中于上方空间，选项钉死在底部拇指区
    /// 反向回想（稳定度≥14 天的成熟卡）：题干是中文词义，选项是英文单词，不放音（音会泄题）
    private var quizCard: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 12) {
                if quiz?.mode == "reverse", let prompt = quiz?.prompt {
                    Text(prompt)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                    Text("回想它的英文单词").font(.system(size: 14)).foregroundStyle(Theme.muted)
                } else {
                    HStack(alignment: .center, spacing: 10) {
                        BigWord(word: word)
                        PlayButton(text: word)
                    }
                    Text("选出正确词义").font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            // 反向回想不播单词（会泄题）；正向照旧自动朗读
            if quiz?.mode != "reverse" {
                app.audio.play(word, voice: app.S.settings.voice)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if let quiz {
                    QuizOptionsView(options: quiz.options) { ok in
                        phase = .answering(ok)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
    }

    private func loadQuiz() async {
        let pos = card?.pos ?? app.S.pointer
        // 成熟卡（稳定度≥14 天）走反向回想；其余正向再认
        let mature = (card?.fsrs?.stability ?? 0) >= 14
        let owner = app.auth, sessionID = app.session.id, generation = app.routeGeneration
        let result = try? await APIClient.shared.quiz(pos: pos, seed: Int(Date().timeIntervalSince1970) % 99991,
                                                    mode: mature ? "reverse" : "forward", word: word)
        guard !Task.isCancelled, app.auth == owner, app.session.id == sessionID,
              app.routeGeneration == generation, app.route == .session else { return }
        if let q = result, q.options.count >= 4 {
            quiz = q
            phase = .quizzing
        } else {
            // 出题失败 → 翻卡兜底（先回忆，再翻卡核对，与 web 一致）
            phase = .flipping
        }
    }

    /// 翻卡兜底卡：出题接口挂时的降级流程
    private var flipCard: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    BigWord(word: word)
                    PlayButton(text: word)
                }
                Text("先回忆词义，再翻卡核对").font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { app.audio.play(word, voice: app.S.settings.voice) }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: "显示释义") { phase = .answering(true) }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial)
        }
    }

    private func next() {
        app.session.idx += 1
        app.save()
    }
}

/// v1.4 水平探测题：与复习测验同形态；每日一题反向回想，检验是否真会而非眼熟。
/// 正向猜测率 0.25，反向为 0；答错的词进明日新词候选。出题失败直接跳过，不阻塞主流程
struct ProbeQuizView: View {
    @Environment(AppState.self) private var app
    let item: NewWord
    let reverse: Bool

    @State private var quiz: Quiz?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(title: "复习 \(app.session.idx + 1)/\(app.session.queue.count)",
                          progress: Double(app.session.idx) / Double(max(1, app.session.queue.count)))
            if loading {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                VStack(spacing: 0) {
                    Spacer()
                    VStack(spacing: 12) {
                        if reverse, let prompt = quiz?.prompt {
                            Text(prompt)
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(Theme.text)
                                .multilineTextAlignment(.center)
                            Text("回想它的英文单词").font(.system(size: 14)).foregroundStyle(Theme.muted)
                        } else {
                            HStack(alignment: .center, spacing: 10) {
                                BigWord(word: item.word)
                                PlayButton(text: item.word)
                            }
                            Text("选出正确词义").font(.system(size: 14)).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .onAppear {
                    if !reverse { app.audio.play(item.word, voice: app.S.settings.voice) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if let quiz {
                    QuizOptionsView(options: quiz.options) { ok in
                        var observed = item
                        observed.pos = quiz.pos
                        app.answerProbe(observed, ok: ok, reverse: reverse)
                        app.session.idx += 1
                        app.save()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .task { await loadQuiz() }
    }

    private func loadQuiz() async {
        let owner = app.auth, sessionID = app.session.id, index = app.session.idx, generation = app.routeGeneration
        let pos = item.pos > 0 ? item.pos : app.S.pointer
        let result = try? await APIClient.shared.quiz(pos: pos, seed: Int(Date().timeIntervalSince1970) % 99991,
                                                       mode: reverse ? "reverse" : "forward", word: item.word)
        guard !Task.isCancelled, app.auth == owner, app.session.id == sessionID,
              app.session.idx == index, app.routeGeneration == generation, app.route == .session else { return }
        if let q = result, q.options.count >= 4 {
            quiz = q
            loading = false
        } else {
            app.session.idx += 1   // 出题失败跳过本题
            app.save()
        }
    }
}

/// 答案卡：答错已记「忘记」（可撤销）；答对再选 困难/记得/熟练
struct AnswerCardView: View {
    @Environment(AppState.self) private var app
    let word: String
    let quizOk: Bool
    let verifiedPos: Int?
    let onNext: () -> Void
    let onUndo: () -> Void

    @State private var detail: NewWord?
    @State private var personal: PersonalizedSentence?
    @State private var sentences: [SentenceItem] = []
    @State private var shadowMsg = ""
    @State private var shadowResult: ShadowResult?
    @State private var rated = false
    @State private var detailError = ""

    var body: some View {
        VStack(spacing: 0) {
            // 内容区：可滚动
            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        Text(quizOk ? "✓ 答对了——这次掌握程度？" : "✗ 正确答案")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(quizOk ? Theme.ok : Theme.bad)
                        HStack(alignment: .center, spacing: 10) {
                            BigWord(word: word)
                            PlayButton(text: word)
                        }
                        if let ph = detail?.phonetic, !ph.isEmpty {
                            Text("/\(ph)/").font(.system(size: 15)).foregroundStyle(Theme.muted)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array((detail?.senses ?? []).enumerated()), id: \.offset) { _, s in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(s.pos ?? "·").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accentLight)
                                    Text(s.text).font(.system(size: 15)).foregroundStyle(Theme.text)
                                }
                            }
                            if detail == nil {
                                if detailError.isEmpty {
                                    HStack { Text("正在加载词义…"); ProgressView().scaleEffect(0.7) }
                                        .font(.system(size: 14)).foregroundStyle(Theme.muted)
                                } else {
                                    Text(detailError).font(.system(size: 13)).foregroundStyle(Theme.bad)
                                    Button("重新加载词义") { Task { await loadDetail() } }
                                        .font(.system(size: 14, weight: .semibold))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Card { sentenceArea }
                    if app.speech.state == .listening {
                        Text(app.speech.liveText.isEmpty ? "请朗读例句，读完松开手…" : app.speech.liveText)
                            .font(.system(size: 13)).foregroundStyle(Theme.accentLight)
                    } else if let r = shadowResult {
                        ShadowResultDisplay(result: r)
                    } else if !shadowMsg.isEmpty {
                        if shadowMsg.contains("权限") {
                            Button(shadowMsg + "（点我去开启）") {
                                #if canImport(UIKit)
                                if let u = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(u)
                                }
                                #endif
                            }
                            .font(.system(size: 13)).foregroundStyle(Theme.accentLight)
                        } else {
                            Text(shadowMsg).font(.system(size: 13)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                .padding(.vertical, 10)
            }
        }
        // 评分/继续：钉死底部拇指区
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                // 复习时也能跟读（与 learning 卡共享组件，读不好同样记薄弱）
                ShadowHoldButton(target: shadowTarget(),
                                 onBusy: { shadowMsg = $0 },
                                 onResult: handleShadow)
                if quizOk {
                    HStack(spacing: 10) {
                        GhostButton(title: "困难") { rate(2) }
                        GhostButton(title: "记得") { rate(3) }
                        PrimaryButton(title: "熟练", color: Theme.ok) { rate(4) }
                    }
                    Text("困难：费力想起 · 记得：正常想起 · 熟练：轻松想起")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                } else {
                    PrimaryButton(title: "继续 →") { app.commitUndoReview(); onNext() }
                    Text("已记为「忘记」，将按记忆间隔再次出现")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    // 手滑误点救星：撤销这次「忘记」，回到本题重来
                    Button("点错了？撤销这次「忘记」") { onUndo() }
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accentLight)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .task { await setup() }
        // 卡片级不做 onDisappear stop：旧卡的 stop 可能晚于新卡开播触发，误杀新卡音频；新卡开播时会自行 stop 旧链
    }

    private var sentenceArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = personal {
                SentenceRow(word: word, tag: "个性化", tagColor: Theme.warn,
                            sentence: SentenceItem(tier: nil, text: p.text, zh: p.zh),
                            kind: "personal") { fresh in
                    if let fresh { personal = PersonalizedSentence(text: fresh.text, recall: nil, zh: fresh.zh) }
                    else { personal = nil }
                }
            }
            ForEach(Array(sentences.enumerated()), id: \.offset) { i, s in
                SentenceRow(word: word, tag: { switch s.tier { case 2: return "进阶"; case 3: return "挑战"; default: return "基础" } }(),
                            tagColor: Theme.accentLight, sentence: s, kind: "static", displayedSentences: sentences.map(\.text) + [personal?.text].compactMap { $0 }) { fresh in
                    if let fresh, sentences.contains(where: { $0.text == fresh.text }) { return }
                    sentences.replaceSentence(s, with: fresh)
                }
            }
            if personal == nil && sentences.isEmpty {
                HStack {
                    TagLabel(text: "例句", color: Theme.muted)
                    Text("生成中…").font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setup() async {
        // 答错的「忘记」评分最先落账（对齐 web）：否则手快翻页会丢 Again、不降级
        if !quizOk {
            // 与撤销快照一起开始计数；任务被撤销或页面关闭后不能再次累加。
            app.session.reviewedToday += 1
            await app.review(word: word, rating: 1, allowUndo: true, verifiedPos: verifiedPos)
            guard !Task.isCancelled else { return }
            app.save()
        }
        personal = app.personalFor(word)
        await loadDetail()
        if sentences.isEmpty, let e = try? await APIClient.shared.ensure(word: word), !e.text.isEmpty {
            sentences = [SentenceItem(tier: 1, text: e.text, zh: nil)]
        }
        // 关键竞态守卫：用户可能在词条加载期间已经翻页（.task 已被取消），
        // 此时绝不能再开播，否则旧卡声音会盖到新卡上
        guard !Task.isCancelled else { return }
        let texts = [personal?.text].compactMap { $0 } + sentences.map { $0.text }
        if let p = personal { app.logSentenceExposures(p.text, source: "personal", played: true) }
        sentences.forEach { app.logSentenceExposures($0.text, source: "trio", played: true) }
        app.audio.playSequence(word: word, sentences: texts, voice: app.S.settings.voice)
    }

    private func loadDetail() async {
        detailError = ""
        do {
            let d = try await APIClient.shared.lexiconWord(word)
            guard d.word == word else { throw APIError(message: "词条不匹配") }
            detail = d
            sentences = d.sentences ?? (d.static.map { [SentenceItem(tier: 1, text: $0, zh: nil)] } ?? [])
        } catch {
            if !Task.isCancelled { detailError = "词义加载失败，请检查网络后重试" }
        }
    }

    /// 跟读目标句：选最短的（挑战句 15~20 词一口气读不下来，基础句最适合跟读）
    private func shadowTarget() -> String {
        ([personal?.text].compactMap { $0 } + sentences.map { $0.text })
            .min { $0.count < $1.count } ?? ""
    }

    /// 跟读结果处理：展示逐词反馈 + 入档（<60% 记薄弱）
    private func handleShadow(_ res: ShadowResult?) {
        guard let res else { shadowMsg = "未听清，再试一次"; return }
        shadowMsg = ""
        shadowResult = res
        app.recordShadow(word: word, result: res)
    }

    private func rate(_ r: Int) {
        guard !rated else { return }
        rated = true
        let owner = app.auth, sessionID = app.session.id, index = app.session.idx, generation = app.routeGeneration
        Task {
            await app.review(word: word, rating: r, verifiedPos: verifiedPos)
            guard app.auth == owner else { return }
            if app.session.id == sessionID {
                app.session.reviewedToday += 1
                if app.routeGeneration == generation && app.route == .session && app.session.idx == index {
                    onNext()
                }
            }
            app.save()
        }
    }
}

// MARK: - 当日新词验收测试（4 选 1）

struct AcceptanceQuizView: View {
    @Environment(AppState.self) private var app
    let words: [String]

    @State private var i = 0
    @State private var quiz: Quiz?
    @State private var loading = true
    @State private var answering = false

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(title: "验收测试 \(i + 1)/\(words.count) · 今天学的还记得吗？",
                          progress: Double(i) / Double(max(1, words.count)))
            // 单词居中于上方剩余空间
            Spacer()
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    BigWord(word: words[min(i, words.count - 1)])
                    PlayButton(text: words[min(i, words.count - 1)])
                }
                if loading {
                    ProgressView()
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        // 选项钉死底部拇指区
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if !loading, let quiz {
                    QuizOptionsView(options: quiz.options) { ok in answer(ok: ok) }
                } else if !loading {
                    Text("题目加载失败，验收尚未完成。请重试或稍后再做。")
                        .foregroundStyle(Theme.muted)
                    PrimaryButton(title: "重试本题") { Task { await load() } }
                    GhostButton(title: "稍后再做") { app.markDayDone(); app.route = .home }
                }
                Text("答对 → 按记忆间隔复习 · 答错 → 进入薄弱词，定制例句")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .task {
            if app.S.quizProgressDay == DayUtil.today() {
                let completed = Set(app.S.quizCompleted ?? [])
                i = words.firstIndex { !completed.contains($0) } ?? 0
            }
            app.audio.play(words[i], voice: app.S.settings.voice)
            await load()
        }
    }

    private func load() async {
        loading = true
        let owner = app.auth, sessionID = app.session.id, index = i, generation = app.routeGeneration
        let w = words[index]
        let pos = app.S.cards[w]?.pos ?? app.S.pointer
        let result = try? await APIClient.shared.quiz(pos: pos, seed: Int(Date().timeIntervalSince1970) % 99991, word: w)
        guard !Task.isCancelled, app.auth == owner, app.session.id == sessionID, i == index,
              app.routeGeneration == generation, app.route == .session else { return }
        quiz = result?.options.count == 4 ? result : nil
        loading = false
    }

    private func answer(ok: Bool) {
        guard !answering else { return }
        answering = true
        let w = words[i]
        let owner = app.auth, sessionID = app.session.id, index = i, generation = app.routeGeneration
        Task {
            // Completion is persisted with the review before the request suspends.
            await app.review(word: w, rating: ok ? 3 : 1, trackWeight: 1.0, acceptance: true, verifiedPos: quiz?.pos)
            guard app.auth == owner else { return }
            app.save()
            guard app.session.id == sessionID, app.routeGeneration == generation,
                  app.route == .session, i == index else { return }
            if words.allSatisfy({ (app.S.quizCompleted ?? []).contains($0) }) {
                app.markDayDone()
            } else {
                advance()
            }
        }
    }

    private func advance() {
        answering = false
        let completed = Set(app.S.quizCompleted ?? [])
        if let next = words.indices.first(where: { !completed.contains(words[$0]) }) {
            i = next
            app.audio.play(words[i], voice: app.S.settings.voice)
            Task { await load() }
        }
    }
}

// MARK: - 完成页 + 自动个性化

struct DoneView: View {
    @Environment(AppState.self) private var app
    @State private var genStatus = "正在为你的薄弱词定制例句…"
    @State private var genRows: [PersonalizedOut.Row] = []
    @State private var marked = false
    private var dailyPlan: StudyEngine.DailyPlanSummary {
        StudyEngine.dailyPlanSummary(app.S, day: DayUtil.today(), now: Date())
    }
    private var remainingCapacity: Int {
        StudyEngine.remainingDailyCapacity(app.S.log, day: DayUtil.today(), cap: app.S.settings.dailyCap)
    }
    private func todayCount(_ kind: String) -> Int {
        Set(app.S.log.filter { $0.d == DayUtil.today() && $0.kind == kind }.map(\.word)).count
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        Text(remainingCapacity == 0 && dailyPlan.dueAvailable > 0 ? "今日已达上限" : "本轮学习完成 🎉").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                        HStack(spacing: 0) {
                            StatCell(number: "\(todayCount("review"))", label: "今日复习")
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("session-reviewed")
                            StatCell(number: "\(todayCount("learn"))", label: "今日新词")
                            StatCell(number: "\(app.S.streak)", label: "连续天数")
                        }
                        if todayCount("probe") > 0 {
                            Text("每日上限还计入 \(todayCount("probe")) 个水平探测词；同一单词当天只计一次。")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        if dailyPlan.repeatPlanned > 0 {
                            Text("还有 \(dailyPlan.repeatPlanned) 个今天学过的词需要按间隔再复习，不增加今日单词数。")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        // v2.0 词级知识预测：预计认识词数 + 滞回级别 + 今日证据
                        if app.S.calibrated, app.S.posterior != nil {
                            let shown = app.S.track?.shownLevel ?? levelForPos(max(1, app.S.frontier))
                            Text("预计认识 \(StudyEngine.expectedKnown(app.S)) 词（\(levelDisplayName(shown))），明天从 \(app.S.pointer) 附近发词")
                                .font(.system(size: 12)).foregroundStyle(Theme.accentLight)
                            let todayLog = app.S.log.filter { $0.d == DayUtil.today() && ["learn", "review", "probe"].contains($0.kind) }
                            let ups = todayLog.filter { $0.rating >= 2 }.count
                            let downs = todayLog.filter { $0.rating == 1 }.count
                            let probes = todayLog.filter { $0.kind == "probe" }.count
                            Text("今日水平证据：↑\(ups) / ↓\(downs)（含 \(probes) 次水平探测）")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            if let note = app.S.track?.lastNote, !note.isEmpty {
                                Text(note).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                        }
                        if app.dueLaterTodayCount(onlyCompleted: remainingCapacity == 0) > 0 && dailyPlan.duePlanned == 0 {
                            Text("⏰ 今天晚些时候还有 \(app.dueLaterTodayCount(onlyCompleted: remainingCapacity == 0)) 个词到期，记得回来")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                    Card {
                        Text("今日薄弱词 · 个性化例句")
                            .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                        Text(genStatus).font(.system(size: 13)).foregroundStyle(Theme.muted)
                        ForEach(Array(genRows.enumerated()), id: \.offset) { _, r in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .top, spacing: 8) {
                                    TagLabel(text: "个性化", color: Theme.warn)
                                    Text(r.text).font(.system(size: 15)).foregroundStyle(Theme.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    PlayButton(text: r.text)
                                }
                                Text("（复习词：\(([r.target] + (r.recall?.split(separator: ",").map(String.init) ?? [])).joined(separator: "、"))）")
                                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                                if let zh = r.zh, !zh.isEmpty {
                                    Text(zh).font(.system(size: 13)).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
        // 底部行动区钉死拇指区
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if dailyPlan.duePlanned > 0 || dailyPlan.newPlanned > 0 {
                    PrimaryButton(title: "继续今日任务（复习 \(dailyPlan.duePlanned) · 新词 \(dailyPlan.newPlanned)）→") {
                        let generation = app.routeGeneration, owner = app.auth
                        Task {
                            let ready = await app.buildQueue()
                            guard app.routeGeneration == generation, app.auth == owner else { return }
                            if ready { app.route = .session }
                            else { genStatus = "任务加载失败，请返回主页检查网络后重试" }
                        }
                    }
                } else if dailyPlan.dueAvailable > 0 && remainingCapacity == 0 {
                    Text("今日已达上限，还有 \(dailyPlan.dueAvailable) 词到期；可在设置中调整上限。")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    GhostButton(title: "调整每日上限", color: Theme.accentLight) { app.route = .settings }
                        .accessibilityIdentifier("adjust-daily-cap")
                }
                GhostButton(title: "返回主页", color: Theme.muted) { app.route = .home }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .task {
            if !marked {
                marked = true
                app.markDayDone()
            }
            await app.autoPersonalize(
                onStatus: { s in genStatus = s },
                onRows: { rows in genRows = rows })
        }
    }
}

// MARK: - 会话页头

struct SessionHeader: View {
    @Environment(AppState.self) private var app
    let title: String
    let progress: Double

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button("退出") {
                    app.audio.stop()
                    app.commitUndoReview()
                    app.route = .home
                }
                .foregroundStyle(Theme.muted)
            }
            ProgressBar(value: progress)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
