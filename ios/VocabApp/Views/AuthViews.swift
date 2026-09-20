import SwiftUI

/// 欢迎页：登录 / 注册 / 游客
struct WelcomeView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("词航").font(.system(size: 44, weight: .bold)).foregroundStyle(Theme.text)
            Text("每天 10 个词，按遗忘曲线记住它们")
                .font(.system(size: 15)).foregroundStyle(Theme.muted).padding(.top, 6)
            Spacer()
            Card {
                Text("登录后进度可跨设备同步；\n游客模式进度仅保存在本机。")
                    .font(.system(size: 15)).foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                PrimaryButton(title: "登录") { app.route = .auth(login: true) }
                GhostButton(title: "注册新账号") { app.route = .auth(login: false) }
                GhostButton(title: "先逛逛（游客模式）", color: Theme.muted) { app.enterGuest() }
            }
            Spacer().frame(height: 60)
        }
    }
}

/// 登录 / 注册表单
struct AuthView: View {
    @Environment(AppState.self) private var app
    let isLogin: Bool

    @State private var username = ""
    @State private var nickname = ""
    @State private var password = ""
    @State private var msg = ""
    @State private var busy = false

    var body: some View {
        VStack {
            Spacer()
            Card {
                Text(isLogin ? "登录" : "注册")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                TextField("用户名（字母/数字/下划线，3~20 位）", text: $username)
                    .textContentType(.username)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(12).background(Theme.cardDeep).clipShape(RoundedRectangle(cornerRadius: 8))
                if !isLogin {
                    TextField("昵称（可中文，仅展示用）", text: $nickname)
                        .padding(12).background(Theme.cardDeep).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                SecureField("密码（至少 8 位）", text: $password)
                    .textContentType(isLogin ? .password : .newPassword)
                    .padding(12).background(Theme.cardDeep).clipShape(RoundedRectangle(cornerRadius: 8))
                PrimaryButton(title: busy ? "请稍候…" : (isLogin ? "登录" : "注册并登录")) {
                    guard !busy else { return }
                    busy = true
                    msg = ""
                    Task {
                        do {
                            let r = isLogin
                                ? try await APIClient.shared.login(username: username.trimmingCharacters(in: .whitespaces), password: password)
                                : try await APIClient.shared.register(username: username.trimmingCharacters(in: .whitespaces),
                                                                      password: password,
                                                                      nickname: nickname.trimmingCharacters(in: .whitespaces))
                            await app.authed(r)
                        } catch {
                            msg = "✗ \(error.localizedDescription)"
                            busy = false
                        }
                    }
                }
                GhostButton(title: "返回", color: Theme.muted) { app.route = .welcome }
                if !msg.isEmpty {
                    Text(msg).font(.system(size: 13)).foregroundStyle(Theme.bad)
                }
            }
            Spacer()
        }
    }
}

/// 用户菜单：同步 / 切换 / 退出
struct UserMenuView: View {
    @Environment(AppState.self) private var app
    @State private var msg = ""

    var body: some View {
        VStack {
            Spacer()
            Card {
                if let a = app.auth {
                    Text(a.nickname).font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                    Text("@\(a.username) · 进度已云端同步").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    GhostButton(title: "立即同步") {
                        Task { await app.pushNow(); msg = app.syncMsg }
                    }
                    GhostButton(title: "切换账号 / 游客模式", color: Theme.muted) { app.switchAccount() }
                    PrimaryButton(title: "退出登录", color: Theme.bad) {
                        Task { await app.logout() }
                    }
                }
                GhostButton(title: "返回学习", color: Theme.muted) { app.route = .home }
                if !msg.isEmpty {
                    Text(msg).font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
        }
    }
}
