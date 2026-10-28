import SwiftUI
import UniformTypeIdentifiers

struct LearningBackup: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var state: LearningState

    init(state: LearningState) { self.state = state }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        state = try JSONDecoder().decode(LearningState.self, from: data)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(state))
    }
}

struct RawRecoveryBackup: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// 设置：每日新词 / 每日上限 / 朗读嗓音（与 web 设置项一致）
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var showReplaceConfirm = false
    @State private var showCheckpointConfirm = false
    @State private var showCancelCheckpointConfirm = false
    @State private var showCancelRestoreConfirm = false
    @State private var backup: LearningBackup?
    @State private var showingExporter = false
    @State private var rawBackup: RawRecoveryBackup?
    @State private var showingRawExporter = false
    @State private var exportError = ""
    @State private var largeRestoreExportMessage = ""
    @State private var exporting = false
    @State private var showingImporter = false
    @State private var restorePlan: RestorePlan?
    @State private var showRestoreConfirm = false
    @State private var restoreIsUnverified = false
    @State private var restoreMessage = ""
    @State private var restoring = false

    private func backupWarnings(_ state: LearningState, verified: Set<String> = []) -> [String] {
        var warnings: [String] = []
        let missing = StudyEngine.missingBackupSchedulers(state)
        let invalid = StudyEngine.invalidBackupSchedulers(state)
        if !missing.isEmpty {
            warnings.append("备份缺少部分评分所用的参数版本，或参数无法安全保存，恢复后可能无法重放。")
        }
        if !invalid.subtracting(missing).isEmpty {
            warnings.append("备份包含无法安全保存的参数版本，可能无法直接恢复。")
        }
        if !Set((state.fsrsSchedulers ?? [:]).keys).subtracting(invalid).subtracting(verified).isEmpty {
            warnings.append("部分本机参数版本未能由服务器核验，恢复前请核对。")
        }
        if StudyEngine.incompleteLegacyFsrsBackup(state) {
            warnings.append("部分旧评分未记录参数版本，无法保证恢复后可重放。")
        }
        if (state.fsrsSchedulers?.count ?? 0) > 256 {
            warnings.append("本机参数版本超过服务器允许的数量，备份可能无法直接恢复。")
        }
        return warnings
    }

    private func prepareExport(_ state: LearningState) {
        let currentAuth = app.auth
        guard currentAuth != nil else {
            backup = LearningBackup(state: state); exportError = backupWarnings(state).joined(separator: " "); showingExporter = true
            return
        }
        guard currentAuth?.accountId != nil else {
            backup = LearningBackup(state: state)
            exportError = (["旧会话仅导出本机内容；服务器参数未加入。"] + backupWarnings(state)).joined(separator: " ")
            showingExporter = true
            return
        }
        exporting = true
        exportError = ""
        Task {
            var snapshot = state
            var warnings: [String] = []
            var verified = Set<String>()
            do {
                let response: FsrsSchedulerBackups
                do {
                    response = try await APIClient.shared.schedulerBackups(expectedToken: currentAuth!.token)
                } catch let error as APIError where error.statusCode == 413 {
                    // A large account history may exceed the all-versions limit;
                    // resolve only the versions referenced by this snapshot.
                    let keys = StudyEngine.referencedBackupSchedulers(snapshot).filter {
                        $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
                    }.sorted()
                    guard keys.count <= 4096 else { throw APIError(message: "引用的参数版本过多") }
                    var resolved: [String: FsrsSchedulerConfig] = [:]
                    if !keys.isEmpty {
                        let remote = try await APIClient.shared.pullState(expectedToken: currentAuth!.token)
                        guard app.auth == currentAuth, let generation = remote.sync_generation else {
                            throw APIError(message: "无法确认服务器同步代次")
                        }
                        for offset in stride(from: 0, to: keys.count, by: 256) {
                            let batch = Array(keys[offset..<min(offset + 256, keys.count)])
                            let versions = try await APIClient.shared.resolveSchedulerBackups(keys: batch, generation: generation, expectedToken: currentAuth!.token)
                            guard app.auth == currentAuth else { throw APIError(message: "账号已切换") }
                            versions.forEach { resolved[$0.key] = $0.value }
                        }
                    }
                    response = FsrsSchedulerBackups(versions: resolved)
                }
                guard app.auth == currentAuth else { exporting = false; return }
                var versions = snapshot.fsrsSchedulers ?? [:]
                var conflict = false
                let needed = StudyEngine.missingBackupSchedulers(snapshot)
                for key in response.versions.keys.sorted(by: { a, b in
                    if needed.contains(a) != needed.contains(b) { return needed.contains(a) }
                    return a < b
                }) {
                    guard let value = response.versions[key] else { continue }
                    if let existing = versions[key] {
                        if !StudyEngine.identicalBackupScheduler(existing, value) { conflict = true } else { verified.insert(key) }
                    } else if versions.count < 256 { versions[key] = value; verified.insert(key) }
                }
                if conflict { warnings.append("本机与服务器的同一参数版本不一致，已保留本机内容。") }
                snapshot.fsrsSchedulers = versions
            } catch {
                guard app.auth == currentAuth else { exporting = false; return }
                warnings.append("未能读取服务器参数快照；已导出本机内容，备份可能不完整。")
            }
            warnings.append(contentsOf: backupWarnings(snapshot, verified: verified))
            exportError = warnings.joined(separator: " ")
            backup = LearningBackup(state: snapshot)
            showingExporter = true
            exporting = false
        }
    }

    private let voices: [(String, String)] = [
        ("en-US-AriaNeural", "Aria 女声"),
        ("en-US-GuyNeural", "Guy 男声"),
        ("en-US-JennyNeural", "Jenny 女声"),
        ("en-GB-SoniaNeural", "Sonia 英音"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                Button("返回") { app.route = .home }.foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            ScrollView {
                Card {
                    if !app.fsrsReplayError.isEmpty {
                        Text(app.fsrsReplayError).font(.system(size: 13)).foregroundStyle(Theme.warn)
                    }
                    settingSection(id: "new", title: "每日新词数",
                                   options: [5, 10, 15, 20],
                                   current: app.S.settings.newPerDay) { n in
                        if app.S.settings.newPerDay != n && app.markSettingChanged("newPerDay") { app.S.settings.newPerDay = n; app.save() }
                    }
                    settingSection(id: "cap", title: "每日总上限（复习、新词和探测的不同单词）",
                                   options: [30, 60, 100, 130],
                                   current: app.S.settings.dailyCap) { n in
                        if app.S.settings.dailyCap != n && app.markSettingChanged("dailyCap") { app.S.settings.dailyCap = n; app.save() }
                    }
                    Text("朗读嗓音").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(voices, id: \.0) { v, name in
                            let selected = (app.S.settings.voice ?? "en-US-AriaNeural") == v
                            Button {
                                if app.S.settings.voice != v && app.markSettingChanged("voice") { app.S.settings.voice = v; app.save() }
                                app.audio.play("The quick brown fox jumps over the lazy dog.", voice: v)
                            } label: {
                                Text(name)
                                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .foregroundStyle(selected ? Theme.accentLight : Theme.text)
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(selected ? Theme.accent : Theme.muted.opacity(0.4)))
                            }
                        }
                    }
                }
                .padding(.top, 12)

                Card {
                    Text("定级").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GhostButton(title: "重新定级（30 题重测词汇边界）") {
                        showReplaceConfirm = true
                    }
                    Text("随时可测。已学单词、复习进度、连续天数全部保留，只更新词汇边界和后续新词起点。")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Card {
                    Text("估值校验").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GhostButton(title: "独立水平校验（24 题，不影响学习计划）") {
                        Task { await app.startValidation() }
                    }
                    if let r = app.S.evalReport {
                        Text("上次 \(r.date)：独立 ≈\(r.mean)，当前 ≈\(r.appMean)，差值 \(r.delta > 0 ? "+" : "")\(r.delta)")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("用独立题目检验当前估值偏差，不修改后验、卡片或发词位置。")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Card {
                    Text("学习数据").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if (try? JSONEncoder().encode(app.S).count) ?? 0 > 6 * 1024 * 1024 {
                        Text("学习状态接近同步大小上限，请先同步其他设备，再整理已同步的历史。")
                            .font(.system(size: 12)).foregroundStyle(Theme.warn)
                    }
                    GhostButton(title: exporting ? "正在准备备份…" : "导出本机学习进度") {
                        prepareExport(app.S)
                    }.disabled(exporting)
                    GhostButton(title: "导出恢复前的本机备份") {
                        do { prepareExport(try app.latestLocalBackup()) }
                        catch { exportError = "读取备份失败：\(error.localizedDescription)" }
                    }.disabled(exporting)
                    if app.auth?.accountId != nil {
                        GhostButton(title: "导出待同步快照") {
                            let current = app.auth
                            exporting = true; exportError = ""
                            Task {
                                defer { exporting = false }
                                do {
                                    let data = try await app.pendingSyncSnapshot()
                                    guard app.auth == current, app.route == .settings else { return }
                                    guard let data else { exportError = "当前没有待确认的同步快照。"; return }
                                    rawBackup = RawRecoveryBackup(data: data)
                                    exportError = "待同步快照可能不包含服务器上的调度参数，请同时导出本机进度。"
                                    showingRawExporter = true
                                } catch {
                                    guard app.auth == current, app.route == .settings else { return }
                                    exportError = "读取待同步快照失败：\(error.localizedDescription)"
                                }
                            }
                        }.disabled(exporting)
                        if app.syncFailed {
                            GhostButton(title: "导出同步恢复文件") {
                                let current = app.auth
                                exporting = true; exportError = ""
                                Task {
                                    defer { exporting = false }
                                    do {
                                        let data = try await app.syncRecoveryRecord()
                                        guard app.auth == current, app.route == .settings else { return }
                                        guard let data else { exportError = "当前没有可导出的同步恢复文件。"; return }
                                        rawBackup = RawRecoveryBackup(data: data)
                                        exportError = "此文件用于排查同步问题，请同时导出本机进度。"
                                        showingRawExporter = true
                                    } catch {
                                        guard app.auth == current, app.route == .settings else { return }
                                        exportError = "读取同步恢复文件失败：\(error.localizedDescription)"
                                    }
                                }
                            }.disabled(exporting)
                        }
                        GhostButton(title: restoring ? "正在继续…" : "继续未完成的恢复或整理") {
                            let current=app.auth
                            restoring=true;largeRestoreExportMessage=""
                            Task {
                                defer { restoring=false }
                                do {
                                    try await app.resumeLargeRestore()
                                    guard app.auth == current, app.route == .settings else { return }
                                    largeRestoreExportMessage="恢复完成；恢复或整理前本机进度已保留。"
                                } catch {
                                    guard app.auth == current, app.route == .settings else { return }
                                    largeRestoreExportMessage="无法继续恢复：\(error.localizedDescription)"
                                }
                            }
                        }.disabled(restoring || exporting)
                        GhostButton(title: "取消未提交的历史整理") { showCancelCheckpointConfirm = true }
                            .disabled(restoring || exporting)
                        GhostButton(title: "取消未提交的备份恢复") { showCancelRestoreConfirm = true }
                            .disabled(restoring || exporting)
                        GhostButton(title: "导出大状态恢复记录") {
                            let current = app.auth
                            exporting = true; largeRestoreExportMessage = ""
                            Task {
                                defer { exporting = false }
                                do {
                                    let data = try await app.largeRestoreRecoveryRecord()
                                    guard app.auth == current, app.route == .settings else { return }
                                    guard let data else { largeRestoreExportMessage = "当前没有可导出的大状态恢复记录。"; return }
                                    rawBackup = RawRecoveryBackup(data: data)
                                    largeRestoreExportMessage = "此文件包含恢复前进度和待恢复备份，请妥善保管并同时导出本机进度。"
                                    showingRawExporter = true
                                } catch {
                                    guard app.auth == current, app.route == .settings else { return }
                                    largeRestoreExportMessage = "读取大状态恢复记录失败：\(error.localizedDescription)；原文件保留在设备上。"
                                }
                            }
                        }.disabled(exporting)
                        if !largeRestoreExportMessage.isEmpty {
                            Text(largeRestoreExportMessage).font(.system(size: 12)).foregroundStyle(Theme.warn)
                                .accessibilityIdentifier("large-restore-export-message")
                        }
                        GhostButton(title: restoring ? "正在处理…" : "整理已同步的历史") { showCheckpointConfirm = true }
                            .disabled(restoring)
                    }
                    if !app.unverifiedStateURLs.isEmpty {
                        Text("发现归属未确认的旧存档。请先导出核对，再决定是否恢复。")
                            .font(.system(size: 12)).foregroundStyle(Theme.warn)
                        ForEach(Array(app.unverifiedStateURLs.enumerated()), id: \.element) { index, url in
                            GhostButton(title: "导出未确认的旧存档 \(index + 1)") {
                                do {
                                    rawBackup = RawRecoveryBackup(data: try app.unverifiedState(url))
                                    showingRawExporter = true
                                } catch { exportError = "读取旧存档失败：\(error.localizedDescription)" }
                            }
                            GhostButton(title: "检查并恢复旧存档 \(index + 1)") {
                                restoring = true
                                restoreMessage = ""
                                Task {
                                    defer { restoring = false }
                                    do {
                                        let data = try app.unverifiedState(url)
                                        restorePlan = try await app.prepareRestore(data)
                                        restoreIsUnverified = true
                                        showRestoreConfirm = true
                                    } catch { restoreMessage = "读取失败：\(error.localizedDescription)" }
                                }
                            }.disabled(restoring)
                        }
                    }
                    GhostButton(title: restoring ? "正在处理备份…" : "选择备份文件恢复") {
                        restoreMessage = ""
                        showingImporter = true
                    }.disabled(restoring)
                    Text("导出文件包含学习记录，不包含密码或登录凭证，请妥善保管。游客更换设备或清除应用数据后，旧的云端例句任务无法继续取回，可重新生成。")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !exportError.isEmpty {
                        Text(exportError).font(.system(size: 12)).foregroundStyle(Theme.warn)
                    }
                    if !restoreMessage.isEmpty {
                        Text(restoreMessage).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }

                Card {
                    Text("复习提醒").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Text("每日提醒").font(.system(size: 15)).foregroundStyle(Theme.text)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { app.S.settings.notifyEnabled },
                            set: { v in
                                guard app.S.settings.notifyEnabled != v, app.markSettingChanged("notifyEnabled") else { return }
                                app.S.settings.notifyEnabled = v
                                app.save()
                                Task { await NotificationService.apply(settings: app.S.settings) }
                            }
                        ))
                        .labelsHidden()
                    }
                    if app.S.settings.notifyEnabled {
                        Text("提醒时间").font(.system(size: 13)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            ForEach([20, 21, 22], id: \.self) { h in
                                Button {
                                    if app.S.settings.notifyHour != h && app.markSettingChanged("notifyHour") { app.S.settings.notifyHour = h; app.save() }
                                    Task { await NotificationService.apply(settings: app.S.settings) }
                                } label: {
                                    Text("\(h):00")
                                        .font(.system(size: 15, weight: app.S.settings.notifyHour == h ? .semibold : .regular))
                                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                                        .foregroundStyle(app.S.settings.notifyHour == h ? Theme.accentLight : Theme.text)
                                        .overlay(RoundedRectangle(cornerRadius: 8)
                                            .stroke(app.S.settings.notifyHour == h ? Theme.accent : Theme.muted.opacity(0.4)))
                                }
                            }
                        }
                        Text("纯本地通知，不联网。如果当天已完成学习，忽略提醒即可。")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .fileExporter(isPresented: $showingExporter, document: backup,
                      contentType: .json, defaultFilename: "vocab-progress-\(DayUtil.today())") { result in
            if case .failure(let error) = result { exportError = "导出失败：\(error.localizedDescription)" }
        }
        .fileExporter(isPresented: $showingRawExporter, document: rawBackup,
                      contentType: .plainText, defaultFilename: "vocab-unverified-\(DayUtil.today())") { result in
            if case .failure(let error) = result { exportError = "导出旧存档失败：\(error.localizedDescription)" }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else {
                if case .failure(let error) = result { restoreMessage = "读取失败：\(error.localizedDescription)" }
                return
            }
            restoring = true
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() }; restoring = false }
                do {
                    let limit = (app.auth?.accountId == nil ? 8 : 14) * 1024 * 1024
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    if let size=values.fileSize, size > limit { throw APIError(message: "备份超过允许大小") }
                    let file=try FileHandle(forReadingFrom:url)
                    defer { try? file.close() }
                    var data=Data()
                    while data.count <= limit {
                        guard let part=try file.read(upToCount:min(256 * 1024,limit + 1 - data.count)), !part.isEmpty else { break }
                        data.append(part)
                    }
                    guard data.count <= limit else { throw APIError(message: "备份超过允许大小") }
                    restorePlan = try await app.prepareRestore(data)
                    restoreIsUnverified = false
                    showRestoreConfirm = true
                } catch { restoreMessage = "读取失败：\(error.localizedDescription)" }
            }
        }
        .alert("恢复学习进度？", isPresented: $showRestoreConfirm) {
            Button("恢复", role: .destructive) {
                guard let plan = restorePlan else { return }
                restoring = true
                Task {
                    defer { restoring = false; restorePlan = nil }
                    do { try await app.applyRestore(plan); restoreMessage = "恢复完成；恢复前的本机进度已备份" }
                    catch { restoreMessage = "恢复失败：\(error.localizedDescription)" }
                }
            }
            Button("取消", role: .cancel) { restorePlan = nil }
        } message: {
            if let plan = restorePlan {
                Text((restoreIsUnverified ? "旧存档归属未确认，请先核对是否属于当前账号。示例单词：\(plan.state.cards.keys.sorted().prefix(5).joined(separator: "、"))。\n" : "") + "备份包含 \(plan.state.cards.count) 张卡，本机当前有 \(plan.before.cards.count) 张。" +
                     (plan.owner == nil ? "将替换游客本机进度，当前进度会先备份。" :
                      "服务器当前有 \(plan.remoteCardCount) 张卡。将替换本机和服务器进度；当前进度会先备份，其他设备需先导出本地进度。" + (plan.largePayload == nil ? "" : " 这是实验性大状态恢复；若中断，请在此页面继续恢复。")))
            }
        }
        .alert("整理已同步的历史？", isPresented: $showCheckpointConfirm) {
            Button("整理", role: .destructive) {
                restoring = true
                Task {
                    defer { restoring = false }
                    do { try await app.checkpointHistory(); restoreMessage = "整理完成；整理前的本机和服务器进度已备份" }
                    catch { restoreMessage = "整理失败：\(error.localizedDescription)" }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("整理会将已同步的历史建立为新基线，服务器和本机会保留整理前备份。请先在其他设备同步并导出离线进度；整理后旧设备需要重新加载，未同步修改无法自动合并。")
        }
        .alert("取消未提交的历史整理？", isPresented: $showCancelCheckpointConfirm) {
            Button("确认取消", role: .destructive) {
                let current=app.auth
                restoring=true;largeRestoreExportMessage=""
                Task {
                    defer { restoring=false }
                    do {
                        try await app.cancelLargeCheckpoint()
                        guard app.auth == current, app.route == .settings else { return }
                        largeRestoreExportMessage="整理已取消；本机进度已保留，请同步。"
                    } catch {
                        guard app.auth == current, app.route == .settings else { return }
                        largeRestoreExportMessage="无法取消整理：\(error.localizedDescription)"
                    }
                }
            }
            Button("返回", role: .cancel) {}
        } message: {
            Text("服务器会确认这次整理尚未提交；若已经提交，需要继续恢复结果。")
        }
        .alert("取消未提交的备份恢复？", isPresented: $showCancelRestoreConfirm) {
            Button("确认取消", role: .destructive) {
                let current=app.auth
                restoring=true;largeRestoreExportMessage=""
                Task {
                    defer { restoring=false }
                    do {
                        try await app.cancelLargeRestore()
                        guard app.auth == current, app.route == .settings else { return }
                        largeRestoreExportMessage="恢复已取消；本机进度已保留，请同步。"
                    } catch {
                        guard app.auth == current, app.route == .settings else { return }
                        largeRestoreExportMessage="无法取消恢复：\(error.localizedDescription)"
                    }
                }
            }
            Button("返回", role: .cancel) {}
        } message: {
            Text("服务器会确认备份恢复尚未提交并清理对应暂存；若已经提交，需要继续安装结果。")
        }
        .alert("重新定级？", isPresented: $showReplaceConfirm) {
            Button("开始重测") { app.startReplacement() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("重新回答最多 30 道词义选择题（自适应难度、全新随机卷），更新词汇边界和新词起点。已学单词与进度全部保留。")
        }
    }

    private func settingSection(id: String, title: String, options: [Int], current: Int,
                                onPick: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { n in
                    Button { onPick(n) } label: {
                        Text("\(n)")
                            .font(.system(size: 15, weight: n == current ? .semibold : .regular))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .foregroundStyle(n == current ? Theme.accentLight : Theme.text)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(n == current ? Theme.accent : Theme.muted.opacity(0.4)))
                    }
                    .accessibilityIdentifier("setting-\(id)-\(n)")
                    .accessibilityValue(n == current ? "已选择" : "未选择")
                }
            }
        }
    }
}

/// 独立留出水平校验：单独后验，不影响学习计划；正反题交替，正向猜测率 0.25、反向为 0
struct ValidationView: View {
    @Environment(AppState.self) private var app
    @State private var quiz: Quiz?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            if let v = app.validation {
                if v.idx >= v.words.count, v.failed > 0 {
                    VStack(spacing: 14) {
                        Spacer()
                        Text("校验暂不可用").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                        Text("部分题目加载失败，本次结果不作为估值依据。请重试。")
                            .font(.system(size: 14)).foregroundStyle(Theme.muted)
                        Spacer()
                        PrimaryButton(title: "重新校验") { Task { await app.startValidation() } }
                        GhostButton(title: "返回设置") { app.closeValidation() }
                    }
                    .padding(.horizontal, 16)
                } else if v.idx >= v.words.count, let r = app.S.evalReport {
                    resultView(r)
                } else {
                    SessionHeader(title: "独立水平校验 \(v.idx + 1)/\(v.words.count)",
                                  progress: Double(v.idx) / Double(max(1, v.words.count)))
                    if loading {
                        Spacer()
                        ProgressView()
                        Spacer()
                    } else {
                        VStack(spacing: 0) {
                            Spacer()
                            VStack(spacing: 12) {
                                let reverse = v.idx % 2 == 1
                                if reverse, let prompt = quiz?.prompt {
                                    Text(prompt).font(.system(size: 30, weight: .bold))
                                        .foregroundStyle(Theme.text).multilineTextAlignment(.center)
                                    Text("回想它的英文单词").font(.system(size: 14)).foregroundStyle(Theme.muted)
                                } else {
                                    HStack(spacing: 10) {
                                        BigWord(word: v.words[v.idx].word)
                                        PlayButton(text: v.words[v.idx].word)
                                    }
                                    Text("选出正确词义").font(.system(size: 14)).foregroundStyle(Theme.muted)
                                }
                                Text("只用于检验估值偏差，不影响学习计划")
                                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .onAppear {
                            if v.idx % 2 == 0 { app.audio.play(v.words[v.idx].word, voice: app.S.settings.voice) }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if let q = quiz, let v = app.validation, v.idx < v.words.count {
                    QuizOptionsView(options: q.options) { ok in
                        app.answerValidation(ok: ok)
                        quiz = nil
                        loading = true
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10).background(.regularMaterial)
        }
        .task(id: app.validation?.idx) { await loadQuiz() }
    }

    private func loadQuiz() async {
        guard let v = app.validation, v.idx < v.words.count else { return }
        let w = v.words[v.idx]
        let reverse = v.idx % 2 == 1
        if let q = try? await APIClient.shared.quiz(pos: w.pos, seed: Int(Date().timeIntervalSince1970) % 99991,
                                                    mode: reverse ? "reverse" : "forward"),
           q.options.count >= 4 {
            quiz = q
            loading = false
        } else {
            app.answerValidation(ok: false, countEvidence: false)   // 出题失败仅跳过，不产生校验证据
        }
    }

    private func resultView(_ r: EvalReport) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Text("独立校验结果").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
            Text("≈\(r.mean)").font(.system(size: 44, weight: .bold)).foregroundStyle(Theme.accentLight)
            Text("独立估值（±\(r.std)） · 答对 \(r.correct)/\(r.count)")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            Text("当前学习系统估值：\(r.appMean)\n差值（当前 − 独立）：\(r.delta > 0 ? "+" : "")\(r.delta)")
                .font(.system(size: 16)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            Text(abs(r.delta) <= 500 ? "与当前估值基本一致" : (r.delta > 0 ? "当前估值可能偏高" : "当前估值可能偏低"))
                .font(.system(size: 14)).foregroundStyle(Theme.warn)
            Text("本次校验没有修改你的后验、卡片或后续发词位置。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer()
            PrimaryButton(title: "返回设置") { app.closeValidation() }
            GhostButton(title: "重新校验") { Task { await app.startValidation() } }
        }
        .padding(.horizontal, 16)
    }
}
