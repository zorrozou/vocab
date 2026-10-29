import SwiftUI
import Network

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
                PlacementView().id(app.placementSession)
            case .validation:
                ValidationView()
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
        .task { await observeConnectivity() }
        .onChange(of: app.S.settings, initial: true) { _, settings in
            NotificationService.apply(settings: settings)
        }
        // 回到前台：服务器有更新的存档就拉过来（多端同步补漏）+ 重排每日提醒
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await app.pullIfNewer()
                    NotificationService.apply(settings: app.S.settings)
                }
            }
        }
    }

    private func observeConnectivity() async {
        let monitor = NWPathMonitor()
        let changes = AsyncStream<Bool> { continuation in
            monitor.pathUpdateHandler = { path in continuation.yield(path.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "vocab.network-recovery"))
        }
        var previous: Bool?
        for await online in changes {
            if online && previous == false { await app.networkReconnected() }
            previous = online
        }
    }
}
