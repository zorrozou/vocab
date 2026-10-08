import SwiftUI

@main
struct VocabApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .task { await app.boot() }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color(.sRGB, red: 0.043, green: 0.055, blue: 0.075, opacity: 1).ignoresSafeArea()
            switch app.route {
            case .welcome:
                WelcomeView()
            case .auth(let isLogin):
                AuthView(isLogin: isLogin)
            case .home:
                HomeView()
            case .placement:
                PlacementView()
            case .session:
                SessionView()
            case .stats:
                StatsView()
            case .settings:
                SettingsView()
            case .userMenu:
                UserMenuView()
            }
        }
        // 回到前台：服务器有更新的存档就拉过来（多端同步补漏）
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await app.pullIfNewer() }
            }
        }
    }
}
