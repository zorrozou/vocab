import SwiftUI

/// 主页：状态条 + 今日任务入口（未定级则引导定级）
struct HomeView: View {
    @Environment(AppState.self) private var app
    @State private var starting = false

    private var learnedCount: Int { app.S.cards.count }
    private var masteredCount: Int { app.S.cards.values.filter { StudyEngine.isMastered($0) }.count }
    private var dueCount: Int { app.dueNowCount() }

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
        // 主行动按钮钉死底部拇指区
        .safeAreaInset(edge: .bottom) {
            Group {
                if !app.S.calibrated {
                    PrimaryButton(title: app.S.probeCount > 0 ? "继续定级" : "开始定级") {
                        app.route = .placement
                    }
                } else {
                    PrimaryButton(title: starting ? "准备中…" : "开始今天") {
                        guard !starting else { return }
                        starting = true
                        Task {
                            await app.buildQueue()
                            starting = false
                            if app.session.queue.isEmpty {
                                app.markDayDone()
                            }
                            app.route = .session
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
            Chip(label: "已掌握", value: "\(masteredCount)")
            Chip(label: "连续", value: "\(app.S.streak)天")
        }
        .padding(.horizontal, 14)
    }

    private var placementIntro: some View {
        Card {
            Text("首次使用 · 智能定级").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
            Text("30 道词义选择（4 选 1），\n系统根据你的真实答题成绩估计词汇量，\n把新词起点放到适合你的位置。")
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
        Card {
            Text("今日任务").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
            HStack(spacing: 0) {
                StatCell(number: "\(dueCount)", label: "待复习")
                StatCell(number: "\(app.S.settings.newPerDay)", label: "新词")
                StatCell(number: "≈\(app.S.pointer) · \(levelDisplayName(levelForPos(app.S.pointer)))", label: "当前词汇量")
            }
            Text("先复习到期单词，再学新词").font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }
}

struct TopBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack {
            Text("词航").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
            Text(app.auth.map { "· \($0.nickname)" } ?? "· 游客（进度仅本机）")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer()
            Button { app.route = .stats } label: {
                Image(systemName: "chart.bar").foregroundStyle(Theme.accentLight)
            }
            Button { app.route = .settings } label: {
                Image(systemName: "gearshape").foregroundStyle(Theme.accentLight).padding(.leading, 8)
            }
            Button { app.route = app.isGuest ? .welcome : .userMenu } label: {
                Image(systemName: "person.circle").foregroundStyle(Theme.accentLight).padding(.leading, 8)
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
