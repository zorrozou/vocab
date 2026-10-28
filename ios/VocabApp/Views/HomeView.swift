import SwiftUI

/// 主页：状态条 + 今日任务入口（未定级则引导定级）
struct HomeView: View {
    @Environment(AppState.self) private var app
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
                        PrimaryButton(title: starting ? "准备中…" : (startError.isEmpty ? "开始今天" : "重新加载")) {
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
                        }
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
        HStack(spacing: 8) {
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
            Text("共 30 道词义选择（4 选 1），难度随作答实时调整，\n系统根据你的真实答题成绩估计词汇量，\n答完后把新词起点放到适合你的位置。")
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
                    Text("今日进度").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("\(plan.completed) / \(plan.totalPlanned)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accentLight)
                }
                ProgressBar(value: plan.totalPlanned > 0 ? Double(plan.completed) / Double(plan.totalPlanned) : 0)
            }
            HStack(spacing: 0) {
                StatCell(number: "\(plan.dueAvailable)", label: "待复习")
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
            Text("优先复习到期单词；实际队列可能包含探测或提前复习。").font(.system(size: 12)).foregroundStyle(Theme.muted)
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
                    Image(systemName: "chart.bar").foregroundStyle(Theme.accentLight)
                }.accessibilityLabel("统计").accessibilityIdentifier("stats-menu")
                Button { app.route = .settings } label: {
                    Image(systemName: "gearshape").foregroundStyle(Theme.accentLight).padding(.leading, 8)
                }.accessibilityLabel("设置").accessibilityIdentifier("settings-menu")
                Button { app.route = app.isGuest ? .welcome : .userMenu } label: {
                    Image(systemName: "person.circle").foregroundStyle(Theme.accentLight).padding(.leading, 8)
                }.accessibilityLabel("账号").accessibilityIdentifier("account-menu")
            }
            if app.syncFailed {
                Text("⚠️ 同步失败").font(.system(size: 11)).foregroundStyle(Theme.warn)
            }
            if app.credentialSaveFailed {
                Text("⚠️ 登录凭证未保存，重启后需重新登录").font(.system(size: 11)).foregroundStyle(Theme.warn)
            }
            if app.localSaveFailed {
                Text("⚠️ 本机保存失败，请导出进度").font(.system(size: 11)).foregroundStyle(Theme.warn)
            }
            if !app.fsrsReplayError.isEmpty {
                Text("⚠️ 评分参数冲突").font(.system(size: 11)).foregroundStyle(Theme.warn)
            }
            if app.S.cards.values.contains(where: { $0.pendingFsrs != nil }) {
                Text("评分待同步").font(.system(size: 11)).foregroundStyle(Theme.warn)
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
