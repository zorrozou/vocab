import SwiftUI

/// 主页：状态条 + 今日任务入口（未定级则引导定级）
struct HomeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var starting = false
    @State private var startError = ""

    private var learnedCount: Int { app.S.cards.count }
    private var masteredCount: Int { app.S.cards.values.filter { StudyEngine.isMastered($0) }.count }
    private var dailyPlan: StudyEngine.DailyPlanSummary {
        StudyEngine.dailyPlanSummary(app.S, day: DayUtil.today(), now: Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            ScrollView {
                VStack(spacing: 14) {
                    chips
                    if !app.studyNotice.isEmpty {
                        Text(app.studyNotice).font(.system(size: 14)).foregroundStyle(Theme.warn)
                            .accessibilityIdentifier("study-plan-notice")
                    }
                    if !app.S.calibrated {
                        placementIntro
                    } else {
                        todayCard
                    }
                }
                .padding(.top, 12)
            }
        }
        .task { await app.refreshPersonalJobs() }
        // 主行动按钮钉死底部拇指区
        .safeAreaInset(edge: .bottom) {
            Group {
                if !app.S.calibrated {
                    PrimaryButton(title: app.S.probeCount > 0 ? "继续定级" : "开始定级") {
                        app.route = .placement
                    }
                } else {
                    VStack(spacing: 6) {
                        PrimaryButton(title: starting ? "准备中…" : (startError.isEmpty ? (dailyPlan.completed > 0 ? "继续今天" : "开始今天") : "重新加载")) {
                            guard !starting else { return }
                            starting = true
                            startError = ""
                            let generation = app.routeGeneration, owner = app.auth
                            Task {
                                let ready = await app.buildQueue()
                                guard app.routeGeneration == generation, app.auth == owner else { return }
                                starting = false
                                if ready {
                                    if app.session.queue.isEmpty { app.markDayDone() }
                                    app.route = .session
                                } else {
                                    startError = "任务加载失败，请检查网络后重试"
                                }
                            }
                        }.accessibilityIdentifier("start-today")
                        if !startError.isEmpty {
                            Text(startError).font(.system(size: 12)).foregroundStyle(Theme.bad)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
    }

    private var chips: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: dynamicTypeSize.isAccessibilitySize ? 2 : 4), spacing: 8) {
            Chip(label: "词汇边界", value: app.S.calibrated ? "≈\(app.S.frontier)" : "未定级")
            Chip(label: "已学", value: "\(learnedCount)")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("learned-count")
            Chip(label: "已掌握", value: "\(masteredCount)")
            Chip(label: "连续", value: "\(app.S.streak)天")
        }
        .padding(.horizontal, 14)
    }

    private var placementIntro: some View {
        Card {
            Text(app.S.placementVersion == nil ? "首次使用 · 智能定级" : "重新定级").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
            Text("共 30 道词义选择题，约需几分钟。难度会随作答调整，结果用于估计适合你的新词起点。可以中途退出，之后继续。")
                .font(.system(size: 15)).foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            if app.S.probeCount > 0 {
                Text("已完成 \(app.S.probeCount)/30\(app.S.probeCount >= 4 ? " · 当前估计 ≈\(Int(StudyEngine.postMean(app.S)))" : "")")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Text("开始按钮在屏幕底部 👇").font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }

    private var todayCard: some View {
        let plan = dailyPlan
        return Card {
            Text("今日任务").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
            // 今日进度：已完成 / 目标（复习+新词），一眼看到还差多少
            VStack(spacing: 4) {
                HStack {
                    Text("今日进度（预计）").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("\(plan.completed) / \(plan.totalPlanned)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accentLight)
                }
                ProgressBar(value: plan.totalPlanned > 0 ? Double(plan.completed) / Double(plan.totalPlanned) : 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("预计今日进度，已完成 \(plan.completed)，共 \(plan.totalPlanned) 词")
            HStack(spacing: 0) {
                StatCell(number: "\(plan.duePlanned)", label: "今日待复习")
                StatCell(number: "\(plan.newPlanned)", label: "新词上限")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("daily-new-planned")
                // v1.3：已校准就显示后验估值 + 滞回级别（不再显示发词游标）
                if app.S.calibrated, app.S.posterior != nil {
                    let shown = app.S.track?.shownLevel ?? levelForPos(max(1, app.S.frontier))
                    StatCell(number: "≈\(StudyEngine.expectedKnown(app.S)) · \(levelDisplayName(shown))", label: "预计认识")
                } else {
                    StatCell(number: "未定级", label: "预计认识")
                }
            }
            if plan.dueAvailable > plan.duePlanned {
                Text("另有 \(plan.dueAvailable - plan.duePlanned) 个词已到期，超出今日上限，暂未安排。")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            if plan.repeatPlanned > 0 {
                Text("其中 \(plan.repeatPlanned) 个是今天学过的词，按间隔再复习，不增加今日单词数。")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Text("先预留每日新词名额，再安排到期复习；实际队列可能包含探测或提前复习。").font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }
}

struct TopBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("词航").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                Text(app.auth.map { "· \($0.nickname)" } ?? "· 游客（进度仅本机）")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Button { app.route = .stats } label: {
                    Image(systemName: "chart.bar").foregroundStyle(Theme.accentLight).frame(width: 44, height: 44)
                }.accessibilityLabel("统计").accessibilityIdentifier("stats-menu")
                Button { app.route = .settings } label: {
                    Image(systemName: "gearshape").foregroundStyle(Theme.accentLight).frame(width: 44, height: 44)
                }.accessibilityLabel("设置").accessibilityIdentifier("settings-menu")
                Button { app.route = app.isGuest ? .welcome : .userMenu } label: {
                    Image(systemName: "person.circle").foregroundStyle(Theme.accentLight).frame(width: 44, height: 44)
                }.accessibilityLabel("账号").accessibilityIdentifier("account-menu")
            }
            if app.syncFailed {
                Button { app.route = app.isGuest ? .welcome : .userMenu } label: {
                    HStack {
                        Text("同步未完成，请查看详情")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.warn)
                    .frame(minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("sync-status")
            }
            if app.credentialSaveFailed {
                Text("⚠️ 登录凭证未保存，重启后需重新登录").font(.system(size: 11)).foregroundStyle(Theme.warn)
            }
            if app.localSaveFailed {
                Button("本机保存失败，打开设置导出进度") { app.route = .settings }
                    .font(.system(size: 13)).foregroundStyle(Theme.warn).frame(minHeight: 44)
            }
            if !app.fsrsReplayError.isEmpty {
                Button("评分参数冲突，打开设置查看") { app.route = .settings }
                    .font(.system(size: 13)).foregroundStyle(Theme.warn).frame(minHeight: 44)
            }
            if app.S.cards.values.contains(where: { $0.pendingFsrs != nil }) {
                Button("评分待同步，打开账号查看") { app.route = app.isGuest ? .welcome : .userMenu }
                    .font(.system(size: 13)).foregroundStyle(Theme.warn).frame(minHeight: 44)
                    .accessibilityIdentifier("pending-sync-status")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct Chip: View {
    let label: String
    let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct StatCell: View {
    let number: String
    let label: String
    var body: some View {
        VStack(spacing: 3) {
            Text(number)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.accentLight)
                .lineLimit(1)
                .minimumScaleFactor(0.55)   // "≈4150 · 四级" 这类长文自动缩到放得下
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}
