import SwiftUI

/// 学习统计：记忆保持率分布 + 未来 14 天负载 + 顽固词（移植自 web showStats）
struct StatsView: View {
    @Environment(AppState.self) private var app
    @State private var preparingDrill = false
    @State private var drillError = ""

    private var mastered: Int { app.S.cards.values.filter { StudyEngine.isMastered($0) }.count }

    /// 未来 14 天负载（今天含过期累积）
    private var loads14: [(String, Int)] {
        StudyEngine.forecastDueDates(app.S.cards, day: DayUtil.today(), configurations: app.S.fsrsSchedulers ?? [:])
    }

    private var stubborn: [(String, Int)] {
        StudyEngine.stubbornWords(app.S)
    }
    private var drillWords: [String] {
        StudyEngine.stubbornDrillWords(app.S, day: DayUtil.today(), now: Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("学习统计").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                Button("返回") { app.route = .home }.foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            ScrollView {
                Card {
                    HStack(spacing: 0) {
                        StatCell(number: "\(app.S.cards.count)", label: "已学")
                        StatCell(number: "\(mastered)", label: "已掌握")
                        StatCell(number: "\(app.S.streak)", label: "连续天数")
                    }
                    Text("记忆保持率分布（FSRS）").font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
                    let retention = StudyEngine.retentionSummary(app.S.cards, log: app.S.log, now: Date(), configurations: app.S.fsrsSchedulers ?? [:])
                    let buckets = Array(zip(["≥95%", "90~95%", "80~90%", "60~80%", "<60%"], retention.counts))
                    let total = max(1, buckets.map(\.1).reduce(0, +))
                    ForEach(Array(buckets.enumerated()), id: \.offset) { index, b in
                        HStack(spacing: 8) {
                            Text(b.0).font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 52, alignment: .leading)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4).fill(Theme.cardDeep).frame(height: 10)
                                    RoundedRectangle(cornerRadius: 4).fill(Theme.accent)
                                        .frame(width: g.size.width * CGFloat(b.1) / CGFloat(total), height: 10)
                                }
                            }
                            .frame(height: 10)
                            Text("\(b.1)").font(.system(size: 11)).foregroundStyle(Theme.text).frame(width: 30, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(b.0)：\(b.1)词")
                        .accessibilityIdentifier("retention-bin-\(index)")
                    }
                    Text("按对应参数曲线估算；\(retention.approximate) 词使用日期或参数近似，\(retention.unknown) 词缺少可用信息或评分待同步，未计入分布。")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .accessibilityIdentifier("retention-summary")
                    Text("未来 14 天负载预测").font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
                    let loads = loads14
                    let maxL = max(1, loads.map(\.1).max() ?? 1)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(Array(loads.enumerated()), id: \.offset) { _, l in
                            VStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Theme.accent)
                                    .frame(height: max(3, 60 * CGFloat(l.1) / CGFloat(maxL)))
                                Text(String(l.0.suffix(5))).font(.system(size: 8)).foregroundStyle(Theme.muted)
                            }
                            .frame(maxWidth: .infinity)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(l.0)，\(l.1)词")
                            .accessibilityIdentifier("forecast-\(l.0)")
                        }
                    }
                    .frame(height: 84)
                    if !stubborn.isEmpty {
                        Text("需要巩固（最近 14 天至少 2 次困难／忘记）").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
                        Text(stubborn.map { row in
                            let counts = StudyEngine.recentDifficult(app.S, day: DayUtil.today())[row.0]
                            return "\(row.0)：忘记 \(counts?.again ?? 0) · 困难 \(counts?.hard ?? 0)"
                        }.joined(separator: " · "))
                            .font(.system(size: 14)).foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("新评分按独立学习证据统计；旧记录仅统计仍可追溯的部分。")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        // 顽固词特训：单独组队歼灭（纯复习队列，不进新词）
                        PrimaryButton(title: "最近 14 天薄弱词特训（\(drillWords.count) 词）", color: Theme.warn) {
                            guard !preparingDrill else { return }
                            preparingDrill = true; drillError = ""
                            let owner = app.auth, generation = app.routeGeneration
                            Task {
                                let count = await app.startStubbornDrill()
                                guard app.auth == owner, app.routeGeneration == generation else { return }
                                preparingDrill = false
                                if count == 0 { drillError = app.studyNotice }
                            }
                        }
                        .disabled(drillWords.isEmpty || preparingDrill)
                        .padding(.top, 4)
                        if !drillError.isEmpty { Text(drillError).font(.system(size: 12)).foregroundStyle(Theme.bad) }
                        if drillWords.count < stubborn.count {
                            Text("已为今日新词预留名额；超过上限的词暂不安排。")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
    }
}
