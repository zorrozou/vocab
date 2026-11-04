import SwiftUI
import Network

@main
struct VocabApp: App {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
    @State private var app = AppState()
    @State private var coachClock = CoachClock()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(coachClock)
                .background(WindowAppearance(preference:appearance))
                .tint(Theme.accent)
                .task { await app.boot() }
        }
    }
}

/// Apply the device preference to this scene's window. Unspecified keeps UIKit's
/// live system traits, including after returning from a manual override.
private struct WindowAppearance:UIViewRepresentable {
    let preference:AppAppearance

    final class Anchor:UIView {
        var style:UIUserInterfaceStyle = .unspecified {
            didSet { updateWindow() }
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateWindow()
        }
        private func updateWindow() {
            guard let window,window.overrideUserInterfaceStyle != style else { return }
            window.overrideUserInterfaceStyle = style
        }
    }
    func makeUIView(context:Context) -> Anchor {
        let anchor=Anchor()
        anchor.isUserInteractionEnabled=false
        anchor.accessibilityElementsHidden=true
        return anchor
    }
    func updateUIView(_ anchor:Anchor,context:Context) {
        anchor.style=preference.interfaceStyle
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch app.route {
            case .welcome:
                WelcomeView()
            case .auth(let isLogin):
                AuthView(isLogin: isLogin)
            case .home:
                HomeView()
            case .placement:
                PlacementView().id(app.placementSession).modifier(CoachTimeGate(active:true))
            case .validation:
                ValidationView().modifier(CoachTimeGate(active:true))
            case .coach:
                CoachLessonView().id(app.auth?.accountId ?? "guest")
            case .session:
                SessionView()
            case .stats:
                StatsView()
            case .settings:
                SettingsView(initial: app.initialSettingsSection)
            case .userMenu:
                UserMenuView()
            }
        }
        .task { await observeConnectivity() }
        .onChange(of: app.S.settings, initial: true) { _, settings in
            NotificationService.apply(settings: settings)
        }
        // 回到前台：服务器有更新的存档就拉过来（多端同步补漏）+ 重排每日提醒
        .onChange(of: scenePhase, initial:true) { _, phase in
            app.updateScene(active:phase == .active)
            if phase == .active { NotificationService.apply(settings: app.S.settings) }
        }
    }

    private func observeConnectivity() async {
        let monitor = NWPathMonitor()
        let changes = AsyncStream<Bool> { continuation in
            monitor.pathUpdateHandler = { path in continuation.yield(path.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "vocab.network-recovery"))
        }
        for await online in changes { await app.updateNetwork(available:online) }
    }
}
