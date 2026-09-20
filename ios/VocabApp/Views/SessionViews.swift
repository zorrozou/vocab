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
                }
            } else if app.S.quizDay != DayUtil.today() && !learnedTodayWords.isEmpty {
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
    @State private var acted = false

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(title: "新词 \(app.session.idx + 1)/\(app.session.queue.count)（第 \(item.pos) 位）",
                          progress: Double(app.session.idx) / Double(max(1, app.session.queue.count)))
            ScrollView {
                Card {
                    HStack(alignment: .center, spacing: 10) {
                        BigWord(word: item.word)
                        PlayButton(text: item.word)
                    }
                    if let ph = item.phonetic, !ph.isEmpty {
                        Text("/\(ph)/").font(.system(size: 15)).foregroundStyle(Theme.muted)
                    }
                    sensesView
                    sentenceArea
                    shadowArea
                    HStack(spacing: 10) {
                        if app.speech.state == .listening {
                            PrimaryButton(title: "■ 停止", color: Theme.warn) {
                                app.speech.stopCapture(finalize: true)
                            }
                        } else {
                            GhostButton(title: "🎤 跟读") { startShadow() }
                        }
                        PrimaryButton(title: "不熟悉", color: Theme.warn) { act(rating: 1) }
                        PrimaryButton(title: "学会了 →", color: Theme.ok) { act(rating: 3) }
                    }
                }
            }
        }
        .onAppear { setup() }
        // 卡片级不做 onDisappear stop：旧卡的 stop 可能晚于新卡开播触发，误杀新卡音频；新卡开播时会自行 stop 旧链
    }

    private var sensesView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array((item.senses ?? []).enumerated()), id: \.offset) { _, s in
                HStack(alignment: .top, spacing: 6) {
                    Text(s.pos ?? "·").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accentLight)
                    Text(s.text).font(.system(size: 15)).foregroundStyle(Theme.text)
                }
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
                            sentence: s, kind: "static") { fresh in
                    if let fresh { sentences[i] = fresh } else { sentences.remove(at: i) }
                }
            }
            if let w = weave {
                SentenceRow(word: item.word, tag: "巩固", tagColor: Theme.accentLight,
                            sentence: SentenceItem(tier: nil, text: w.text, zh: w.zh),
                            kind: "weave", recallNote: "（复习词：\(w.weak)）") { _ in weave = nil }
            }
            if personal == nil && sentences.isEmpty {
                HStack {
                    TagLabel(text: "例句", color: Theme.muted)
                    Text("生成中…").font(.system(size: 14)).foregroundStyle(Theme.muted)
                    ProgressView().scaleEffect(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shadowArea: some View {
        Group {
            if app.speech.state == .listening {
                Text(app.speech.liveText.isEmpty ? "请朗读例句…" : app.speech.liveText)
                    .font(.system(size: 13)).foregroundStyle(Theme.accentLight)
            } else if !shadowMsg.isEmpty {
                Text(shadowMsg).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func tierLabel(_ t: Int?) -> String {
        switch t { case 2: return "进阶"; case 3: return "挑战"; default: return "基础" }
    }

    private func setup() {
        personal = app.S.personalized[item.word]
        if let s = item.sentences, !s.isEmpty {
            sentences = s
        } else if let st = item.static, !st.isEmpty {
            sentences = [SentenceItem(tier: 1, text: st, zh: nil)]
        }
        // 自动连播：单词 → 全部例句
        let texts = [personal?.text].compactMap { $0 } + sentences.map { $0.text }
        app.audio.playSequence(word: item.word, sentences: texts, voice: app.S.settings.voice)
        // 例句不足三条且非个性化：按需补三句套装
        if personal == nil && sentences.count < 3 {
            Task {
                let weak = StudyEngine.recentWeakWords(app.S, today: DayUtil.today()).prefix(15).joined(separator: ",")
                if let r = try? await APIClient.shared.trio(word: item.word, weak: weak, cap: app.S.pointer + 10),
                   !r.sentences.isEmpty {
                    await MainActor.run {
                        if personal == nil {
                            let had = sentences.isEmpty
                            sentences = r.sentences
                            if had {
                                app.audio.playSequence(word: item.word,
                                                       sentences: r.sentences.map { $0.text },
                                                       voice: app.S.settings.voice)
                            }
                        }
                    }
                }
            }
        }
        // 巩固句：40% 概率织入近期薄弱词
        if personal == nil {
            Task {
                if let w = await app.maybeWeave(for: item.word) {
                    await MainActor.run { weave = w }
                }
            }
        }
    }

    private func startShadow() {
        let target = personal?.text ?? sentences.first?.text ?? ""
        guard !target.isEmpty else { shadowMsg = "例句还在生成，稍等"; return }
        app.audio.stop()
        Task {
            guard await SpeechService.requestPermissions() else {
                shadowMsg = "需要麦克风和语音识别权限（设置 → 词航）"
                return
            }
            app.speech.start(target: target) { res in
                guard let res else { shadowMsg = "未听清，再试一次"; return }
                shadowMsg = "识别：\(res.text)\n完整度 \(res.completeness)% · 置信度 \(res.confidence)%"
            }
        }
    }

    private func act(rating: Int) {
        guard !acted else { return }
        acted = true
        Task {
            await app.learn(word: item.word, pos: item.pos, rating: rating)
            app.session.learnedToday += 1
            app.session.idx += 1
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
        if StudyEngine.isMastered(c) { return "已掌握" }
        if let f = c.fsrs { return "稳定≈\(Int(f.stability))天" }
        if let s = c.stage { return s == 5 ? "长期池" : "D\(s)" }
        return ""
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(title: "复习 \(app.session.idx + 1)/\(app.session.queue.count) · \(stageLabel)",
                          progress: Double(app.session.idx) / Double(max(1, app.session.queue.count)))
            ScrollView {
                switch phase {
                case .loading:
                    ProgressView().padding(.top, 60)
                case .quizzing:
                    quizCard
                case .flipping:
                    flipCard
                case .answering(let ok):
                    AnswerCardView(word: word, quizOk: ok, onNext: next)
                }
            }
        }
        .task { await loadQuiz() }
        // 卡片级不做 onDisappear stop：旧卡的 stop 可能晚于新卡开播触发，误杀新卡音频；新卡开播时会自行 stop 旧链
    }

    private var quizCard: some View {
        Card {
            HStack(alignment: .center, spacing: 10) {
                BigWord(word: word)
                PlayButton(text: word)
            }
            Text("选出正确词义：").font(.system(size: 14)).foregroundStyle(Theme.muted)
            if let quiz {
                QuizOptionsView(options: quiz.options) { ok in
                    phase = .answering(ok)
                }
            }
        }
        .onAppear { app.audio.play(word, voice: app.S.settings.voice) }
    }

    private func loadQuiz() async {
        let pos = card?.pos ?? app.S.pointer
        if let q = try? await APIClient.shared.quiz(pos: pos, seed: Int(Date().timeIntervalSince1970) % 99991),
           q.options.count >= 4 {
            quiz = q
            phase = .quizzing
        } else {
            // 出题失败 → 翻卡兜底（先回忆，再翻卡核对，与 web 一致）
            phase = .flipping
        }
    }

    /// 翻卡兜底卡：出题接口挂时的降级流程
    private var flipCard: some View {
        Card {
            HStack(alignment: .center, spacing: 10) {
                BigWord(word: word)
                PlayButton(text: word)
            }
            Text("先回忆词义，再翻卡核对").font(.system(size: 14)).foregroundStyle(Theme.muted)
            PrimaryButton(title: "显示释义") { phase = .answering(true) }
        }
        .onAppear { app.audio.play(word, voice: app.S.settings.voice) }
    }

    private func next() {
        app.session.idx += 1
        app.save()
    }
}

/// 答案卡：答错已记「忘记」；答对再选 困难/记得/熟练
struct AnswerCardView: View {
    @Environment(AppState.self) private var app
    let word: String
    let quizOk: Bool
    let onNext: () -> Void

    @State private var detail: NewWord?
    @State private var personal: PersonalizedSentence?
    @State private var sentences: [SentenceItem] = []
    @State private var rated = false

    var body: some View {
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            sentenceArea
            if quizOk {
                HStack(spacing: 10) {
                    GhostButton(title: "困难") { rate(2) }
                    GhostButton(title: "记得") { rate(3) }
                    PrimaryButton(title: "熟练", color: Theme.ok) { rate(4) }
                }
            } else {
                PrimaryButton(title: "继续 →") { onNext() }
                Text("已记为「忘记」，降级并明天再见")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
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
                            tagColor: Theme.accentLight, sentence: s, kind: "static") { fresh in
                    if let fresh { sentences[i] = fresh } else { sentences.remove(at: i) }
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
        personal = app.S.personalized[word]
        let pos = app.S.cards[word]?.pos ?? app.S.pointer
        if let r = try? await APIClient.shared.lexiconAt(pos: pos, n: 1),
           let d = r.words.first(where: { $0.word == word }) ?? r.words.first {
            detail = d
            sentences = d.sentences ?? (d.static.map { [SentenceItem(tier: 1, text: $0, zh: nil)] } ?? [])
        }
        if sentences.isEmpty, let e = try? await APIClient.shared.ensure(word: word), !e.text.isEmpty {
            sentences = [SentenceItem(tier: 1, text: e.text, zh: nil)]
        }
        let texts = [personal?.text].compactMap { $0 } + sentences.map { $0.text }
        app.audio.playSequence(word: word, sentences: texts, voice: app.S.settings.voice)
        if !quizOk {
            await app.review(word: word, rating: 1)
            app.session.reviewedToday += 1
            app.save()
        }
    }

    private func rate(_ r: Int) {
        guard !rated else { return }
        rated = true
        Task {
            await app.review(word: word, rating: r)
            app.session.reviewedToday += 1
            app.save()
            onNext()
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

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(title: "验收测试 \(i + 1)/\(words.count) · 今天学的还记得吗？",
                          progress: Double(i) / Double(max(1, words.count)))
            ScrollView {
                Card {
                    HStack(alignment: .center, spacing: 10) {
                        BigWord(word: words[min(i, words.count - 1)])
                        PlayButton(text: words[min(i, words.count - 1)])
                    }
                    if loading {
                        ProgressView()
                    } else if let quiz {
                        QuizOptionsView(options: quiz.options) { ok in answer(ok: ok) }
                    } else {
                        Text("出题失败，跳过").foregroundStyle(Theme.muted)
                    }
                    Text("答对 → 明天复习见 · 答错 → 进入薄弱词，今晚就定制例句")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
        }
        .task { await load() }
        .onAppear { app.audio.play(words[min(i, words.count - 1)], voice: app.S.settings.voice) }
    }

    private func load() async {
        loading = true
        let w = words[i]
        let pos = app.S.cards[w]?.pos ?? app.S.pointer
        quiz = try? await APIClient.shared.quiz(pos: pos, seed: Int(Date().timeIntervalSince1970) % 99991)
        if quiz?.options.count != 4 { quiz = nil }
        loading = false
        if quiz == nil {
            // 出题失败自动跳过（与 web 一致），避免卡在死页面
            try? await Task.sleep(nanoseconds: 500_000_000)
            advance()
        }
    }

    private func answer(ok: Bool) {
        let w = words[i]
        Task {
            await app.review(word: w, rating: ok ? 3 : 1)
            app.save()
            await MainActor.run { advance() }
        }
    }

    private func advance() {
        if i + 1 < words.count {
            i += 1
            app.audio.play(words[i], voice: app.S.settings.voice)
            Task { await load() }
        } else {
            // 验收测试真正跑完才标记 quizDay（markDayDone 不管这个字段）
            app.S.quizDay = DayUtil.today()
            app.markDayDone()
        }
    }
}

// MARK: - 完成页 + 自动个性化

struct DoneView: View {
    @Environment(AppState.self) private var app
    @State private var genStatus = "正在为你的薄弱词定制例句…"
    @State private var genRows: [PersonalizedOut.Row] = []
    @State private var marked = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        Text("今日完成 🎉").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                        HStack(spacing: 0) {
                            StatCell(number: "\(app.session.reviewedToday)", label: "复习")
                            StatCell(number: "\(app.session.learnedToday)", label: "新词")
                            StatCell(number: "\(app.S.streak)", label: "连续天数")
                        }
                        if app.dueNowCount() > 0 {
                            PrimaryButton(title: "还有 \(app.dueNowCount()) 词已到期，继续复习 →") {
                                Task {
                                    await app.buildQueue()
                                    app.route = .session
                                }
                            }
                        } else if app.dueLaterTodayCount() > 0 {
                            Text("⏰ 今天晚些时候还有 \(app.dueLaterTodayCount()) 个词到期，记得回来")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        GhostButton(title: "返回主页", color: Theme.muted) { app.route = .home }
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
                    app.route = .home
                }
                .foregroundStyle(Theme.muted)
            }
            ProgressBar(value: progress)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
