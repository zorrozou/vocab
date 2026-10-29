import OSLog
import Darwin
import SwiftUI

/// 会话内瞬态（不持久化）：今日队列与进度
struct Session {
    let id = UUID()
    enum Item: Equatable {
        case review(word: String)
        case learn(word: NewWord)
        case probe(word: NewWord, reverse: Bool)   // v1.4 水平探测题；reverse=true 检验回想而非再认
    }
    var queue: [Item] = []
    var idx = 0
    var learnedToday = 0
    var reviewedToday = 0
    /// 当日验收测试进度（学完新词后的 4 选 1）
    var acceptanceIdx: Int?
}

struct ValidationSession {
    var words: [PlacementItem]
    var idx = 0
    var posterior: [Double]?
    var correct = 0
    var failed = 0
}

struct RestorePlan {
    let state: LearningState
    let before: LearningState
    let slot: String
    let owner: Int?
    let token: String?
    let expectedUpdatedAt: Double?
    let expectedRevision: String?
    let expectedGeneration: String?
    let remoteCardCount: Int
    let largePayload: Data?
}

struct ServerReloadPlan {
    let state: LearningState
    let before: LearningState
    let slot: String
    let owner: Int
    let token: String
    let updatedAt: Double?
    let revision: String?
    let generation: String?
    let missingSyncRecord: Bool
}

struct Auth: Equatable {
    let userId: Int
    let accountId: String?
    let username: String
    let nickname: String
    let token: String
}

enum Route: Equatable {
    case welcome
    case auth(login: Bool)
    case home
    case placement
    case validation
    case session
    case stats
    case settings
    case userMenu
}

@MainActor
@Observable
final class AppState {
    var S = LearningState()
    var auth: Auth?
    var route: Route = .welcome {
        didSet { if oldValue != route { routeGeneration &+= 1 } }
    }
    private(set) var routeGeneration: UInt64 = 0
    var session = Session()
    var validation: ValidationSession?
    var placementSet: PlacementSet?
    var placementSession = UUID()   // 每次重新定级更换，强制清空已考集合与 CAT 位置
    var booted = false
    var syncMsg = ""
    var credentialSaveFailed = false
    var fsrsReplayError = ""

    let audio = AudioService()
    let speech = SpeechService()
    private let api = APIClient.shared
    private let delta = DeltaSyncCoordinator(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("VocabDelta", isDirectory: true))
    private var pushTask: Task<Void, Never>?
    var syncFailed = false   // 上次推送服务器失败（顶栏显示 ⚠️）
    var localSaveFailed = false

    var isGuest: Bool { auth == nil }

    private func versionDevice() -> String {
        let defaults = UserDefaults.standard
        let key = "vocab_settings_device"
        let saved = defaults.string(forKey: key)
        let device = saved.flatMap { UUID(uuidString: $0) != nil ? $0.lowercased() : nil } ?? UUID().uuidString.lowercased()
        defaults.set(device, forKey: key)
        return device
    }

    @discardableResult
    func markSettingChanged(_ key: String) -> Bool {
        let old = S.settingsVersions?[key]?.counter ?? 0
        guard old >= 0, old < 9_007_199_254_740_991 else {
            syncMsg = "设置版本无效，请先导出进度并重新加载"
            return false
        }
        let device = versionDevice()
        if S.settingsVersions == nil { S.settingsVersions = [:] }
        S.settingsVersions?[key] = SettingVersion(counter: old + 1, device: device)
        return true
    }

    // MARK: 本地持久化（Documents 目录，按账号分槽位）

    private var slotKey: String {
        auth.map { LocalAccountSlot.name(userId: $0.userId, username: $0.username, accountId: $0.accountId) } ?? "guest"
    }

    private var lastSyncKey: String { "vocab_sync_\(slotKey)" }

    private var recoveryDirectory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    func pendingSyncSnapshot() async throws -> Data? {
        guard let current = auth, let account = current.accountId else { return nil }
        let pending = try await delta.pendingTarget(account: account)
        let data = pending == nil ? try await delta.pendingPullPrevious(account: account) : pending
        guard auth == current else { throw APIError(message: "账号已切换，请重新导出") }
        return data
    }
    func syncRecoveryRecord() async throws -> Data? {
        guard let current = auth, let account = current.accountId else { return nil }
        let data = try await delta.rawRecoveryRecord(account: account)
        guard auth == current else { throw APIError(message: "账号已切换，请重新导出") }
        return data
    }

    func largeRestoreRecoveryRecord() async throws -> Data? {
        guard let current = auth, let account = current.accountId else { return nil }
        let data = try await delta.rawExperimentalLargeRestoreRecord(account: account)
        guard auth == current else { throw APIError(message: "账号已切换，请重新导出") }
        return data
    }

    /// Retry a previously staged restore only while the signed account slot and
    /// in-memory state are still the exact views recorded by that restore.
    func resumeLargeRestore() async throws {
        guard let active=auth, let account=active.accountId, route == .settings,
              undoSnapshot == nil, !localSaveFailed else { throw APIError(message:"请先登录并完成当前复习") }
        let slot=slotKey, page=routeGeneration
        guard let resume=try await delta.experimentalLargeRestoreResume(account:account) else {
            throw APIError(message:"当前没有未完成的大状态恢复")
        }
        guard auth == active, slotKey == slot, route == .settings, routeGeneration == page,
              undoSnapshot == nil, !localSaveFailed else { throw APIError(message:"账号或页面已变化，请重试") }
        pushTask?.cancel()
        let confirm: @MainActor @Sendable (LearningState) throws -> Void = { [weak self] target in
            guard let self, self.auth == active, self.slotKey == slot, self.route == .settings,
                  self.routeGeneration == page, self.undoSnapshot == nil, !self.localSaveFailed,
                  self.S == target,
                  LocalAccountSlot.loadVerified(state:self.stateURL(for:slot),owner:self.userURL(for:slot),expected:account) == target else {
                throw APIError(message:"本机进度或账号已变化，请先导出")
            }
            // These files must be durable before the final fence can be removed.
            for url in [self.stateURL(for:slot),self.userURL(for:slot),self.stateURL(for:slot).deletingLastPathComponent()] {
                let fd=open(url.path,O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw APIError(message:"无法确认本机进度已保存，请先导出") }
                let result=fsync(fd); close(fd)
                guard result == 0 else { throw APIError(message:"无法确认本机进度已保存，请先导出") }
            }
        }
        if resume.phase == .installSlot {
            try await delta.installExperimentalLargeRestoreSlot(account:account,token:active.token,previous:resume.previous) { [weak self] old,target in
                guard let self, self.auth == active, self.slotKey == slot, self.route == .settings,
                      self.routeGeneration == page, self.undoSnapshot == nil, !self.localSaveFailed,
                      LocalAccountSlot.loadVerified(state:self.stateURL(for:slot),owner:self.userURL(for:slot),expected:account) == self.S else {
                    throw APIError(message:"本机进度或账号已变化，请先导出")
                }
                if self.S == old {
                    self.S=target;self.saveLocal()
                    guard !self.localSaveFailed else { self.S=old;throw APIError(message:"无法保存恢复结果，请先导出") }
                } else if self.S != target { throw APIError(message:"本机进度已变化，请先导出") }
            }
            try await delta.installExperimentalLargeRestoreBaseline(account:account,token:active.token,previous:resume.previous,confirm:confirm)
        }
        let beforeFinal=S
        try await delta.finalizeExperimentalLargeRestore(account:account,token:active.token,previous:resume.previous,confirm:confirm)
        guard auth == active, slotKey == slot, route == .settings, routeGeneration == page, S == beforeFinal,
              undoSnapshot == nil, !localSaveFailed else { throw APIError(message:"恢复已完成，账号或页面已变化，请重新同步") }
        UserDefaults.standard.set(UserDefaults.standard.double(forKey:"vocab_write_\(slot)"),forKey:lastSyncKey)
        syncFailed=false;syncMsg="✓ 已同步"
    }

    func cancelLargeCheckpoint() async throws { try await cancelLargeOperation(restore:false) }
    func cancelLargeRestore() async throws { try await cancelLargeOperation(restore:true) }
    private func cancelLargeOperation(restore: Bool) async throws {
        guard let active=auth, let account=active.accountId, route == .settings,
              undoSnapshot == nil, !localSaveFailed else { throw APIError(message:"请先登录并完成当前复习") }
        let slot=slotKey, page=routeGeneration
        pushTask?.cancel()
        try await delta.cancelExperimentalLargeOperation(account:account,token:active.token,restore:restore) { [weak self] previous in
            guard let self, self.auth == active, self.slotKey == slot, self.route == .settings, self.routeGeneration == page,
                  self.undoSnapshot == nil, !self.localSaveFailed, self.S == previous,
                  LocalAccountSlot.loadVerified(state:self.stateURL(for:slot),owner:self.userURL(for:slot),expected:account) == previous else {
                throw APIError(message:"本机进度或账号已变化，请先导出")
            }
            for url in [self.stateURL(for:slot),self.userURL(for:slot),self.stateURL(for:slot).deletingLastPathComponent()] {
                let fd=open(url.path,O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw APIError(message:"无法确认本机进度已保存，请先导出") }
                let result=fsync(fd);close(fd)
                guard result == 0 else { throw APIError(message:"无法确认本机进度已保存，请先导出") }
            }
        }
        guard auth == active, slotKey == slot, route == .settings, routeGeneration == page else {
            throw APIError(message:"操作已取消，账号或页面已变化，请重新同步")
        }
        syncFailed=false; syncMsg=restore ? "恢复已取消；本机进度已保留，请同步" : "整理已取消；本机进度已保留，请同步"
    }

    /// If the primary slot is missing, retain a durable in-flight target rather
    /// than overwriting it with a server read before the batch can be retried.
    private func recoverPendingSlot(_ current: Auth) async throws -> Bool {
        guard let account = current.accountId else { return false }
        let before = S
        let pending = try await delta.pendingTarget(account: account)
        let data = pending == nil ? try await delta.pendingPullPrevious(account: account) : pending
        guard auth == current, S == before else { throw APIError(message: "本机进度已变化，请重试") }
        guard let data else { return false }
        let recovered = try JSONDecoder().decode(LearningState.self, from: data)
        S = recovered
        saveLocal()
        guard !localSaveFailed else { S = before; throw APIError(message: "待同步进度无法保存，请先导出并释放空间") }
        UserDefaults.standard.set(0, forKey: lastSyncKey)
        return true
    }

    private func stateURL(for slot: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Config.stateFilePrefix)_\(slot).json")
    }

    private func userURL(for slot: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Config.stateFilePrefix)_\(slot).user")
    }

    private func saveLocal() {
        do {
            let data = try JSONEncoder().encode(S)
            let path = stateURL(for: slotKey)
            var damaged = false
            if FileManager.default.fileExists(atPath: path.path) {
                let old = try Data(contentsOf: path)
                damaged = (try? JSONDecoder().decode(LearningState.self, from: old)) == nil
            }
            _ = try LocalAccountSlot.preserveUnverified(state: path, owner: userURL(for: slotKey),
                expected: auth?.accountId ?? auth?.username ?? "guest", slot: slotKey, force: damaged)
            try data.write(to: path, options: .atomic)
            // 槽位署名防止 uid 复用时错配旧本地存档。
            try (auth?.accountId ?? auth?.username ?? "guest").write(to: userURL(for: slotKey), atomically: true, encoding: .utf8)
            let key = "vocab_write_\(slotKey)"
            let previous = UserDefaults.standard.double(forKey: key)
            UserDefaults.standard.set(max(Date().timeIntervalSince1970, previous + 0.001), forKey: key)
            localSaveFailed = false
        } catch {
            localSaveFailed = true
        }
    }

    /// 回到前台：有未同步修改先补推，再拉服务器合并结果（学习会话中不打扰）
    func pullIfNewer() async {
        guard route != .session else { return }
        if auth != nil { await syncFromServer() }
        if route == .home {
            await flushPendingFsrs()
            await refreshPersonalJobs()
        }
    }

    /// 网络恢复后重试本机评分和上传；学习中不替换当前会话的状态。
    func networkReconnected() async {
        guard booted else { return }
        guard auth == nil || auth?.accountId != nil else { return }
        if route == .session {
            guard undoSnapshot == nil else { return }
            await flushPendingFsrs()
            let defaults = UserDefaults.standard
            if auth != nil, defaults.double(forKey: "vocab_write_\(slotKey)") > defaults.double(forKey: lastSyncKey) {
                await pushNow()
            }
        } else {
            await pullIfNewer()
        }
    }

    private func loadLocal(slot: String, forUsername: String? = nil) -> LearningState? {
        func read(_ candidate: String, username: String?) -> LearningState? {
            LocalAccountSlot.loadVerified(state: stateURL(for: candidate), owner: userURL(for: candidate), expected: username)
        }
        if let state = read(slot, username: auth?.accountId ?? forUsername) { return state }
        // 有新槽位但损坏或署名不符时不能回退到可能过时的旧槽位。
        guard !FileManager.default.fileExists(atPath: stateURL(for: slot).path),
              let username = forUsername, let auth, auth.accountId == nil, slot != "guest" else { return nil }
        let legacy = "u\(auth.userId)"
        guard let state = read(legacy, username: username) else { return nil }
        // 继承该账号旧槽位的同步水位，避免尚未上传的离线修改被远端覆盖。
        LocalAccountSlot.migrateClocks(UserDefaults.standard, from: legacy, to: slot)
        return state
    }

    /// 不把署名属于其他账号的旧数据展示给当前账号；未署名的原始内容可显式导出。
    var unverifiedStateURLs: [URL] {
        var paths: [URL] = []
        if let auth {
            let legacy = "u\(auth.userId)"
            let legacyOwner = try? String(contentsOf: userURL(for: legacy), encoding: .utf8)
            if FileManager.default.fileExists(atPath: stateURL(for: legacy).path),
               (!FileManager.default.fileExists(atPath: userURL(for: legacy).path) ||
                (auth.accountId != nil && legacyOwner?.lowercased() == auth.username.lowercased())) {
                paths.append(stateURL(for: legacy))
            }
            if auth.accountId != nil {
                let named = LocalAccountSlot.name(userId: auth.userId, username: auth.username)
                let owner = try? String(contentsOf: userURL(for: named), encoding: .utf8)
                if FileManager.default.fileExists(atPath: stateURL(for: named).path),
                   owner == nil || owner?.lowercased() == auth.username.lowercased() {
                    paths.append(stateURL(for: named))
                }
                let backups = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("VocabBackups", isDirectory: true)
                if let contents = try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil) {
                    let prefix = "before-restore-\(named)-"
                    paths.append(contentsOf: contents.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent })
                }
            }
            // 旧恢复前备份没有独立署名，只能按未确认数据显式导出。
            if legacyOwner == nil || legacyOwner?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == auth.username.lowercased() {
                let backups = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("VocabBackups", isDirectory: true)
                let prefix = "before-restore-\(legacy)-"
                if let contents = try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil) {
                    paths.append(contentsOf: contents.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent })
                }
            }
        }
        let directory = stateURL(for: slotKey).deletingLastPathComponent()
        let prefix = "unverified-\(slotKey)-"
        if let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            paths.append(contentsOf: contents.filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted { $0.lastPathComponent < $1.lastPathComponent })
        }
        return paths
    }

    func unverifiedState(_ url: URL) throws -> Data {
        guard unverifiedStateURLs.contains(url) else { throw APIError(message: "旧存档不属于当前恢复范围") }
        return try Data(contentsOf: url)
    }

    /// 预览阶段不写入任何状态；登录用户同时读取服务器版本用于后续条件更新。
    func prepareRestore(_ data: Data) async throws -> RestorePlan {
        if let auth, auth.accountId == nil { throw APIError(message: "请先重新登录，再核对旧存档") }
        let isLarge=data.count > 8 * 1024 * 1024
        guard data.count <= 14 * 1024 * 1024, (!isLarge || auth?.accountId != nil),
              case .object = try StateDelta.decode(data),
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = raw["v"] as? Int, version >= 1,
              raw["cards"] is [String: Any], raw["log"] is [Any],
              raw["pendingNew"] is [Any], raw["settings"] is [String: Any],
              raw["__proto__"] == nil else { throw APIError(message: "备份格式无效或超过允许大小") }
        let restored = try JSONDecoder().decode(LearningState.self, from: data)
        let before = S, slot = slotKey, owner = auth?.userId, token = auth?.token
        if isLarge {
            guard let token, try await api.supportsExperimentalLargeRestore(expectedToken:token) else {
                throw APIError(message:"服务器未启用大状态恢复，请保留备份")
            }
        }
        let remote: StateResponse? = owner == nil ? nil : try await api.pullState(expectedToken: token)
        if isLarge {
            guard remote?.state != nil, remote?.state_revision != nil, remote?.sync_generation != nil,
                  (remote?.state?.restoreEpoch ?? 0) == (before.restoreEpoch ?? 0) else {
                throw APIError(message:"服务器恢复版本或同步基线不一致，请先同步并导出")
            }
        }
        guard slotKey == slot, auth?.userId == owner, auth?.token == token, S == before else {
            throw APIError(message: "进度已变化，请重新选择备份")
        }
        return RestorePlan(state: restored, before: before, slot: slot, owner: owner, token: token,
                           expectedUpdatedAt: remote?.updated_at, expectedRevision: remote?.state_revision,
                           expectedGeneration: remote?.sync_generation, remoteCardCount: remote?.state?.cards.count ?? 0,
                           largePayload:isLarge ? data : nil)
    }

    private func backupLocalState(_ state: LearningState, slot: String) throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VocabBackups", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("before-restore-\(slot)-\(UUID().uuidString).json")
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
        } catch {
            throw APIError(message: "无法备份当前本机进度，请先导出并释放空间")
        }
    }

    func latestLocalBackup() throws -> LearningState {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VocabBackups", isDirectory: true)
        let prefix = "before-restore-\(slotKey)-"
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var backups=urls.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
        if let account=auth?.accountId, LocalAccountSlot.validAccountID(account) {
            let deltaDirectory=recoveryDirectory.appendingPathComponent("VocabDelta",isDirectory:true)
            let deltaBackups=(try? FileManager.default.contentsOfDirectory(at:deltaDirectory,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []
            let pattern="^before-large-restore-\(account)-[a-f0-9]{32}\\.json$"
            backups += deltaBackups.filter { $0.lastPathComponent.range(of:pattern,options:.regularExpression) != nil }
        }
        let candidates = backups.sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        guard let latest = candidates.first else { throw APIError(message: "没有恢复前的本机备份") }
        return try JSONDecoder().decode(LearningState.self, from: Data(contentsOf: latest))
    }

    /// 先备份本机旧档，再按预览版本条件恢复服务器；等待期间有新修改时不覆盖内存。
    func applyRestore(_ plan: RestorePlan) async throws {
        guard slotKey == plan.slot, auth?.userId == plan.owner, auth?.token == plan.token, S == plan.before, undoSnapshot == nil else {
            throw APIError(message: "进度已变化，请重新选择备份")
        }
        try backupLocalState(plan.before, slot: plan.slot)
        pushTask?.cancel()
        if plan.owner != nil {
            guard let account = auth?.accountId, let token = plan.token else { throw APIError(message: "账号已切换，请重试") }
            if let payload=plan.largePayload {
                guard route == .settings, !localSaveFailed, let generation=plan.expectedGeneration, let revision=plan.expectedRevision,
                      LocalAccountSlot.loadVerified(state:stateURL(for:plan.slot),owner:userURL(for:plan.slot),expected:account) == plan.before else {
                    throw APIError(message:"本机进度或同步基线不一致，请先同步并导出")
                }
                let intent=ExperimentalLargeRestoreIntent(batchID:UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),
                    generation:generation,baseRevision:revision,restoreEpoch:plan.before.restoreEpoch ?? 0,payload:payload)
                do {
                    _ = try await delta.beginExperimentalLargeRestore(account:account,token:token,intent:intent,previous:JSONEncoder().encode(plan.before))
                    try await resumeLargeRestore()
                } catch {
                    if auth?.accountId == account, auth?.token == token { syncFailed=true }
                    throw APIError(message:"大状态恢复未完成，服务器可能已接收；请保留备份并使用“继续未完成的恢复或整理”。原因：\(error.localizedDescription)")
                }
                return
            }
            _ = try await delta.restoreAndClear(account: account, token: token, state: plan.state,
                expectedUpdatedAt: plan.expectedUpdatedAt, revision: plan.expectedRevision, generation: plan.expectedGeneration,
                archiveDirectory: recoveryDirectory) { @MainActor [weak self] response, store, archive in
                guard let self, self.slotKey == plan.slot, self.auth?.userId == plan.owner, self.auth?.token == plan.token,
                      self.S == plan.before, self.undoSnapshot == nil, !self.localSaveFailed else {
                    throw APIError(message: "服务器已恢复，但本机进度在请求期间变化；请先导出本机进度")
                }
                guard let restored = response.state else { throw APIError(message: "服务器未返回恢复结果") }
                self.S = restored
                self.saveLocal()
                guard !self.localSaveFailed else {
                    self.S = plan.before; self.syncFailed = true
                    throw APIError(message: "恢复结果无法保存到本机；请先导出并释放空间")
                }
                do { try store.clearPreparedArchive(archive) }
                catch { self.syncFailed = true; throw APIError(message: "服务器已恢复，但本机同步记录已变化或无法清除；请先导出本机进度") }
                UserDefaults.standard.set(UserDefaults.standard.double(forKey: "vocab_write_\(self.slotKey)"), forKey: self.lastSyncKey)
                self.syncFailed = false
            }
            return
        }
        S = plan.state
        saveLocal()
        guard !localSaveFailed else {
            S = plan.before
            throw APIError(message: "恢复结果无法保存到本机；请先导出并释放空间")
        }
        syncFailed = false
    }

    /// 建立检查点前同步本机并备份，服务器以版本比较保护并发修改。
    func checkpointHistory() async throws {
        guard let active = auth, active.accountId != nil, undoSnapshot == nil, !localSaveFailed else {
            throw APIError(message: "请先登录并完成当前复习")
        }
        pushTask?.cancel()
        guard await syncFromServer() else { throw APIError(message: "同步未完成，请先处理待同步进度") }
        let before = S, slot = slotKey
        guard auth?.token == active.token, auth?.userId == active.userId else { throw APIError(message: "账号已切换") }
        let remote = try await api.pullState(expectedToken: active.token)
        guard let updated = remote.updated_at, remote.state != nil, slotKey == slot, auth?.token == active.token,
              S == before, undoSnapshot == nil, !localSaveFailed else { throw APIError(message: "进度已变化，请重新同步后再整理") }
        try backupLocalState(before, slot: slot)
        let latest = try await api.pullState(expectedToken: active.token)
        guard slotKey == slot, auth?.token == active.token, S == before, latest.updated_at == updated,
              latest.state_revision == remote.state_revision, latest.sync_generation == remote.sync_generation else {
            throw APIError(message: "服务器进度已变化，请重新同步后再整理")
        }
        if remote.fromLargeSnapshot {
            let page=routeGeneration
            guard let account=active.accountId, let generation=remote.sync_generation, let revision=remote.state_revision,
                  route == .settings, try await api.supportsExperimentalLargeCheckpoint(expectedToken:active.token),
                  route == .settings, routeGeneration == page, auth == active, slotKey == slot, S == before, undoSnapshot == nil, !localSaveFailed,
                  LocalAccountSlot.loadVerified(state:stateURL(for:slot),owner:userURL(for:slot),expected:account) == before else {
                throw APIError(message:"服务器未启用大状态整理或本机进度已变化，请先同步并导出")
            }
            try await api.previewExperimentalLargeCheckpoint(generation:generation,revision:revision,
                                                             epoch:before.restoreEpoch ?? 0,expectedToken:active.token)
            guard route == .settings, routeGeneration == page, auth == active, slotKey == slot, S == before,
                  undoSnapshot == nil, !localSaveFailed,
                  LocalAccountSlot.loadVerified(state:stateURL(for:slot),owner:userURL(for:slot),expected:account) == before else {
                throw APIError(message:"账号、页面或本机进度已变化，请重新同步")
            }
            let previous=try JSONEncoder().encode(before)
            let intent=ExperimentalLargeRestoreIntent(batchID:UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),
                generation:generation,baseRevision:revision,restoreEpoch:before.restoreEpoch ?? 0,payload:previous,kind:"checkpoint")
            do {
                _ = try await delta.beginExperimentalLargeRestore(account:account,token:active.token,intent:intent,previous:previous)
                try await resumeLargeRestore()
            } catch {
                if auth == active { syncFailed=true }
                throw APIError(message:"大状态整理未完成，服务器可能已处理；请导出并使用“继续未完成的恢复或整理”。原因：\(error.localizedDescription)")
            }
            return
        }
        _ = try await delta.checkpointAndClear(account: active.accountId!, token: active.token,
            expectedUpdatedAt: updated, revision: remote.state_revision, generation: remote.sync_generation, archiveDirectory: recoveryDirectory) { @MainActor [weak self] response, store, archive in
            guard let self, self.slotKey == slot, self.auth?.userId == active.userId, self.auth?.token == active.token,
                  self.S == before, self.undoSnapshot == nil, !self.localSaveFailed else {
                throw APIError(message: "服务器已整理，但本机进度发生变化；请先导出本机进度")
            }
            guard let compacted = response.state else { throw APIError(message: "服务器未返回整理结果") }
            self.S = compacted
            self.saveLocal()
            guard !self.localSaveFailed else {
                self.S = before; self.syncFailed = true
                throw APIError(message: "整理结果无法保存到本机，请先导出并释放空间")
            }
            do { try store.clearPreparedArchive(archive) }
            catch { self.syncFailed = true; throw APIError(message: "服务器已整理，但本机同步记录已变化或无法清除；请先导出本机进度") }
            UserDefaults.standard.set(UserDefaults.standard.double(forKey: "vocab_write_\(self.slotKey)"), forKey: self.lastSyncKey)
            self.syncFailed = false
        }
    }

    func prepareServerReload() async throws -> ServerReloadPlan {
        guard let active = auth else { throw APIError(message: "请先登录") }
        guard let account = active.accountId else { throw APIError(message: "请先重新登录，再核对旧存档") }
        let owner = active.userId, before = S, slot = slotKey
        let missingSyncRecord = try await delta.hasMissingRecord(account: account)
        let response = try await api.pullState(expectedToken: active.token)
        guard slotKey == slot, auth?.userId == owner, auth?.token == active.token, S == before else { throw APIError(message: "本机进度已变化，请重试") }
        guard let remote = response.state else { throw APIError(message: "服务器没有可加载的进度") }
        return ServerReloadPlan(state: remote, before: before, slot: slot, owner: owner, token: active.token,
                                updatedAt: response.updated_at, revision: response.state_revision, generation: response.sync_generation,
                                missingSyncRecord: missingSyncRecord)
    }

    func applyServerReload(_ plan: ServerReloadPlan) async throws {
        guard slotKey == plan.slot, auth?.userId == plan.owner, auth?.token == plan.token, S == plan.before, undoSnapshot == nil else {
            throw APIError(message: "本机进度已变化，请重试")
        }
        let latest = try await api.pullState(expectedToken: plan.token)
        guard slotKey == plan.slot, auth?.userId == plan.owner, auth?.token == plan.token, S == plan.before, undoSnapshot == nil else { throw APIError(message: "本机进度已变化，请重试") }
        guard latest.updated_at == plan.updatedAt, latest.state != nil, latest.state_revision == plan.revision,
              latest.sync_generation == plan.generation else { throw APIError(message: "服务器进度已变化，请重试") }
        try backupLocalState(plan.before, slot: plan.slot)
        pushTask?.cancel()
        guard let account = auth?.accountId else { throw APIError(message: "账号已切换，请重试") }
        try await delta.reloadCheckAndClear(account: account, token: plan.token, updatedAt: plan.updatedAt,
                                                revision: plan.revision, generation: plan.generation, archiveDirectory: recoveryDirectory,
                                                allowMissingRecord: plan.missingSyncRecord) { @MainActor [weak self] store in
                guard let self, self.slotKey == plan.slot, self.auth?.userId == plan.owner, self.auth?.token == plan.token,
                      self.S == plan.before, self.undoSnapshot == nil, !self.localSaveFailed else {
                    throw APIError(message: "本机进度已变化，请重试")
                }
                // Save before removing the fence. A failed disk write must not
                // leave an unsynced local state without its generation guard.
                self.S = plan.state
                self.saveLocal()
                guard !self.localSaveFailed else {
                    self.S = plan.before
                    throw APIError(message: "无法保存服务器进度，请先导出并释放空间")
                }
                do {
                    try store.archivePendingAndClear(to: self.recoveryDirectory, allowMissingRecord: plan.missingSyncRecord)
                } catch {
                    self.S = plan.before
                    self.saveLocal()
                    throw error
                }
                UserDefaults.standard.set(UserDefaults.standard.double(forKey: "vocab_write_\(self.slotKey)"), forKey: self.lastSyncKey)
                self.syncFailed = false
            }
    }

    private func isAuthError(_ error: Error) -> Bool {
        (error as? APIError)?.statusCode == 401
    }

    private func handleSyncError(_ error: Error) async {
        if isAuthError(error) {
            guard switchAccount() else { syncFailed = true; return }
            route = .auth(login: true)
        } else {
            syncFailed = true
            syncMsg = error.localizedDescription
        }
    }

    /// 保存 = 本地立即 + 登录后防抖 2s 推服务器（与 web 一致）
    func save() {
        // 限制日志条数；卡片和事件仍会增长，网络同步还有独立的字节上限。
        // 若写入失败，导出的内存进度必须保留裁剪前的完整日志。
        let originalLog = S.log
        if S.log.count > 1200 { S.log = StudyEngine.trimLearningLog(S.log, day: DayUtil.today()) }
        saveLocal()
        if localSaveFailed { S.log = originalLog }
        pushTask?.cancel()
        guard undoSnapshot == nil, !localSaveFailed else { return } // 撤销窗口及本机保存失败时不上传。
        guard let active = auth, let account = active.accountId else { return }
        let owner = active.userId, slot = slotKey, token = active.token
        let snapshot = S   // 值类型快照：防止切换账号后旧任务把新状态写错账号
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.auth?.userId == owner, self.auth?.token == token, self.slotKey == slot else { return }   // 账号已切换，旧推送作废
            do {
                try await self.delta.push(account: account, token: token, target: snapshot)
                guard self.auth?.userId == owner, self.auth?.token == token, self.slotKey == slot else { return }
                if self.S == snapshot && !self.localSaveFailed {
                    UserDefaults.standard.set(UserDefaults.standard.double(forKey: "vocab_write_\(self.slotKey)"), forKey: self.lastSyncKey)
                }
                self.syncFailed = false
            } catch {
                guard self.auth?.userId == owner, self.auth?.token == token, self.slotKey == slot else { return }
                await self.handleSyncError(error)
            }
        }
    }

    func pushNow() async {
        guard let active = auth else { return }
        guard let account = active.accountId else { syncMsg = "旧会话仅保存在本机，请重新登录并核对旧存档"; return }
        let owner = active.userId, token = active.token
        guard undoSnapshot == nil else { syncMsg = "请先完成当前复习"; return }
        guard !localSaveFailed else { syncMsg = "本机保存失败，请先导出进度并释放空间"; return }
        pushTask?.cancel()
        let slot = slotKey, snapshot = S, generation = routeGeneration
        do {
            try await delta.push(account: account, token: token, target: snapshot)
            guard auth?.userId == owner, auth?.token == token, slotKey == slot else { return }
            guard S == snapshot, !localSaveFailed else {
                syncMsg = "先前进度已同步，最新修改等待同步"
                syncFailed = false
                return
            }
            if route != .session {
                let largeBaseline = try await delta.hasLargeBaseline(account: account)
                guard auth?.userId == owner, auth?.token == token, slotKey == slot, S == snapshot,
                      !localSaveFailed, undoSnapshot == nil, routeGeneration == generation, route != .session else { return }
                if largeBaseline {
                    let installed = try await delta.readAndApply(account: account, token: token, local: snapshot) { [weak self] previous, target in
                        guard let self, self.auth?.userId == owner, self.auth?.token == token, self.slotKey == slot,
                              self.S == previous, !self.localSaveFailed, self.undoSnapshot == nil,
                              self.routeGeneration == generation, self.route != .session else {
                            throw APIError(message: "本机进度或页面已变化，请重试")
                        }
                        self.S = target
                        self.saveLocal()
                        guard !self.localSaveFailed else {
                            self.S = previous
                            throw APIError(message: "无法保存服务器进度，请先导出并释放空间")
                        }
                    }
                    guard installed else { throw APIError(message: "缺少大状态同步基线，请先导出本机进度") }
                    guard auth?.userId == owner, auth?.token == token, slotKey == slot,
                          !localSaveFailed, undoSnapshot == nil, routeGeneration == generation, route != .session else { return }
                } else {
                let remote = try await api.pullState(expectedToken: token)
                guard auth?.userId == owner, auth?.token == token, slotKey == slot else { return }
                guard S == snapshot, !localSaveFailed, undoSnapshot == nil,
                      routeGeneration == generation, route != .session else {
                    syncMsg = "进度已上传，服务器合并结果等待重新同步"
                    return
                }
                guard let merged = remote.state else { throw APIError(message: "服务器未返回合并后的进度，请重试") }
                try await delta.verifyPulled(account: account, token: token, remote: remote)
                guard auth?.userId == owner, auth?.token == token, slotKey == slot, S == snapshot,
                      !localSaveFailed, undoSnapshot == nil, routeGeneration == generation, route != .session else { return }
                if remote.fromLargeSnapshot {
                    try await delta.prime(account: account, token: token, remote: remote, local: merged)
                    guard auth?.userId == owner, auth?.token == token, slotKey == slot, S == snapshot,
                          !localSaveFailed, undoSnapshot == nil, routeGeneration == generation, route != .session else { return }
                }
                S = merged
                saveLocal()
                guard !localSaveFailed else {
                    S = snapshot
                    syncFailed = true
                    syncMsg = "无法保存服务器进度，请先导出并释放空间"
                    return
                }
                if !remote.fromLargeSnapshot { try? await delta.prime(account: account, token: token, remote: remote, local: merged) }
                guard auth?.userId == owner, auth?.token == token, slotKey == slot,
                      S == merged, !localSaveFailed, undoSnapshot == nil,
                      routeGeneration == generation, route != .session else { return }
                }
            }
            UserDefaults.standard.set(UserDefaults.standard.double(forKey: "vocab_write_\(slotKey)"), forKey: lastSyncKey)
            syncMsg = "✓ 已同步"
            syncFailed = false
        } catch {
            guard auth?.userId == owner, auth?.token == token, slotKey == slot else { return }
            await handleSyncError(error)
        }
    }

    /// 有未同步修改先补推，再拉服务器合并结果；没有未同步修改则以服务器为准。
    /// 避免“本地时间新”被误当成“本地内容更新”而覆盖新服务器状态。
    @discardableResult
    func syncFromServer() async -> Bool {
        guard undoSnapshot == nil, !localSaveFailed, let active = auth, let account = active.accountId else { return false }
        let owner = active.userId, token = active.token, slot = slotKey, startingRoute = routeGeneration
        let install: @MainActor @Sendable (LearningState, LearningState) throws -> Void = { [weak self] previous, target in
            guard let self, self.auth?.userId == owner, self.auth?.token == token, self.slotKey == slot,
                  self.routeGeneration == startingRoute, self.route != .session,
                  !self.localSaveFailed, self.undoSnapshot == nil else { throw APIError(message: "本机进度或页面已变化，请重试") }
            if self.S == previous {
                self.S = target
                self.saveLocal()
                guard !self.localSaveFailed else {
                    self.S = previous
                    throw APIError(message: "无法保存服务器进度，请先导出并释放空间")
                }
            } else if self.S != target {
                throw APIError(message: "本机进度已变化，请先导出并处理未完成下载")
            }
            UserDefaults.standard.set(UserDefaults.standard.double(forKey: "vocab_write_\(slot)"), forKey: self.lastSyncKey)
            self.syncFailed = false
        }
        do {
            if try await delta.resumePull(account: account, token: token, install: install) {
                guard auth?.userId == owner, auth?.token == token, slotKey == slot, !localSaveFailed, undoSnapshot == nil else { return false }
                return UserDefaults.standard.double(forKey: "vocab_write_\(slot)") <= UserDefaults.standard.double(forKey: lastSyncKey)
            }
            guard auth?.userId == owner, auth?.token == token, slotKey == slot, !localSaveFailed, undoSnapshot == nil else { return false }
            let snapshot = S
            let localTs = UserDefaults.standard.double(forKey: "vocab_write_\(slotKey)")
            let lastSync = UserDefaults.standard.double(forKey: lastSyncKey)
            // Never replace a local view while a durable batch still needs
            // replay, even if an old watermark happens to say it is synced.
            let pending = try await delta.pendingTarget(account: account)
            guard auth?.userId == owner, auth?.token == token, slotKey == slot, S == snapshot, !localSaveFailed, undoSnapshot == nil else { return false }
            if localTs > lastSync || pending != nil {
                try await delta.push(account: account, token: token, target: snapshot)
                guard auth?.userId == owner, auth?.token == token, slotKey == slot, S == snapshot,
                      routeGeneration == startingRoute, route != .session, !localSaveFailed, undoSnapshot == nil else { return false }
                UserDefaults.standard.set(localTs, forKey: lastSyncKey)
            }
            do {
                if try await delta.readAndApply(account: account, token: token, local: snapshot, install: install) {
                    guard auth?.userId == owner, auth?.token == token, slotKey == slot, !localSaveFailed, undoSnapshot == nil else { return false }
                    return UserDefaults.standard.double(forKey: "vocab_write_\(slot)") <= UserDefaults.standard.double(forKey: lastSyncKey)
                }
            } catch let error as APIError where error.statusCode == 410 {
                // A pruned journal requires the existing fully verified pull.
            }
            let remote = try await api.pullState(expectedToken: token)
            guard auth?.userId == owner, auth?.token == token, slotKey == slot, S == snapshot,
                  routeGeneration == startingRoute, route != .session, !localSaveFailed, undoSnapshot == nil else { return false }
            if let rs = remote.state {
                try await delta.verifyPulled(account: account, token: token, remote: remote)
                guard auth?.userId == owner, auth?.token == token, slotKey == slot, S == snapshot,
                      routeGeneration == startingRoute, route != .session, !localSaveFailed, undoSnapshot == nil else { return false }
                if remote.fromLargeSnapshot {
                    try await delta.prime(account: account, token: token, remote: remote, local: rs)
                    guard auth?.userId == owner, auth?.token == token, slotKey == slot, S == snapshot,
                          routeGeneration == startingRoute, route != .session, !localSaveFailed, undoSnapshot == nil else { return false }
                }
                S = rs
                saveLocal()
                guard !localSaveFailed else { S = snapshot; syncFailed = true; return false }
                UserDefaults.standard.set(UserDefaults.standard.double(forKey: "vocab_write_\(slotKey)"), forKey: lastSyncKey)
                if !remote.fromLargeSnapshot { try? await delta.prime(account: account, token: token, remote: remote, local: rs) }
                guard auth?.userId == owner, auth?.token == token, slotKey == slot, S == rs,
                      !localSaveFailed, undoSnapshot == nil else { return false }
                return true
            }
            return false
        } catch {
            guard auth?.userId == owner, auth?.token == token, slotKey == slot else { return false }
            await handleSyncError(error)
            return false
        }
    }

    // MARK: 设备 ID（个性化例句分桶，与 web 规则一致）

    private var undoSnapshot: (word: String, card: CardState, log: [LogEntry], knowledge: [String: KnowledgeStat]?, knowledgeEvidence: [String: KnowledgeEvidence]?, posterior: [Double]?, posteriorHistory: PosteriorHistory?, probeCount: Int, track: TrackState?)?

    /// 撤销最近一次「忘记」评分（手滑误点）：恢复卡片 FSRS 状态、删除日志、回到出题环节
    func undoReview() {
        guard let snap = undoSnapshot else { return }
        S.cards[snap.word] = snap.card
        S.log = snap.log
        S.knowledge = snap.knowledge
        S.knowledgeEvidence = snap.knowledgeEvidence
        S.posterior = snap.posterior
        S.posteriorHistory = snap.posteriorHistory
        S.probeCount = snap.probeCount
        S.track = snap.track
        undoSnapshot = nil
        if session.reviewedToday > 0 { session.reviewedToday -= 1 }
        save()
    }

    func commitUndoReview() {
        guard undoSnapshot != nil else { return }
        undoSnapshot = nil
        save()
    }

    // MARK: 设备 ID（个性化例句分桶，与 web 规则一致）

    func deviceId() -> String {
        if let auth { return "u\(auth.userId)" }
        let key = "vocab_device_v2"
        if let d = UserDefaults.standard.string(forKey: key) { return d }
        let d = "ios-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(d, forKey: key)
        return d
    }

    // MARK: 启动与认证

    func boot() async {
        guard !booted else { return }
        booted = true
        if let a = restoreAuth() {
            auth = a
            await api.setToken(a.token)
            guard auth == a else { return }
            let local = loadLocal(slot: slotKey, forUsername: a.username)
            S = local ?? LearningState()   // 先装本机存档，绝不能用空白内存覆盖服务器
            if a.accountId == nil {
                syncFailed = true
                syncMsg = "旧会话仅保存在本机，请重新登录并核对旧存档"
                route = .home
                return
            }
            if local != nil {
                _ = await syncFromServer()
            } else {
                // 无可信本地槽位时只拉取，不能用空白状态和旧时间戳先推送。
                let snapshot = S
                do {
                    if try await recoverPendingSlot(a) {
                        _ = await syncFromServer()
                        guard auth == a else { return }
                        route = .home
                        return
                    }
                    let remote = try await api.pullState(expectedToken: a.token)
                    guard auth == a, S == snapshot else { return }
                    if let state = remote.state {
                        try await delta.verifyPulled(account: a.accountId!, token: a.token, remote: remote)
                        guard auth == a, S == snapshot else { return }
                        if remote.fromLargeSnapshot {
                            try await delta.prime(account: a.accountId!, token: a.token, remote: remote, local: state)
                            guard auth == a, S == snapshot else { return }
                        }
                        S = state; saveLocal()
                        if !localSaveFailed {
                            UserDefaults.standard.set(UserDefaults.standard.double(forKey: "vocab_write_\(slotKey)"), forKey: lastSyncKey)
                            if !remote.fromLargeSnapshot { try? await delta.prime(account: a.accountId!, token: a.token, remote: remote, local: state) }
                            guard auth == a, S == state else { return }
                        }
                    }
                } catch {
                    guard auth == a else { return }
                    await handleSyncError(error)
                }
            }
            guard auth == a else { return }   // 401 已切到登录页，不再跳回主页
            route = .home
        } else if UserDefaults.standard.bool(forKey: "vocab_guest") {
            S = loadLocal(slot: "guest") ?? LearningState()
            route = .home
        } else {
            route = .welcome
        }
    }

    private func restoreAuth() -> Auth? {
        guard let token = Keychain.load("token"),
              let d = UserDefaults.standard.data(forKey: "vocab_profile"),
              let p = try? JSONDecoder().decode(AuthUser.self, from: d) else { return nil }
        guard p.account_id == nil || LocalAccountSlot.validAccountID(p.account_id!) else { return nil }
        return Auth(userId: p.id, accountId: p.account_id, username: p.username, nickname: p.nickname, token: token)
    }

    func enterGuest() {
        UserDefaults.standard.set(true, forKey: "vocab_guest")
        placementSet = nil   // 进游客也清空定级题缓存（与账号隔离）
        S = loadLocal(slot: "guest") ?? LearningState()
        route = .home
    }

    /// 登录/注册成功后的状态装载
    /// - 服务器有存档 → 服务器为准
    /// - 否则有本机槽位 → 用槽位并推上服务器
    /// - 注册新账号：绝不并入当前内存进度（新账号 = 全新开始 + 定级）
    /// - 登录老账号且两端都空 → 才把当前（游客）进度并入
    func authed(_ r: AuthResponse, isRegistration: Bool = false) async {
        pushTask?.cancel()   // 先取消旧账号延迟推送，防止旧状态写到新账号
        pushTask = nil
        let wasGuest = auth == nil && UserDefaults.standard.bool(forKey: "vocab_guest")
        // 归档当前进度——但空状态不归档（切换/登出后 S 已被重置，
        // 此时归档会把游客等旧槽位覆盖成空白，造成进度丢失）
        if (auth != nil || wasGuest) && (!S.cards.isEmpty || S.probeCount > 0 || !S.log.isEmpty) {
            saveLocal()
        }
        placementSet = nil   // 换账号必须重抽定级题（否则新用户会做到上一个用户的卷子）
        guard r.user.account_id == nil || LocalAccountSlot.validAccountID(r.user.account_id!) else { syncMsg = "账号标识无效，请重试"; return }
        let a = Auth(userId: r.user.id, accountId: r.user.account_id, username: r.user.username,
                     nickname: r.user.nickname, token: r.token)
        auth = a
        await api.setToken(a.token)
        guard auth == a else { return }
        let credentialStatus = Keychain.save(a.token, for: "token")
        credentialSaveFailed = credentialStatus != 0
        if credentialSaveFailed {
            // Never pair the new profile with an older token after a failed write.
            Keychain.delete("token")
            UserDefaults.standard.removeObject(forKey: "vocab_profile")
            Logger.app.error("Unable to save login credential, status=\(credentialStatus)")
        } else if let d = try? JSONEncoder().encode(r.user) {
            UserDefaults.standard.set(d, forKey: "vocab_profile")
        }
        UserDefaults.standard.set(false, forKey: "vocab_guest")
        let previousState = S
        let local = loadLocal(slot: slotKey, forUsername: r.user.username)
        S = local ?? LearningState()   // 先切换到目标账号存档，不能把上一个账号/游客状态误推过去
        if a.accountId == nil {
            syncFailed = true
            syncMsg = "服务器未提供账号标识，请更新服务器后重新登录"
            route = .home
            return
        }
        if local != nil {
            _ = await syncFromServer() // 失败时保留该账号的本地状态，不把失败误当成空服务器。
        } else {
            let snapshot = S
            do {
                if try await recoverPendingSlot(a) {
                    _ = await syncFromServer()
                    guard auth == a else { return }
                    route = .home
                    return
                }
                let remote = try await api.pullState(expectedToken: a.token)
                guard auth == a, S == snapshot else { return }
                if let state = remote.state {
                    try await delta.verifyPulled(account: a.accountId!, token: a.token, remote: remote)
                    guard auth == a, S == snapshot else { return }
                    if remote.fromLargeSnapshot {
                        try await delta.prime(account: a.accountId!, token: a.token, remote: remote, local: state)
                        guard auth == a, S == snapshot else { return }
                    }
                    S = state; saveLocal()
                    if !localSaveFailed {
                        UserDefaults.standard.set(UserDefaults.standard.double(forKey: "vocab_write_\(slotKey)"), forKey: lastSyncKey)
                        if !remote.fromLargeSnapshot { try? await delta.prime(account: a.accountId!, token: a.token, remote: remote, local: state) }
                        guard auth == a, S == state else { return }
                    }
                } else if wasGuest && !isRegistration && (!previousState.cards.isEmpty || previousState.probeCount > 0) {
                    S = previousState
                    save() // 只有确认服务器为空且来源确为游客时才导入。
                }
                syncFailed = false
            } catch {
                guard auth == a else { return }
                await handleSyncError(error)
            }
        }
        guard auth == a else { return }
        route = .home
    }

    /// 重新定级：重置探测状态并重抽题库（30 题新随机卷）。
    /// 已学卡片、FSRS 调度、连续天数全部保留；完成后 frontier/pointer 跳到新边界。
    func startReplacement() {
        guard let version = StudyEngine.nextPlacementVersion(S.placementVersion, device: versionDevice(), id: UUID().uuidString.lowercased()) else {
            syncMsg = "定级版本无效，请先导出进度并重新加载"
            return
        }
        S.placementVersion = version
        S.calibrated = false
        S.posterior = nil
        S.posteriorHistory = nil
        S.probeCount = 0
        S.wrongStreak = 0
        S.track = nil          // 追踪状态一并刷新（先验更换）
        S.bandStats = nil      // 重新定级重置档位先验；词级历史证据保留
        S.bandEvidence = nil
        S.placementResetAt = Date().timeIntervalSince1970   // 显式重测，服务端不得合并回旧后验
        placementSet = nil
        placementSession = UUID()
        save()
        route = .placement
    }

    /// 独立留出水平校验：单独维护一份后验，不写 S.posterior/log/cards/pendingNew，不影响学习计划
    func startValidation() async throws {
        let owner = auth, generation = routeGeneration, origin = route
        let r = try await api.placementSet(seed: "validation-\(deviceId())-\(Int(Date().timeIntervalSince1970))")
        guard auth == owner, route == origin, routeGeneration == generation, !Task.isCancelled else { return }
        guard r.words.count >= 24 else { throw APIError(message: "校验题目不足，请稍后重试") }
        validation = ValidationSession(words: Array(r.words.prefix(24)))
        route = .validation
    }

    func answerValidation(ok: Bool, countEvidence: Bool = true) {
        guard var v = validation, v.idx < v.words.count else { return }
        let w = v.words[v.idx]
        let reverse = v.idx % 2 == 1
        if countEvidence {
            v.posterior = StudyEngine.posteriorCalc(v.posterior, rank: w.pos, resp: ok ? 1 : 0,
                                                    weight: 1.0, guess: reverse ? 0 : 0.25)
            if ok { v.correct += 1 }
        } else {
            v.failed += 1
        }
        v.idx += 1
        validation = v
        if v.idx >= v.words.count {
            if v.failed == 0 {
                let mean = Int(StudyEngine.posteriorMean(v.posterior).rounded())
                let std = Int(StudyEngine.posteriorStd(v.posterior).rounded())
                let appMean = Int(StudyEngine.postMean(S).rounded())
                S.evalReport = EvalReport(date: DayUtil.today(), mean: mean, std: std,
                                          appMean: appMean, delta: appMean - mean,
                                          correct: v.correct, count: v.words.count)
            } else {
                S.evalReport = nil   // 有题目失败，不给出伪精确估值
            }
            save()
        }
    }

    func closeValidation() {
        validation = nil
        route = .settings
    }

    @discardableResult
    func switchAccount() -> Bool {
        commitUndoReview()
        pushTask?.cancel()
        pushTask = nil
        saveLocal()
        guard !localSaveFailed else {
            syncMsg = "本机保存失败，请先导出进度并释放空间"
            return false
        }
        let previousToken = auth?.token
        auth = nil
        fsrsReplayError = ""
        Task { await api.clearToken(ifMatches: previousToken) }
        Keychain.delete("token")
        UserDefaults.standard.removeObject(forKey: "vocab_profile")
        credentialSaveFailed = false
        placementSet = nil   // 切账号清空定级题缓存
        S = LearningState()
        route = .welcome
        return true
    }

    func logout() async {
        guard let current = auth else { return }
        let generation = routeGeneration
        commitUndoReview()
        await pushNow()
        guard auth == current, routeGeneration == generation else { return }
        guard syncMsg == "✓ 已同步" else {
            if !localSaveFailed { syncMsg += "；本机进度已保留，可重试或选择切换账号" }
            return
        }
        await api.logout(expectedToken: current.token)
        guard auth == current else { return }
        guard switchAccount() else { return }
        if let g = loadLocal(slot: "guest") {
            S = g
            UserDefaults.standard.set(true, forKey: "vocab_guest")
            route = .home
        }
    }

    // MARK: 学习/复习评分写卡（FSRS 服务端 + 阶梯兜底）

    /// 该词上一次学习/复习日期（从日志推导，含历史老卡），用于 FSRS 计算真实经过天数
    private func lastReviewDate(_ word: String) -> String? {
        S.lastStudyDay(for: word)
    }

    /// 对同一张卡按原始发生时间重算；只有全部成功才替换卡片，失败保留完整队列。
    private func replayPendingFsrs(word: String) async -> Bool {
        if let auth, auth.accountId == nil { return false }
        guard let pending = S.cards[word]?.pendingFsrs, !pending.events.isEmpty else { return true }
        let owner = slotKey, originalAuth = auth, token = auth?.token
        let result: FsrsResponse?
        var versions: [String: String] = [:]
        var configs: [String: FsrsSchedulerConfig] = [:]
        do {
            result = try await StudyEngine.replayFsrs(pending, onVersion: { versions[$0] = $1 }) { request in
                let response = try await self.api.fsrsReview(request, expectedToken: token, enforceSession: true)
                if let key = response.schedulerKey, let config = response.schedulerConfig { configs[key] = config }
                return response
            }
        } catch {
            guard slotKey == owner, auth == originalAuth else { return false }
            if error.localizedDescription.contains("FSRS 参数") || error.localizedDescription.contains("FSRS 算法") {
                fsrsReplayError = error.localizedDescription
            }
            return false
        }
        guard slotKey == owner, auth == originalAuth, var card = S.cards[word], card.pendingFsrs == pending,
              let result else { return false }
        for (key, config) in configs {
            if let existing = S.fsrsSchedulers?[key], existing != config {
                fsrsReplayError = "FSRS 参数备份冲突，请先导出进度"
                return false
            }
        }
        if !configs.isEmpty {
            var saved = S.fsrsSchedulers ?? [:]
            configs.forEach { saved[$0.key] = $0.value }
            S.fsrsSchedulers = saved
        }
        StudyEngine.applyFsrs(result, to: &card, today: DayUtil.today())
        var replayVersions = card.fsrsReplayVersions ?? [:]
        versions.forEach { replayVersions[$0.key] = $0.value }
        card.fsrsReplayVersions = replayVersions
        if var history = card.fsrsHistory {
            for index in history.events.indices {
                if let version = versions[history.events[index].id] { history.events[index].schedulerKey = version }
            }
            card.fsrsHistory = history
        }
        var applied = card.appliedFsrs ?? []
        for event in pending.events where !applied.contains(event.id) { applied.append(event.id) }
        card.appliedFsrs = applied
        card.pendingFsrs = nil
        S.cards[word] = card
        return true
    }

    private func scheduleFsrs(word: String, body: APIClient.FsrsIn, rating: Int) async {
        guard var card = S.cards[word] else { return }
        let owner = slotKey, originalAuth = auth
        if card.pendingFsrs == nil { card.pendingFsrs = PendingFsrs(base: body, events: []) }
        if card.fsrsHistory == nil { card.fsrsHistory = card.pendingFsrs; card.fsrsReplayVersions = [:] }
        let lastDate = (card.fsrsHistory?.events.last ?? card.pendingFsrs?.events.last)
            .flatMap { DayUtil.parseISO($0.at) } ?? .distantPast
        let eventDate = max(Date(), lastDate.addingTimeInterval(0.001))
        let event = PendingFsrsEvent(id: UUID().uuidString.lowercased(), rating: rating, at: DayUtil.isoString(eventDate))
        card.pendingFsrs?.events.append(event)
        card.fsrsHistory?.events.append(event)
        S.cards[word] = card
        saveLocal() // 请求之前保存待处理评分，进程中断后可重试。
        if !(await replayPendingFsrs(word: word)), slotKey == owner, auth == originalAuth, var current = S.cards[word],
           current.pendingFsrs?.events.contains(where: { $0.id == event.id }) == true {
            StudyEngine.ladderFallback(&current, rating: rating, today: DayUtil.today())
            S.cards[word] = current
        }
    }

    private func flushPendingFsrs() async {
        let owner = auth, slot = slotKey
        var changed = false
        for word in S.cards.keys.sorted() where S.cards[word]?.pendingFsrs != nil {
            let replayed = await replayPendingFsrs(word: word)
            guard auth == owner, slotKey == slot else { return }
            if !replayed { break }
            changed = true
        }
        if !S.cards.values.contains(where: { $0.pendingFsrs != nil }) { fsrsReplayError = "" }
        if changed { save() }
    }

    func learn(word: String, pos: Int, rating: Int, fromPending: Bool = false) async {
        let today = DayUtil.today()
        let lastReview = lastReviewDate(word)
        let c = S.cards[word] ?? CardState(stage: 1, due: DayUtil.addDays(today, 1) + "T12:00:00Z",
                                           lt: 0, pos: pos, fsrs: nil)
        let isNewCard = S.cards[word] == nil
        let body = StudyEngine.fsrsBody(for: S.cards[word], rating: rating, isNewCard: isNewCard, lastReview: lastReview)
        S.cards[word] = c
        // 只有真正完成学习才消耗待补学词/推进顺序游标；中途退出不丢词、不跳词。
        S.pendingNew.removeAll { $0.word == word }
        if !fromPending { S.pointer = max(S.pointer, pos + 1) }
        S.log.append(LogEntry(d: today, word: word, rating: rating, kind: "learn"))
        StudyEngine.recordKnowledge(&S, word: word, pos: pos, ok: rating != 1)
        // 水平追踪观测（v1.2）：不熟悉=强证据(resp 0, w1.0)；学会了=自评弱证据(resp 1, w0.5)
        observeLevel(pos: pos, known: rating != 1, weight: rating == 1 ? 1.0 : 0.5)
        await scheduleFsrs(word: word, body: body, rating: rating)
    }

    /// 水平观测（v1.2）：每次反馈都是对词汇量后验的一次带权观测
    func observeLevel(pos: Int, known: Bool, weight: Double, guess: Double = 0) {
        guard S.calibrated else { return }
        StudyEngine.posteriorUpdate(&S, rank: pos, resp: known ? 1 : 0, weight: weight, guess: guess)
    }

    func review(word: String, rating: Int, trackWeight: Double? = nil, allowUndo: Bool = false, acceptance: Bool = false) async {
        guard var c = S.cards[word] else { return }
        let preStab = c.fsrs?.stability ?? Double(c.stage.flatMap { StudyEngine.ladderInterval[$0] } ?? 0)   // v1.3：成熟度用答前稳定度
        let lastReview = lastReviewDate(word)   // 在写今日日志前取上一次记录
        let today = DayUtil.today()
        // 答错前快照（撤销用）：防止手滑误记「忘记」无法挽回
        if rating == 1 && allowUndo {
            undoSnapshot = (word: word, card: c, log: S.log, knowledge: S.knowledge, knowledgeEvidence: S.knowledgeEvidence,
                            posterior: S.posterior, posteriorHistory: S.posteriorHistory, probeCount: S.probeCount, track: S.track)
        } else {
            undoSnapshot = nil
        }
        S.log.append(LogEntry(d: today, word: word, rating: rating, kind: "review"))
        StudyEngine.recordKnowledge(&S, word: word, pos: c.pos ?? S.pointer, ok: rating != 1)
        let body = StudyEngine.fsrsBody(for: c, rating: rating, isNewCard: false, lastReview: lastReview)
        if rating == 1 { c.lt = 0 }
        // 只记录连续熟练次数，间隔和稳定度由 FSRS 计算。
        if rating == 4 {
            c.easyStreak = (c.easyStreak ?? 0) + 1
        } else {
            c.easyStreak = 0
        }
        S.cards[word] = c
        // 水平追踪观测（v1.3 权重修正，治"只升不降"）：
        //  - 忘记：曾通过的成熟卡（答前稳定度≥21天）是有力向下证据 w0.4；新卡遗忘 w0.2
        //  - 记得/困难/熟练：只有词排位高于当前估值才算向上证据（低于估值的成功无信息量），w0.15
        //  - 被动证据每日总权重封顶 1.5；验收测试（trackWeight 1.0）不受上限
        if let pos = S.cards[word]?.pos, S.calibrated {
            if let tw = trackWeight {
                observeLevel(pos: pos, known: rating != 1, weight: tw, guess: preStab >= 14 ? 0 : 0.25)
            } else {
                var tr = S.track ?? TrackState()
                if tr.dayWDay != today { tr.dayW = 0; tr.dayWDay = today }
                var w = 0.0
                var known = true
                if rating == 1 { w = preStab >= 21 ? 0.4 : 0.2; known = false }
                else if Double(pos) > StudyEngine.postMean(S) { w = 0.15 }
                if w > 0 && (tr.dayW ?? 0) + w <= 1.5 {
                    observeLevel(pos: pos, known: known, weight: w, guess: preStab >= 14 ? 0 : 0.25)
                    tr.dayW = (tr.dayW ?? 0) + w
                    S.track = tr
                }
            }
        }
        if acceptance {
            // The answer and its completion marker must be saved together before
            // the FSRS request suspends, even if the user leaves this screen.
            if S.quizProgressDay != today { S.quizProgressDay = today; S.quizCompleted = [] }
            if !(S.quizCompleted ?? []).contains(word) { S.quizCompleted?.append(word) }
            let learned = Set(S.log.filter { $0.d == today && $0.kind == "learn" }.map(\.word))
            if learned.isSubset(of: Set(S.quizCompleted ?? [])) { S.quizDay = today }
        }
        await scheduleFsrs(word: word, body: body, rating: rating)
    }

    /// 每天首次 buildQueue 时运行：T=后验均值。
    /// T 超前 pointer >500 且证据够硬(std<800) → pointer 跳到 T（中间词视为已会）；
    /// pointer 超前 T >500 且连续 2 天 → 减压（新词 5 个/天，不后退——已发词 FSRS 在管）。
    /// v1.3：评估前先做置信度扩散（每日一次）；级别变更须连续 3 天跨边界（滞回防抖）
    func trackLevelDaily() {
        guard S.calibrated, S.posterior != nil else { return }
        if var track = S.track, track.throttle == true {
            track.throttle = false; track.lowSince = nil
            if track.lastNote?.contains("新词临时降到") == true { track.lastNote = nil }
            S.track = track
        }
        let today = DayUtil.today()
        if S.track?.evalDay == today { return }   // 每日最多一次
        var track = S.track ?? TrackState()
        if track.diffuseDay != today {
            StudyEngine.diffusePosterior(&S)
            track.diffuseDay = today
        }
        let T = Int(StudyEngine.postMean(S).rounded())
        let std = StudyEngine.postStd(S)
        if Double(T - S.pointer) > 500 && std < 800 {
            track.lastNote = "连续表现超过当前级别，发词位置从 \(S.pointer) 追平到 ≈\(T)（\(levelDisplayName(levelForPos(T)))），中间词视为已会跳过"
            S.pointer = T
            track.lowSince = nil
            track.throttle = false
        } else {
            track.lowSince = nil
            track.throttle = false
        }
        // v1.3 级别滞回：后验均值跨边界须连续 3 天，才正式调整展示级别（防单日抖动）
        let band = levelForPos(max(1, T))
        if track.shownLevel == nil { track.shownLevel = levelForPos(max(1, S.pointer)) }
        if band != track.shownLevel {
            if track.pendingBand == band { track.pendingDays = (track.pendingDays ?? 0) + 1 }
            else { track.pendingBand = band; track.pendingDays = 1 }
            if (track.pendingDays ?? 0) >= 3 {
                track.shownLevel = band
                track.lastNote = "词汇水平连续 3 天稳定在「\(levelDisplayName(band))」区间，当前级别已调整"
                track.pendingBand = nil
                track.pendingDays = 0
            }
        } else {
            track.pendingBand = nil
            track.pendingDays = 0
        }
        track.evalDay = today
        S.track = track
        save()
    }

    /// v1.4 主动探测选词：上方近端反向回想 / 上方远端正向再认 / 下方正向回归检查
    private func pickProbes(reviewWords: [String], news: [NewWord], active: () -> Bool) async -> [(word: NewWord, reverse: Bool)] {
        guard S.calibrated, S.posterior != nil else { return [] }
        let today = DayUtil.today()
        // 每日总计 3 题：当天重建队列（继续复习/二次进入）不重复追加探测
        let already = S.log.filter { $0.kind == "probe" && $0.d == today }.count
        let need = 3 - already
        guard need > 0 else { return [] }
        let m = StudyEngine.postMean(S), sd = max(60, StudyEngine.postStd(S))
        let recentProbe = Set(S.log.filter { $0.kind == "probe" && $0.d >= DayUtil.addDays(today, -14) }.map(\.word))
        var busy = Set(reviewWords)
        news.forEach { busy.insert($0.word) }
        let zones: [(Double, Double, Bool)] = [
            (m + 0.5 * sd, m + 1.0 * sd, true),   // 上方近端：反向回想，检验是否真会而非眼熟
            (m + 1.5 * sd, m + 2.0 * sd, false),  // 上方远端：正向再认，探大幅进步
            (m - 1.0 * sd, m - 0.5 * sd, false),  // 下方：正向再认，高估回归检查
        ]
        var out: [(word: NewWord, reverse: Bool)] = []
        for (lo, hi, reverse) in zones {
            if out.count >= need { break }
            let a = max(1, Int(lo.rounded())), b = min(10991, Int(hi.rounded()))
            guard a <= b else { continue }
            for _ in 0..<6 {
                let pos = Int.random(in: a...b)
                let result = try? await api.lexiconAt(pos: pos, n: 1)
                guard active() else { return [] }
                guard let r = result, let w = r.words.first,
                      S.cards[w.word] == nil,
                      !recentProbe.contains(w.word),
                      !busy.contains(w.word),
                      !out.contains(where: { $0.word.word == w.word }),
                      !S.pendingNew.contains(where: { $0.word == w.word }) else { continue }
                out.append((word: w, reverse: reverse))
                break
            }
        }
        return out
    }

    /// v1.4 探测作答：全额证据；正向猜测率 0.25，反向回想为 0；答错 → 进明日新词候选
    func answerProbe(_ w: NewWord, ok: Bool, reverse: Bool) {
        StudyEngine.posteriorUpdate(&S, rank: w.pos, resp: ok ? 1 : 0, weight: 1.0, guess: reverse ? 0 : 0.25)
        S.log.append(LogEntry(d: DayUtil.today(), word: w.word, rating: ok ? 4 : 1, kind: "probe", reverse: reverse))
        if !ok, S.cards[w.word] == nil, !S.pendingNew.contains(where: { $0.word == w.word }) {
            S.pendingNew.append(NewWord(word: w.word, pos: w.pos))
        }
        save()
    }

    /// 例句曝光埋点：用于后续评估"薄弱词复现 → 3/7/30 天记忆效果"
    private func sentenceHash(_ text: String) -> String {
        var h: UInt32 = 2166136261
        for b in text.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return String(h, radix: 16)
    }

    func logExposure(word: String, source: String, text: String, played: Bool, score: Int? = nil) {
        S.log.append(LogEntry(d: DayUtil.today(), word: word, rating: 3, kind: "exposure",
                              ts: DayUtil.isoString(Date()), source: source,
                              sentenceId: sentenceHash(text), played: played, score: score))
        save()
    }

    func logSentenceExposures(_ text: String, source: String, played: Bool) {
        let lower = text.lowercased()
        for w in StudyEngine.recentWeakWords(S, today: DayUtil.today()) {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: w.lowercased()))\\b"
            if lower.range(of: pattern, options: .regularExpression) != nil {
                logExposure(word: w, source: source, text: text, played: played)
            }
        }
    }

    /// 跟读结果入档：完整度 <60 记薄弱（进薄弱词管线，当晚就定制例句），≥60 记一次影子练习
    /// 让跟读真正参与学习决策，而不是"白评了"
    func recordShadow(word: String, result: ShadowResult) {
        let rating = result.completeness < 60 ? 1 : 3
        S.log.append(LogEntry(d: DayUtil.today(), word: word, rating: rating, kind: "shadow"))
        logExposure(word: word, source: "shadow", text: word, played: true, score: result.completeness)
        save()
    }

    /// 顽固词特训：把 ≥2 次没记住的词单独组一队复习（不进新词，纯歼灭战）
    @discardableResult
    func startStubbornDrill() -> Int {
        let words = StudyEngine.stubbornDrillWords(S, day: DayUtil.today(), now: Date())
        guard !words.isEmpty else { return 0 }
        session = Session()
        session.queue = words.map { .review(word: $0) }
        route = .session
        return words.count
    }

    /// 已掌握词不再显示旧个性化例句
    func personalFor(_ word: String) -> PersonalizedSentence? {
        if let c = S.cards[word], StudyEngine.isMastered(c) { return nil }
        guard let sentence = S.personalized[word], !(S.rejectedPersonalized?[word] ?? []).contains(sentence.text) else { return nil }
        return sentence
    }

    func prunePersonalized() {
        let mastered = S.cards.compactMap { word, card in StudyEngine.isMastered(card) ? word : nil }
        let device = versionDevice()
        for word in mastered {
            if let text = S.personalized[word]?.text {
                if !StudyEngine.rejectPersonalSentence(&S, word: word, text: text, device: device) {
                    syncMsg = "例句版本无效，请先导出进度并重新加载"
                }
            }
        }
    }

    // MARK: 每日队列（到期复习 + 提前巩固概率池 + 新词）

    @discardableResult
    func buildQueue() async -> Bool {
        let owner = auth, slot = slotKey, generation = routeGeneration
        func active() -> Bool { auth == owner && slotKey == slot && routeGeneration == generation && !Task.isCancelled }
        await flushPendingFsrs()
        guard active() else { return false }
        await refreshPersonalJobs()
        guard active() else { return false }
        let now = Date()
        let cap = S.settings.dailyCap
        let completed = StudyEngine.completedDailyWords(S.log, day: DayUtil.today())
        let remaining = StudyEngine.remainingDailyCapacity(S.log, day: DayUtil.today(), cap: cap)

        let due = S.cards
            .filter { (!completed.contains($0.key) || [1, 3].contains($0.value.fsrs?.state ?? 0)) && !StudyEngine.isMastered($0.value) && (DayUtil.parseISO($0.value.due) ?? .distantFuture) <= now }
            .sorted { (DayUtil.parseISO($0.value.due) ?? .distantFuture) < (DayUtil.parseISO($1.value.due) ?? .distantFuture) }
            .map { $0.key }
        // 提前巩固位：1~7 天前碰过、FSRS 未到期、未掌握，P=(1−R)×0.5，≤5 个
        let earlyPool = S.cards.filter { pair in
            let (w, c) = pair
            guard !completed.contains(w) else { return false }
            guard !StudyEngine.isMastered(c), let dueD = DayUtil.parseISO(c.due), dueD > now else { return false }
            guard let last = lastReviewDate(w) else { return false }
            guard let lastD = DayUtil.localNoon(last) else { return false }
            let elapsed = now.timeIntervalSince(lastD) / 86400
            guard elapsed >= 1, elapsed <= 7 else { return false }
            let r = StudyEngine.retrievability(c, elapsedDays: elapsed)
            return Double.random(in: 0..<1) < (1 - r) * 0.5
        }.map { $0.key }
        // 新词：pendingNew 优先，然后按 pointer 顺序取
        // 先为用户设置的新词目标留位；词库不足时剩余容量交给复习。
        trackLevelDaily()
        let newPerDay = S.settings.newPerDay
        let learnedToday = Set(S.log.filter { $0.kind == "learn" && $0.d == DayUtil.today() }.map(\.word)).count
        let nNew = min(max(0, newPerDay - learnedToday), remaining)
        var news: [NewWord] = []
        // 只清理已经入卡的旧待学项；本次选中但未学完的词必须留在 pendingNew。
        S.pendingNew = S.pendingNew.filter { S.cards[$0.word] == nil }
        for w in S.pendingNew where news.count < nNew {
            if !completed.contains(w.word) && !news.contains(where: { $0.word == w.word }) {
                var pending = w
                pending.fromPending = true
                news.append(pending)
            }
        }
        var cursor = S.pointer
        var exhausted = false
        var scanBatch = min(30, nNew + 2)
        while news.count < nNew && !exhausted {
            let want = min(30, max(scanBatch, nNew - news.count + 2))
            let result = try? await api.lexiconAt(pos: cursor, n: want)
            guard active(), let r = result else { return false }
            for w in r.words {
                if news.count >= nNew { break }
                if !completed.contains(w.word) && S.cards[w.word] == nil && !news.contains(where: { $0.word == w.word }) {
                    news.append(w)
                }
            }
            if r.exhausted == true { exhausted = true; break }
            // Older servers omit the scan cursor. Their empty response does not
            // prove exhaustion, so preserve the current queue and report failure.
            let next = r.nextPos ?? r.words.map(\.pos).max().map { $0 + 1 }
            guard let next, next > cursor else { return false }
            cursor = next
            scanBatch = min(30, scanBatch * 2)
        }
        // 统一按词形补全详情：不能按可能已过期的位置猜词，更不能把别的词释义填进来。
        for i in news.indices where !(news[i].senses ?? []).contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) &&
            (news[i].sense ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let result = try? await api.lexiconWord(news[i].word)
            guard active() else { return false }
            if let full = result, full.word.caseInsensitiveCompare(news[i].word) == .orderedSame {
                let pending = news[i].fromPending
                news[i] = full
                news[i].fromPending = pending
            }
        }
        guard news.count == nNew || exhausted else { return false }   // 仅服务端明确词库结束时允许不足额
        let repeats = due.filter { completed.contains($0) }
        let freshDue = due.filter { !completed.contains($0) }
        let reviews = repeats + freshDue.prefix(max(0, remaining - news.count))
        let reviewSet = Set(reviews)
        let early = earlyPool.filter { !reviewSet.contains($0) }
            .prefix(min(5, max(0, remaining - news.count - reviews.count)))
        let reviewsAll = reviews + early
        // 跳段复核：发生过跳位（pointer 已显著领先定级边界）时，每天从跳过区间随机抽 1 个词
        // 顶替 1 个新词位——给"视为已会"的跳过词一次被抓住的机会。
        // 答对就过（确认真会），答错它会正常进卡片复习，同时水平后验自动回落纠偏。
        if nNew > 0, news.count == nNew, S.pointer - S.frontier > 200 {
            for _ in 0..<6 {   // 最多试 6 个随机位置，避开已入卡的词
                let randPos = Int.random(in: S.frontier..<S.pointer)
                let result = try? await api.lexiconAt(pos: randPos, n: 1)
                guard active() else { return false }
                guard let r = result, let w = r.words.first,
                      S.cards[w.word] == nil,
                      !completed.contains(w.word),
                      !news.contains(where: { $0.word == w.word }) else { continue }
                news[news.count - 1] = w
                break
            }
        }

        // v1.3 每日主动探测：3 个探测词（2 个后验上方区 / 1 个下方区）随机混入复习段，
        // 4选1 形式与复习测验无差别——用户无感知，证据全额（与定级同级 weight 1.0）
        let probeBudget = max(0, remaining - reviewsAll.count - news.count)
        let probes = probeBudget > 0 ? Array((await pickProbes(reviewWords: reviewsAll, news: news, active: active)).prefix(probeBudget)) : []
        guard active() else { return false }
        var revBlock: [Session.Item] = reviewsAll.map { .review(word: $0) }
        for p in probes {
            let at = Int.random(in: 0...revBlock.count)
            revBlock.insert(.probe(word: p.word, reverse: p.reverse), at: at)
        }

        session = Session()
        session.queue = revBlock + news.map { .learn(word: $0) }
        save()
        prefetchDay(news: news, reviewWords: reviewsAll)
        return true
    }

    /// 队列确定后立即后台预生成三句套装 + TTS 预热（不等翻卡）
    private func prefetchDay(news: [NewWord], reviewWords: [String]) {
        let weak = StudyEngine.recentWeakWords(S, today: DayUtil.today()).prefix(15).joined(separator: ",")
        let api = self.api
        let cap = S.pointer + 10
        let voice = S.settings.voice
        Logger.app.info("prefetchDay: \(news.count) 新词, weak=\(weak, privacy: .public)")
        Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: (String, TrioResponse?, String?).self) { group in
                for w in news {
                    group.addTask {
                        do {
                            let r = try await api.trio(word: w.word, weak: weak, cap: cap)
                            return (w.word, r, nil)
                        } catch {
                            return (w.word, nil, String(describing: error))
                        }
                    }
                }
                var texts: [String] = reviewWords.prefix(15).map { $0 }
                for await (word, r, err) in group {
                    if let err { Logger.app.error("trio 失败 \(word, privacy: .public): \(err, privacy: .public)") }
                    if let sents = r?.sentences, !sents.isEmpty {
                        if let i = self.session.queue.firstIndex(where: {
                            if case .learn(let nw) = $0 { return nw.word == word } else { return false }
                        }), case .learn(var nw) = self.session.queue[i] {
                            nw.sentences = sents
                            self.session.queue[i] = .learn(word: nw)
                        }
                        texts.append(word)
                        texts.append(contentsOf: sents.map { $0.text })
                    }
                }
                await api.warmTTS(Array(texts.prefix(80)), voice: voice)
            }
        }
    }

    // MARK: 当日完成与自动个性化

    func markDayDone() {
        let today = DayUtil.today()
        if StudyEngine.hasStudyActivity(S.log, day: today) {
            StudyEngine.recordStudyDay(&S, day: today)
        }
        // 注意：不在这里设 quizDay——只有验收测试真正跑完才能标记（与 web 一致），
        // 否则同一天二次学习的新词会永远错过验收。
        prunePersonalized()
        save()
    }

    /// 今日稍后到期且尚未计入当日学习上限的单词。
    func dueLaterTodayCount(onlyCompleted: Bool = false) -> Int {
        let now = Date()
        let calendar = Calendar.current
        let eod = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let completed = StudyEngine.completedDailyWords(S.log, day: DayUtil.today())
        return S.cards.filter { word, card in
            guard (!onlyCompleted || completed.contains(word)), (!completed.contains(word) || [1, 3].contains(card.fsrs?.state ?? 0)), !StudyEngine.isMastered(card), let d = DayUtil.parseISO(card.due), d > now else { return false }
            return d < eod
        }.count
    }

    private var personalRefreshRunning = false

    /// 重新提交相同幂等键并拉取任务状态；进程重启和网络失败后可安全重试。
    func refreshPersonalJobs() async {
        if let auth, auth.accountId == nil { return }
        guard !personalRefreshRunning else { return }
        personalRefreshRunning = true
        defer { personalRefreshRunning = false }
        let owner = deviceId(), slot = slotKey, token = auth?.token
        let jobs = S.personalJobs ?? []
        var changed = false
        for job in jobs where job.owner == owner && !["complete", "partial", "failed", "superseded"].contains(job.status) {
            do {
                _ = try await api.personalize(.init(device: owner, date: job.date, weak_words: job.weakWords,
                    learned_max_pos: job.learnedMaxPos, sync: true, replace: job.replace, request_id: job.id), expectedToken: token, enforceSession: true)
                let result = try await api.personalizedJob(id: job.id, device: owner, expectedToken: token, enforceSession: true)
                guard deviceId() == owner, slotKey == slot, let index = S.personalJobs?.firstIndex(where: { $0.id == job.id && $0.owner == owner }) else { return }
                if S.personalJobs?[index].status != result.status {
                    S.personalJobs?[index].status = result.status
                    changed = true
                }
                if result.status != "superseded" {
                    for row in result.sentences {
                        if (S.rejectedPersonalized?[row.target] ?? []).contains(row.text) { continue }
                        if let card = S.cards[row.target], StudyEngine.isMastered(card) { continue }
                        if (S.personalJobs ?? []).contains(where: { newer in
                            newer.owner == owner && newer.date > job.date && newer.weakWords.contains(row.target)
                                && !["failed", "superseded"].contains(newer.status)
                        }) { continue }
                        if StudyEngine.applyPersonalJobResult(&S, job: job, row: row) { changed = true }
                    }
                }
                if result.status == "complete" && job.replace {
                    S.personalizedDay = job.date
                    S.personalizedWeak = job.weakKey
                    changed = true
                }
            } catch {
                // 旧游客任务可能属于无法验证的旧命名空间；保留记录，允许用户重新生成。
                if token == nil, (error as? APIError)?.statusCode == 409, deviceId() == owner, slotKey == slot,
                   let index = S.personalJobs?.firstIndex(where: { $0.id == job.id && $0.owner == owner }) {
                    S.personalJobs?[index].status = "failed"
                    changed = true
                }
            }
        }
        if changed && deviceId() == owner && slotKey == slot { save() }
    }

    /// 生成任务在提交前保存，完成后按任务 ID 取回全部结果。
    func autoPersonalize(onStatus: @escaping (String) -> Void,
                         onRows: (([PersonalizedOut.Row]) -> Void)? = nil) async {
        if let auth, auth.accountId == nil { onStatus("请重新登录并核对旧存档"); return }
        let date = DayUtil.today(), owner = deviceId(), slot = slotKey
        let weakToday = StudyEngine.recentWeakWords(S, today: date)
            .filter { w in S.log.contains(where: { $0.d == date && $0.word == w && $0.rating <= 2 }) }
        let weakKey = weakToday.sorted().joined(separator: ",")
        guard !weakToday.isEmpty else {
            S.personalizedDay = date; S.personalizedWeak = ""; save()
            onStatus("今天没有薄弱词，无需定制")
            return
        }
        var job = S.personalJobs?.reversed().first(where: {
            $0.replace && $0.owner == owner && $0.date == date && $0.weakKey == weakKey &&
            !["partial", "failed", "superseded"].contains($0.status)
        })
        if job == nil {
            let words = Array(weakToday.prefix(15))
            guard let versions = StudyEngine.reservePersonalVersions(S, words: words, device: versionDevice()) else {
                onStatus("例句版本无效，请先导出进度并重新加载"); return
            }
            let created = PersonalJob(id: UUID().uuidString.lowercased(), date: date, weakKey: weakKey,
                weakWords: words, learnedMaxPos: min(12000, S.pointer + 10),
                replace: true, owner: owner, status: "queued", personalVersions: versions)
            if S.personalJobs == nil { S.personalJobs = [] }
            S.personalJobs?.append(created)
            if let jobs = S.personalJobs, jobs.count > 100 { S.personalJobs = Array(jobs.suffix(100)) }
            save()
            job = created
        }
        guard let job else { return }
        for _ in 0..<10 {
            onStatus("正在为薄弱词定制例句…")
            await refreshPersonalJobs()
            guard deviceId() == owner, slotKey == slot, !Task.isCancelled else { return }
            let state = S.personalJobs?.first(where: { $0.id == job.id })?.status
            if state == "complete" {
                let rows = weakToday.compactMap { word -> PersonalizedOut.Row? in
                    guard let p = personalFor(word) else { return nil }
                    return PersonalizedOut.Row(target: word, recall: p.recall, text: p.text, zh: p.zh)
                }
                onStatus("✓ 薄弱词例句已就绪")
                if !rows.isEmpty { onRows?(rows) }
                return
            }
            if let state, ["partial", "failed", "superseded"].contains(state) {
                onStatus("部分例句暂不可用，可稍后重新进入完成页重试；现有例句仍可使用。")
                return
            }
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
        }
        onStatus("生成任务仍在处理中，稍后回到主页会继续取回结果。")
    }

    // MARK: 织入巩固句（新词卡 40% 概率、每天 ≤3 次）

    func maybeWeave(for word: String) async -> (text: String, zh: String?, weak: String)? {
        if let auth, auth.accountId == nil { return nil }
        let today = DayUtil.today(), slot = slotKey, token = auth?.token
        if S.weaveDay != today { S.weaveDay = today; S.weaveCount = 0 }
        let pool = StudyEngine.recentWeakWords(S, today: today)
            .filter { $0 != word }
        guard !pool.isEmpty, S.weaveCount < 3, Double.random(in: 0..<1) < 0.4 else { return nil }
        let weakW = pool.randomElement()!
        S.weaveCount += 1
        save()
        guard let r = try? await api.weave(word: word, weak: weakW, cap: S.pointer + 10,
                                           device: deviceId(), expectedToken: token, enforceSession: true),
              !r.text.isEmpty, !(S.rejectedPersonalized?[word] ?? []).contains(r.text), slotKey == slot else { return nil }
        await api.warmTTS([r.text], voice: S.settings.voice)
        guard slotKey == slot else { return nil }
        return (r.text, r.zh, weakW)
    }

    // MARK: ↻ 换一句

    func swapSentence(word: String, oldText: String, kind: String, tier: Int = 1, displayedSentences: [String] = []) async -> SentenceItem? {
        let slot = slotKey, token = auth?.token
        do {
            if kind == "static" {
                try await api.report(word: word, text: oldText, device: deviceId(), expectedToken: token, enforceSession: true)
                let r = try await api.alternatives(word: word, tier: (1...3).contains(tier) ? tier : 1)
                guard slotKey == slot else { return nil }
                if r.word.lowercased() == word.lowercased(),
                   let fresh = r.sentences.firstAlternative(excluding: displayedSentences + [oldText]) {
                    return fresh
                }
                return nil
            } else {
                let device = versionDevice()
                guard StudyEngine.rejectPersonalSentence(&S, word: word, text: oldText, device: device) else {
                    syncMsg = "例句版本无效，请先导出进度并重新加载"; return nil
                }
                guard let versions = StudyEngine.reservePersonalVersions(S, words: [word], device: device) else {
                    save(); syncMsg = "例句版本无效，请先导出进度并重新加载"; return nil
                }
                let owner = deviceId()
                let job = PersonalJob(id: UUID().uuidString.lowercased(), date: DayUtil.today(), weakKey: word,
                    weakWords: [word], learnedMaxPos: min(12000, S.pointer + 10), replace: false, owner: owner, status: "queued", personalVersions: versions)
                if S.personalJobs == nil { S.personalJobs = [] }
                S.personalJobs?.append(job)
                if let jobs = S.personalJobs, jobs.count > 100 { S.personalJobs = Array(jobs.suffix(100)) }
                save()
                for _ in 0..<8 {
                    await refreshPersonalJobs()
                    guard deviceId() == owner, slotKey == slot, !Task.isCancelled else { return nil }
                    if let s = personalFor(word), s.text != oldText {
                        return SentenceItem(tier: nil, text: s.text, zh: s.zh)
                    }
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return nil }
                }
                return nil
            }
        } catch {
            return nil
        }
    }
}
