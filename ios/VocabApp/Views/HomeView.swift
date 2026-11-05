import SwiftUI

/// 主页：状态条 + 今日任务入口（未定级则引导定级）
struct HomeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("coach.classic.interface.v1") private var classic=false
    @SceneStorage("vocab.home.section") private var section = 0
    @State private var starting = false
    @State private var startError = ""

    private var learnedCount: Int { app.S.cards.count }
    private var masteredCount: Int { app.S.cards.values.filter { StudyEngine.isMastered($0) }.count }
    private var dailyPlan: StudyEngine.DailyPlanSummary {
        StudyEngine.dailyPlanSummary(app.S, day: DayUtil.today(), now: Date())
    }
    private var vocabularyAction: String {
        if starting {return "准备中…"}
        if !startError.isEmpty {return "重新加载"}
        if classic {return dailyPlan.completed > 0 ? "继续今天" : "开始今天"}
        return dailyPlan.completed > 0 ? "继续词汇练习" : "开始词汇练习"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let _ = context.date
            content
        }
    }
    private var content: some View {
        VStack(spacing: 0) {
            TopBar()
            if classic || section == 1 {
                ScreenPages {
                    chips
                    if !app.studyNotice.isEmpty {
                        ReadingText(text: app.studyNotice, font: .subheadline).foregroundStyle(Theme.warn)
                            .accessibilityIdentifier("study-plan-notice")
                    }
                    if !app.S.calibrated { placementIntro } else { todayCard }
                    if classic {
                        Button("开启听读教练") {
                            section = 0; classic = false
                        }
                        .frame(minHeight: 44).accessibilityIdentifier("coach-enable")
                    }
                }.padding(.horizontal, 14)
            } else {
                CoachHomeCard(tab: section == 0 ? 0 : section - 1)
            }
        }
        .task { await app.refreshPersonalJobs() }
        // 主行动按钮钉死底部拇指区
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                if classic || section == 1 {
                    if !app.S.calibrated {
                        PrimaryButton(title: app.S.probeCount > 0 ? "继续定级" : "开始定级") {
                            app.route = .placement
                        }
                    } else {
                        VStack(spacing: 6) {
                            PrimaryButton(title: vocabularyAction) {
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
                                        startError = app.studyNotice.isEmpty ? "任务加载失败，请检查网络后重试" : app.studyNotice
                                    }
                                }
                            }.accessibilityIdentifier("start-today")
                            if !startError.isEmpty {
                                Text(startError).font(.caption).foregroundStyle(Theme.bad)
                            }
                        }
                    }
                }
                if !classic {
                    HStack(spacing: 4) {
                        ForEach(Array(["课堂", "词汇", "档案", "目标"].enumerated()), id: \.offset) { index, label in
                            Button {
                                section = index
                            } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: ["headphones", "character.book.closed", "chart.bar", "scope"][index])
                                    Text(label).font(.caption)
                                }.foregroundStyle(section == index ? Theme.accent : Theme.muted)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(section == index ? Theme.cardDeep : .clear, in: RoundedRectangle(cornerRadius: 10))
                            }.accessibilityIdentifier("home-section-\(index)")
                                .accessibilityAddTraits(section == index ? .isSelected : [])
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
            Chip(label: "学习位置", value: app.S.calibrated ? "\(app.S.pointer)" : "未定级")
            Chip(label: "已学", value: "\(learnedCount)")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("learned-count")
            Chip(label: "已掌握", value: "\(masteredCount)")
            Chip(label: "连续", value: "\(app.S.streak)天")
        }
        .padding(.horizontal, 14)
    }

    private var placementIntro: some View {
        Group {
            Text(app.S.placementVersion == nil ? "首次使用 · 智能定级" : "重新定级").font(.title2.weight(.bold)).foregroundStyle(Theme.text)
            Text("共 30 道词义选择题，约需几分钟。覆盖六个词频区间，结果给出粗略识别范围和新词起点。可以中途退出，之后继续。")
                .font(.subheadline).foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            if app.S.probeCount > 0 {
                Text("已完成 \(app.S.probeCount)/30")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }

        }
    }

    private var todayCard: some View {
        let plan = dailyPlan
        return Group {
            Text("今日任务").font(.title2.weight(.bold)).foregroundStyle(Theme.text)
            // 今日进度：已完成 / 目标（复习+新词），一眼看到还差多少
            VStack(spacing: 4) {
                HStack {
                    Text("今日进度（预计）").font(.caption).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("\(plan.completed) / \(plan.totalPlanned)").font(.caption.weight(.semibold)).foregroundStyle(Theme.accentLight)
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
                    StatCell(number: StudyEngine.recognitionEstimate(app.S).rangeText, label: "词义识别范围")
                } else {
                    StatCell(number: "未定级", label: "预计认识")
                }
            }
            if plan.dueAvailable > plan.duePlanned {
                Text("另有 \(plan.dueAvailable - plan.duePlanned) 个词已到期，超出今日上限，暂未安排。")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            if plan.repeatPlanned > 0 {
                Text("其中 \(plan.repeatPlanned) 个是今天学过的词，按间隔再复习，不增加今日单词数。")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            Text("先保留新词名额；另含最多 \(plan.probePlanned) 个校准词，总量仍遵守每日上限。").font(.caption).foregroundStyle(Theme.muted)
        }
    }
}

struct TopBar: View {
    @Environment(AppState.self) private var app

    @State private var showNotices = false
    private struct Notice {
        let id: String
        let title: String
        let action: () -> Void
    }
    private var notices: [Notice] {
        var items: [Notice] = []
        let account = { app.route = app.isGuest ? .welcome : .userMenu }
        if app.localSaveFailed {
            items.append(Notice(id: "disk-status", title: "本机保存失败，打开设置导出进度") { app.openSettings(.backup) })
        }
        if app.syncFailed {
            items.append(Notice(id: "sync-status", title: "同步未完成，请查看详情", action: account))
        }
        if app.credentialSaveFailed {
            items.append(Notice(id: "credential-status", title: "⚠️ 登录凭证未保存，重启后需重新登录", action: account))
        }
        if !app.fsrsReplayError.isEmpty {
            items.append(Notice(id: "fsrs-status", title: "评分参数冲突，打开设置查看") { app.openSettings(.offline) })
        }
        if app.S.cards.values.contains(where: { $0.pendingFsrs != nil }) {
            items.append(Notice(id: "pending-sync-status", title: "评分待同步，打开账号查看", action: account))
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("词航").font(.title3.weight(.bold)).foregroundStyle(Theme.text)
                Text(app.auth.map { "· \($0.nickname)" } ?? "· 游客（进度仅本机）")
                    .font(.caption).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Button { app.route = .stats } label: {
                    Image(systemName: "chart.bar").foregroundStyle(Theme.accentLight).frame(width: 44, height: 44).background(Theme.card,in:RoundedRectangle(cornerRadius:12))
                }.accessibilityLabel("统计").accessibilityIdentifier("stats-menu")
                Button { app.openSettings(.daily) } label: {
                    Image(systemName: "gearshape").foregroundStyle(Theme.accentLight).frame(width: 44, height: 44).background(Theme.card,in:RoundedRectangle(cornerRadius:12))
                }.accessibilityLabel("设置").accessibilityIdentifier("settings-menu")
                Button { app.route = app.isGuest ? .welcome : .userMenu } label: {
                    Image(systemName: "person.circle").foregroundStyle(Theme.accentLight).frame(width: 44, height: 44).background(Theme.card,in:RoundedRectangle(cornerRadius:12))
                }.accessibilityLabel("账号").accessibilityIdentifier("account-menu")
            }
            if let item = notices.first {
                HStack {
                    Button(item.title, action: item.action)
                        .font(.footnote.weight(.medium)).foregroundStyle(Theme.warn)
                        .frame(minHeight: 44).accessibilityIdentifier(item.id)
                    if notices.count > 1 {
                        Button {
                            showNotices = true
                        } label: {
                            Text("更多（\(notices.count)）")
                                .font(.footnote).foregroundStyle(Theme.warn).frame(minHeight: 44)
                        }.sheet(isPresented: $showNotices) {
                            VStack {
                                HStack {
                                    Text("进度提醒").font(.headline); Spacer(); NavigationAction(title: "关闭") { showNotices = false }
                                }
                                ScreenPages {
                                    ForEach(notices, id: \.id) { item in
                                        GhostButton(title: item.title) {
                                            showNotices = false; item.action()
                                        }.accessibilityIdentifier(item.id)
                                    }
                                }
                            }.padding().background(Theme.bg)
                        }
                    }
                }
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
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(Theme.text)
            Text(label).font(.caption2).foregroundStyle(Theme.muted)
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
                .font(.title.weight(.bold))
                .foregroundStyle(Theme.accentLight)
                .lineLimit(1)
                .minimumScaleFactor(0.55)   // "≈4150 · 四级" 这类长文自动缩到放得下
            Text(label).font(.caption).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}
