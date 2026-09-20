import SwiftUI

/// 学习统计：记忆保持率分布 + 未来 14 天负载 + 顽固词（移植自 web showStats）
struct StatsView: View {
    @Environment(AppState.self) private var app

    private var mastered: Int { app.S.cards.values.filter { StudyEngine.isMastered($0) }.count }

    /// 保持率分桶（R = (1+0.9805·t/S)^-0.1542，t=距上次复习天数）
    private var retentionBuckets: [(String, Int)] {
        var buckets = [("≥95%", 0), ("90~95%", 0), ("80~90%", 0), ("60~80%", 0), ("<60%", 0)]
        let today = DayUtil.today()
        for (w, c) in app.S.cards {
            guard let f = c.fsrs, f.stability > 0,
                  let last = app.S.log.reversed().first(where: { $0.word == w }),
                  let lastD = DayUtil.parseISO(last.d + "T12:00:00Z"),
                  let todayD = DayUtil.parseISO(today + "T12:00:00Z") else { continue }
            let t = max(0, todayD.timeIntervalSince(lastD) / 86400)
            let r = StudyEngine.retrievability(c, elapsedDays: t)
            if r >= 0.95 { buckets[0].1 += 1 }
            else if r >= 0.9 { buckets[1].1 += 1 }
            else if r >= 0.8 { buckets[2].1 += 1 }
            else if r >= 0.6 { buckets[3].1 += 1 }
            else { buckets[4].1 += 1 }
        }
        return buckets
    }

    /// 未来 14 天负载（今天含过期累积）
    private var loads14: [(String, Int)] {
        let day0 = DayUtil.today()
        var loads = (0..<14).map { i -> (String, Int) in
            let d = DayUtil.addDays(day0, i)
            let n = app.S.cards.values.filter {
                !StudyEngine.isMastered($0) && ($0.due?.prefix(10) ?? "") == d
            }.count
            return (d, n)
        }
        let overdue = app.S.cards.values.filter {
            !StudyEngine.isMastered($0) && String($0.due?.prefix(10) ?? "") < day0 && !($0.due ?? "").isEmpty
        }.count
        loads[0].1 += overdue
        return loads
    }

    private var stubborn: [(String, Int)] {
        var count: [String: Int] = [:]
        for l in app.S.log where l.rating <= 2 { count[l.word, default: 0] += 1 }
        return count.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) }
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
                    let buckets = retentionBuckets
                    let total = max(1, buckets.map(\.1).reduce(0, +))
                    ForEach(Array(buckets.enumerated()), id: \.offset) { _, b in
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
                    }
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
                        }
                    }
                    .frame(height: 84)
                    if !stubborn.isEmpty {
                        Text("顽固词（≥2 次没记住）").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
                        Text(stubborn.map { "\($0.0) ×\($0.1)" }.joined(separator: " · "))
                            .font(.system(size: 14)).foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 12)
            }
        }
    }
}
