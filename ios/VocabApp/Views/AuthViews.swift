import SwiftUI
import UniformTypeIdentifiers

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
        ScrollView {
          VStack {
            Spacer()
            Card {
                Text(isLogin ? "登录" : "注册")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                TextField("用户名（字母/数字/下划线，3~20 位）", text: $username)
                    .accessibilityIdentifier("auth-username")
                    .textContentType(.username)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(12).background(Theme.cardDeep).clipShape(RoundedRectangle(cornerRadius: 8))
                if !isLogin {
                    TextField("昵称（可中文，仅展示用）", text: $nickname)
                        .padding(12).background(Theme.cardDeep).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                SecureField("密码（至少 8 位）", text: $password)
                    .accessibilityIdentifier("auth-password")
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
                            await app.authed(r, isRegistration: !isLogin)
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
          }.padding(.vertical, 20)
        }
    }
}

/// 用户菜单：同步 / 切换 / 退出
struct UserMenuView: View {
    @Environment(AppState.self) private var app
    @State private var msg = ""
    @State private var reloadPlan: ServerReloadPlan?
    @State private var showReloadConfirm = false
    @State private var reloading = false
    @State private var serverBackups: [StateBackupEntry] = []
    @State private var backupDocument: LearningBackup?
    @State private var showBackupExporter = false

    var body: some View {
        ScrollView {
          VStack {
            Spacer()
            Card {
                if let a = app.auth {
                    Text(a.nickname).font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                    Text("@\(a.username)\(app.syncFailed ? " · 同步失败" : "")").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    if app.syncFailed && msg.isEmpty {
                        Text((app.syncMsg.isEmpty || app.syncMsg == "✓ 已同步") ? "同步未完成，请重试或查看账号状态。" : app.syncMsg)
                            .font(.system(size: 13)).foregroundStyle(Theme.warn)
                    }
                    if !app.fsrsReplayError.isEmpty {
                        Text(app.fsrsReplayError).font(.system(size: 13)).foregroundStyle(Theme.warn)
                    }
                    GhostButton(title: "立即同步") {
                        Task { await app.pushNow(); msg = app.syncMsg }
                    }
                    GhostButton(title: reloading ? "正在读取服务器进度…" : "重新加载服务器进度") {
                        guard !reloading else { return }
                        reloading = true
                        Task {
                            defer { reloading = false }
                            do { reloadPlan = try await app.prepareServerReload(); showReloadConfirm = true }
                            catch { msg = "读取失败：\(error.localizedDescription)" }
                        }
                    }
                    GhostButton(title: "查看服务器恢复前备份") {
                        let owner = app.auth
                        Task {
                            do {
                                let result = try await APIClient.shared.stateBackups()
                                guard app.auth == owner else { return }
                                serverBackups = result.backups
                                if serverBackups.isEmpty { msg = "没有服务器备份" }
                            } catch { msg = "读取备份失败：\(error.localizedDescription)" }
                        }
                    }
                    ForEach(serverBackups) { backup in
                        GhostButton(title: "导出备份 \(Date(timeIntervalSince1970: backup.created_at).formatted(date: .abbreviated, time: .shortened))") {
                            let owner = app.auth
                            Task {
                                do {
                                    let response = try await APIClient.shared.stateBackup(id: backup.id)
                                    guard app.auth == owner else { return }
                                    guard let state = response.state else { throw APIError(message: "备份内容为空") }
                                    backupDocument = LearningBackup(state: state)
                                    showBackupExporter = true
                                } catch { msg = "读取备份失败：\(error.localizedDescription)" }
                            }
                        }
                    }
                    GhostButton(title: "切换账号 / 游客模式", color: Theme.muted) {
                        if !app.switchAccount() { msg = app.syncMsg }
                    }
                    Text("切换账号会先保留本机进度；退出登录会先尝试同步。")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    PrimaryButton(title: "退出登录", color: Theme.bad) {
                        let owner = app.auth
                        Task {
                            await app.logout()
                            if app.auth == owner { msg = app.syncMsg }
                        }
                    }
                }
                GhostButton(title: "返回学习", color: Theme.muted) { app.route = .home }
                if !msg.isEmpty {
                    Text(msg).font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
          }.padding(.vertical, 20)
        }
        .fileExporter(isPresented: $showBackupExporter, document: backupDocument,
                      contentType: .json, defaultFilename: "vocab-server-backup") { result in
            if case .failure(let error) = result { msg = "导出失败：\(error.localizedDescription)" }
        }
        .alert("重新加载服务器进度？", isPresented: $showReloadConfirm) {
            Button("重新加载", role: .destructive) {
                guard let plan = reloadPlan else { return }
                reloading = true
                Task {
                    defer { reloading = false; reloadPlan = nil }
                    do { try await app.applyServerReload(plan); msg = "服务器进度已加载，原本机进度已备份" }
                    catch { msg = "重新加载失败：\(error.localizedDescription)" }
                }
            }
            Button("取消", role: .cancel) { reloadPlan = nil }
        } message: {
            if let plan = reloadPlan {
                Text("服务器有 \(plan.state.cards.count) 张卡，本机有 \(plan.before.cards.count) 张。将替换本机进度，当前本机进度会先备份。" + (plan.missingSyncRecord ? "同步记录已丢失，无法找回其中可能包含的待同步修改。" : ""))
            }
        }
    }
}
