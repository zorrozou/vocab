import Foundation

// The scheduler only needs the API request value type for this standalone test.
enum APIClient {
    struct FsrsIn: Codable, Equatable {
        var is_new: Bool = false
        var state: Int = 1
        var stability: Double = 0
        var difficulty: Double = 0
        var due: String? = nil
        var rating: Int = 3
        var step: Int? = nil
        var last_review: String? = nil
        var legacy_last_review_day: String? = nil
        var now: String? = nil
        var deterministic: Bool? = nil
        var scheduler_key: String? = nil
    }
}

@main
struct FsrsCodingCheck {
    static func main() async throws {
        var drill = LearningState()
        drill.cards = ["apple": CardState(stage: 1, due: nil, lt: 0, pos: 1, fsrs: nil),
                       "banana": CardState(stage: 1, due: nil, lt: 0, pos: 2, fsrs: nil)]
        drill.log = [LogEntry(d: "2026-10-29", word: "apple", rating: 1, kind: "learn"),
                     LogEntry(d: "2026-10-29", word: "apple", rating: 2, kind: "review"),
                     LogEntry(d: "2026-10-29", word: "banana", rating: 1, kind: "placement"),
                     LogEntry(d: "2026-10-29", word: "banana", rating: 1, kind: "shadow")]
        precondition(StudyEngine.stubbornWords(drill).map(\.0) == ["apple"])
        drill.log.append(contentsOf: [LogEntry(d:"2026-10-28",word:"banana",rating:1,kind:"review"),
                                      LogEntry(d:"2026-10-28",word:"banana",rating:1,kind:"review")])
        drill.settings.dailyCap = 1; drill.settings.newPerDay = 0
        precondition(StudyEngine.stubbornDrillWords(drill, day:"2026-10-29", now:Date()) == ["apple"], "drill must not exceed the daily cap")
        drill.settings.dailyCap = 2; drill.settings.newPerDay = 2
        precondition(StudyEngine.stubbornDrillWords(drill, day:"2026-10-29", now:Date()) == ["apple"], "drill must reserve remaining capacity for new words")
        precondition(LocalAccountSlot.name(userId: 7, username: "Alice") == LocalAccountSlot.name(userId: 7, username: "alice"))
        precondition(LocalAccountSlot.name(userId: 7, username: "alice") != LocalAccountSlot.name(userId: 7, username: "bob"))
        let firstIdentity = String(repeating: "a", count: 32), secondIdentity = String(repeating: "b", count: 32)
        precondition(LocalAccountSlot.validAccountID(firstIdentity) && !LocalAccountSlot.validAccountID("../bad"))
        precondition(LocalAccountSlot.name(userId: 7, username: "alice", accountId: firstIdentity) != LocalAccountSlot.name(userId: 7, username: "alice", accountId: secondIdentity))
        let profile = try JSONDecoder().decode(AuthUser.self, from: Data("{\"id\":7,\"username\":\"alice\",\"nickname\":\"Alice\",\"account_id\":\"\(firstIdentity)\"}".utf8))
        let legacyProfile = try JSONDecoder().decode(AuthUser.self, from: Data("{\"id\":7,\"username\":\"alice\",\"nickname\":\"Alice\"}".utf8))
        precondition(profile.account_id == firstIdentity && legacyProfile.account_id == nil)
        let currentStateResponse = try JSONDecoder().decode(StateResponse.self, from: Data("{\"state\":null,\"state_revision\":\"9007199254740993\",\"sync_generation\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}".utf8))
        let oldStateResponse = try JSONDecoder().decode(StateResponse.self, from: Data("{\"state\":null}".utf8))
        precondition(currentStateResponse.state_revision == "9007199254740993" && currentStateResponse.sync_generation == firstIdentity)
        precondition(oldStateResponse.state_revision == nil && oldStateResponse.sync_generation == nil)
        var backupState = LearningState()
        let backupKey = String(repeating: "a", count: 64)
        var backupCard = CardState(stage: nil, due: nil, lt: nil, pos: 1, fsrs: nil)
        backupCard.fsrsHistory = PendingFsrs(base: .init(), events: [PendingFsrsEvent(id: "recorded", rating: 3, at: "2026-10-27T00:00:00Z", schedulerKey: backupKey), PendingFsrsEvent(id: "legacy", rating: 2, at: "2026-10-27T00:00:01Z")])
        backupCard.appliedFsrs = ["recorded", "legacy"]
        backupState.cards["apple"] = backupCard
        precondition(StudyEngine.missingBackupSchedulers(backupState) == [backupKey])
        precondition(StudyEngine.incompleteLegacyFsrsBackup(backupState))
        var groupedBackup = backupState
        groupedBackup.cards["apple"]?.fsrsHistory?.schedulerKey = backupKey
        groupedBackup.cards["apple"]?.fsrsHistory?.events[1].schedulerKey = ""
        precondition(!StudyEngine.incompleteLegacyFsrsBackup(groupedBackup))
        backupState.fsrsSchedulers = [backupKey: FsrsSchedulerConfig(library: "test", parameters: [], desired_retention: 0.9, learning_steps: [], relearning_steps: [], maximum_interval: 365)]
        precondition(StudyEngine.missingBackupSchedulers(backupState).isEmpty)
        backupState.fsrsSchedulers?[backupKey]?.desired_retention = 2
        precondition(StudyEngine.missingBackupSchedulers(backupState) == [backupKey])
        let positiveZero = FsrsSchedulerConfig(library: "test", parameters: [0], desired_retention: 0.9, learning_steps: [], relearning_steps: [], maximum_interval: 365)
        var negativeZero = positiveZero
        negativeZero.parameters = [-0.0]
        backupState.fsrsSchedulers?[backupKey] = negativeZero
        precondition(StudyEngine.missingBackupSchedulers(backupState) == [backupKey])
        precondition(!StudyEngine.identicalBackupScheduler(positiveZero, negativeZero))
        var longLibrary = positiveZero
        longLibrary.library = String(repeating: "e\u{301}", count: 40)
        backupState.fsrsSchedulers?[backupKey] = longLibrary
        precondition(StudyEngine.missingBackupSchedulers(backupState) == [backupKey])
        precondition(!StudyEngine.hasStudyActivity([], day: "2026-10-27"))
        precondition(!StudyEngine.hasStudyActivity([LogEntry(d: "2026-10-27", word: "apple", rating: 3, kind: "exposure", source: "personal")], day: "2026-10-27"))
        precondition(StudyEngine.hasStudyActivity([LogEntry(d: "2026-10-27", word: "apple", rating: 3, kind: "review")], day: "2026-10-27"))
        var calendarState = LearningState()
        StudyEngine.recordStudyDay(&calendarState, day: "2026-10-26")
        StudyEngine.recordStudyDay(&calendarState, day: "2026-10-27")
        StudyEngine.recordStudyDay(&calendarState, day: "2026-10-27")
        precondition(calendarState.streak == 2 && calendarState.streakEvidence?.days.count == 2)
        let calendarRoundTrip = try JSONDecoder().decode(LearningState.self, from: JSONEncoder().encode(calendarState))
        precondition(calendarRoundTrip == calendarState)
        // Web's legacy date-only due values mean midnight UTC, independent of
        // the device timezone. They must be due on iOS at the same instant.
        let legacyDue = DayUtil.parseISO("2026-10-28")!
        precondition(legacyDue == DayUtil.parseISO("2026-10-28T00:00:00Z"))
        precondition(DayUtil.parseISO("2024-02-29") != nil && DayUtil.parseISO("2026-02-29") == nil)
        precondition(DayUtil.parseISO("2026-13-01") == nil && DayUtil.parseISO("2026-2-01") == nil)
        var legacyQueue = LearningState()
        legacyQueue.cards["apple"] = CardState(stage: 2, due: "2026-10-28", lt: 0, pos: 1, fsrs: nil)
        let legacyCopy = try JSONDecoder().decode(LearningState.self, from: JSONEncoder().encode(legacyQueue))
        precondition(legacyCopy.cards["apple"]?.due == "2026-10-28")
        precondition(StudyEngine.dailyPlanSummary(legacyCopy, day: "2026-10-28", now: legacyDue.addingTimeInterval(-1)).dueAvailable == 0)
        precondition(StudyEngine.dailyPlanSummary(legacyCopy, day: "2026-10-28", now: legacyDue).dueAvailable == 1)
        let forecastCards: [String: CardState] = [
            "a": CardState(stage: 1, due: "2026-03-08T07:30:00Z", lt: 0, pos: 1, fsrs: nil),
            "b": CardState(stage: 1, due: "2026-03-09T00:30:00Z", lt: 0, pos: 2, fsrs: nil),
            "c": CardState(stage: 1, due: "2026-03-08", lt: 0, pos: 3, fsrs: nil),
            "d": CardState(stage: 1, due: "2026-03-08T23:00:00-08:00", lt: 0, pos: 4, fsrs: nil),
            "invalid": CardState(stage: 1, due: "2026-02-29", lt: 0, pos: 5, fsrs: nil),
            "later": CardState(stage: 1, due: "2026-04-01", lt: 0, pos: 6, fsrs: nil)]
        let forecast = StudyEngine.forecastDueDates(forecastCards, day: "2026-03-08")
        precondition(forecast.count == 14 && forecast[1].0 == "2026-03-09")
        if TimeZone.current.identifier == "Pacific/Kiritimati" { precondition(forecast[0].1 == 2 && forecast[1].1 == 2) }
        if TimeZone.current.identifier == "America/Los_Angeles" { precondition(forecast[0].1 == 3 && forecast[1].1 == 1) }
        precondition(forecast.map(\.1).reduce(0, +) == 4)
        func retentionCard(_ stability: Double, _ last: String?) -> CardState {
            CardState(stage: 2, due: nil, lt: 0, pos: 1,
                      fsrs: FsrsState(state: 2, stability: stability, difficulty: 5, due: nil, scheduled_days: nil, step: nil, lastReview: last))
        }
        var pendingRetention = retentionCard(10, "2026-10-08T12:00:00Z")
        pendingRetention.pendingFsrs = PendingFsrs(base: APIClient.FsrsIn(), events: [PendingFsrsEvent(id: "test", rating: 3, at: "2026-10-27T12:00:00Z")])
        let retentionCards = ["exact":retentionCard(10, "2026-10-08T12:00:00Z"), "legacy":retentionCard(10, nil),
            "small":retentionCard(0.1, "2026-10-27T12:00:00Z"), "missing":retentionCard(10, nil),
            "future":retentionCard(10, "2026-10-29T12:00:00Z"), "invalid":retentionCard(10, "2026-02-29T12:00:00Z"),
            "pending":pendingRetention, "untracked":CardState(stage: 1, due: nil, lt: 0, pos: 1, fsrs: nil)]
        let retentionLog = [LogEntry(d: "2026-10-08", word: "legacy", rating: 3, kind: "review"),
            LogEntry(d: "2026-10-05", word: "legacy", rating: 3, kind: "learn"),
            LogEntry(d: "2026-10-28", word: "legacy", rating: 3, kind: "exposure")]
        let retention = StudyEngine.retentionSummary(retentionCards, log: retentionLog, now: DayUtil.parseISO("2026-10-28T12:00:00Z")!)
        precondition(retention.counts == [0, 0, 2, 1, 0] && retention.approximate == 3 && retention.unknown == 5)
        var backfill = LearningState()
        backfill.lastDay = "2026-10-25"; backfill.streak = 4
        StudyEngine.recordStudyDay(&backfill, day: "2026-10-24")
        precondition(backfill.streak == 4)
        StudyEngine.recordStudyDay(&backfill, day: "2026-10-20")
        precondition(backfill.streak == 4)
        StudyEngine.recordStudyDay(&backfill, day: "2026-10-21")
        precondition(backfill.streak == 6)
        StudyEngine.recordStudyDay(&backfill, day: "2026-10-26")
        precondition(backfill.streak == 7 && backfill.lastDay == "2026-10-26")
        var evidenceState = LearningState()
        evidenceState.knowledge = ["apple": KnowledgeStat(a: 2, b: 1, pos: 7)]
        StudyEngine.recordKnowledge(&evidenceState, word: "apple", pos: 7, ok: true)
        StudyEngine.recordKnowledge(&evidenceState, word: "apple", pos: 7, ok: false)
        let evidenceRoundTrip = try JSONDecoder().decode(LearningState.self, from: JSONEncoder().encode(evidenceState))
        precondition(evidenceRoundTrip.knowledge?["apple"]?.a == 3 && evidenceRoundTrip.knowledge?["apple"]?.b == 2)
        precondition(evidenceRoundTrip.knowledgeEvidence?["apple"]?.base.a == 2 && evidenceRoundTrip.knowledgeEvidence?["apple"]?.events.count == 2)
        var placementState = LearningState()
        StudyEngine.recordKnowledge(&placementState, word: "apple", pos: 7, ok: true, isPlacement: true)
        let placementRoundTrip = try JSONDecoder().decode(LearningState.self, from: JSONEncoder().encode(placementState))
        let placementId = placementRoundTrip.knowledgeEvidence?["apple"]?.events.keys.first
        precondition(placementId != nil && placementRoundTrip.bandEvidence?["0"]?.events[placementId!] == placementRoundTrip.knowledgeEvidence?["apple"]?.events[placementId!])
        let resetVersion = StudyEngine.nextPlacementVersion(nil, device: "device-a", id: "aaaaaaaa-1111")!
        let nextReset = StudyEngine.nextPlacementVersion(resetVersion, device: "device-a", id: "bbbbbbbb-2222")!
        precondition(resetVersion.counter == 1 && nextReset.counter == 2 && resetVersion.id != nextReset.id)
        placementState.placementVersion = nextReset
        let resetRoundTrip = try JSONDecoder().decode(LearningState.self, from: JSONEncoder().encode(placementState))
        precondition(resetRoundTrip.placementVersion == nextReset)
        precondition(StudyEngine.nextPlacementVersion(PlacementVersion(counter: 9_007_199_254_740_991, device: "a", id: "aaaaaaaa"), device: "a", id: "bbbbbbbb") == nil)
        var versionedState = LearningState()
        versionedState.settings.newPerDay = 20
        versionedState.settingsVersions = ["newPerDay": SettingVersion(counter: 2, device: "device-a")]
        let settingsRoundTrip = try JSONDecoder().decode(LearningState.self, from: JSONEncoder().encode(versionedState))
        precondition(settingsRoundTrip.settings.newPerDay == 20 && settingsRoundTrip.settingsVersions == versionedState.settingsVersions)
        var personalState = LearningState()
        personalState.personalized["apple"] = PersonalizedSentence(text: "Old sentence", recall: nil, zh: nil)
        StudyEngine.rejectPersonalSentence(&personalState, word: "apple", text: "Other sentence", device: "device-a")
        precondition(personalState.personalized["apple"]?.text == "Old sentence")
        StudyEngine.rejectPersonalSentence(&personalState, word: "apple", text: "Old sentence", device: "device-a")
        StudyEngine.rejectPersonalSentence(&personalState, word: "apple", text: "Old sentence", device: "device-a")
        let personalRoundTrip = try JSONDecoder().decode(LearningState.self, from: JSONEncoder().encode(personalState))
        precondition(personalRoundTrip.personalized["apple"] == nil && personalRoundTrip.rejectedPersonalized?["apple"] == ["Other sentence", "Old sentence"])
        let firstJobVersion = StudyEngine.reservePersonalVersions(personalState, words: ["apple"], device: "device-a")!
        let firstJob = PersonalJob(id: "first-job", date: "2026-10-27", weakKey: "apple", weakWords: ["apple"], learnedMaxPos: 300, replace: false, owner: "u7", status: "queued", personalVersions: firstJobVersion)
        personalState.personalJobs = [firstJob]
        let laterJobVersion = StudyEngine.reservePersonalVersions(personalState, words: ["apple"], device: "device-a")!
        let laterJob = PersonalJob(id: "later-job", date: "2026-10-27", weakKey: "apple", weakWords: ["apple"], learnedMaxPos: 300, replace: false, owner: "u7", status: "queued", personalVersions: laterJobVersion)
        personalState.personalJobs?.append(laterJob)
        let firstRow = PersonalizedOut.Row(target: "apple", recall: nil, text: "Earlier result", zh: nil)
        let laterRow = PersonalizedOut.Row(target: "apple", recall: nil, text: "Later result", zh: nil)
        precondition(!StudyEngine.applyPersonalJobResult(&personalState, job: firstJob, row: firstRow))
        precondition(StudyEngine.applyPersonalJobResult(&personalState, job: laterJob, row: laterRow))
        precondition(personalState.personalized["apple"]?.text == "Later result")
        precondition(StudyEngine.rejectPersonalSentence(&personalState, word: "apple", text: "Later result", device: "device-a"))
        precondition(!StudyEngine.applyPersonalJobResult(&personalState, job: laterJob, row: firstRow))
        let day = "2026-10-27"
        let loadLog = [LogEntry(d: day, word: "apple", rating: 3, kind: "learn"),
                       LogEntry(d: day, word: "apple", rating: 1, kind: "review"),
                       LogEntry(d: day, word: "banana", rating: 4, kind: "probe"),
                       LogEntry(d: day, word: "noise", rating: 3, kind: "exposure")]
        precondition(StudyEngine.completedDailyWords(loadLog, day: day) == Set(["apple", "banana"]))
        precondition(StudyEngine.remainingDailyCapacity(loadLog, day: day, cap: 3) == 1)
        precondition(StudyEngine.remainingDailyCapacity(loadLog, day: day, cap: 1) == 0)
        precondition(StudyEngine.remainingDailyCapacity(loadLog, day: "2026-10-28", cap: 3) == 3)
        var planState = LearningState()
        planState.settings.dailyCap = 4; planState.settings.newPerDay = 5
        planState.log = loadLog + [LogEntry(d: day, word: "ignored-placement", rating: 1, kind: "placement")]
        planState.cards = ["apple": CardState(stage: 1, due: "2000-01-01T00:00:00Z", lt: nil, pos: 1),
                           "due1": CardState(stage: 1, due: "2000-01-01T00:00:00Z", lt: nil, pos: 2),
                           "due2": CardState(stage: 1, due: "2000-01-01T00:00:00Z", lt: nil, pos: 3),
                           "due3": CardState(stage: 1, due: "2000-01-01T00:00:00Z", lt: nil, pos: 4)]
        let plan = StudyEngine.dailyPlanSummary(planState, day: day, now: Date())
        precondition(plan.completed == 2 && plan.dueAvailable == 3 && plan.duePlanned == 0 && plan.newPlanned == 2 && plan.totalPlanned == 4)
        planState.settings.dailyCap = 20
        let largerPlan = StudyEngine.dailyPlanSummary(planState, day: day, now: Date())
        precondition(largerPlan.newPlanned == 4 && largerPlan.totalPlanned == 9)
        planState.cards["mastered"] = CardState(stage: 6, due: "2000-01-01T00:00:00Z", lt: nil, pos: 5)
        precondition(StudyEngine.dailyPlanSummary(planState, day: day, now: Date()).dueAvailable == 3)
        var offlineForgotten = CardState(stage:6,due:"2000-01-01T00:00:00Z",lt:nil,pos:6)
        offlineForgotten.pendingFsrs = PendingFsrs(base:.init(),events:[PendingFsrsEvent(id:"offline-fail",rating:1,at:"2026-10-29T00:00:00Z")])
        precondition(!StudyEngine.isMastered(offlineForgotten), "pending forgotten rating must override stale mastery")
        var longRelearning = CardState(stage:nil,due:"2000-01-01T00:00:00Z",lt:nil,pos:7,
            fsrs:FsrsState(state:3,stability:200,difficulty:5,due:"2000-01-01T00:00:00Z",scheduled_days:nil,step:0,lastReview:nil))
        precondition(!StudyEngine.isMastered(longRelearning), "relearning state must override old stability")
        longRelearning.fsrs?.state = 2
        precondition(StudyEngine.isMastered(longRelearning))
        planState.cards["offlineForgotten"] = offlineForgotten
        precondition(StudyEngine.dailyPlanSummary(planState, day:day, now:Date()).dueAvailable == 4)
        var repeatState = LearningState()
        repeatState.settings.dailyCap = 1; repeatState.settings.newPerDay = 1
        repeatState.log = [LogEntry(d:day,word:"again",rating:1,kind:"review")]
        repeatState.cards["again"] = CardState(stage:nil,due:"2000-01-01T00:00:00Z",lt:nil,pos:1,
            fsrs:FsrsState(state:3,stability:1,difficulty:5,due:"2000-01-01T00:00:00Z",scheduled_days:nil,step:0,lastReview:nil))
        let repeatPlan = StudyEngine.dailyPlanSummary(repeatState, day:day, now:Date())
        precondition(repeatPlan.repeatPlanned == 1 && repeatPlan.duePlanned == 1 && repeatPlan.totalPlanned == 1,
                     "same-day relearning must fit within the existing distinct-word cap")
        let longLog = loadLog + (0..<1400).map { _ in LogEntry(d: day, word: "noise", rating: 3, kind: "exposure") }
        precondition(StudyEngine.completedDailyWords(StudyEngine.trimLearningLog(longLog, day: day), day: day) == Set(["apple", "banana"]))
        let historic = ["2026-10-24", "2026-10-25", "2026-10-26", "2026-10-27"].map { LogEntry(d: $0, word: "apple", rating: 3, kind: "review") }
        let manyExposures = (0..<1400).map { _ in LogEntry(d: "2026-10-27", word: "noise", rating: 3, kind: "exposure") }
        let trimmedDates = StudyEngine.trimLearningLog(historic + manyExposures, day: "2026-10-24").filter { $0.kind == "review" }.map(\.d)
        precondition(trimmedDates == ["2026-10-24", "2026-10-25", "2026-10-26", "2026-10-27"])
        let recentDates = StudyEngine.trimLearningLog(historic + manyExposures, day: "2026-10-27").filter { $0.kind == "review" }.map(\.d)
        precondition(recentDates == ["2026-10-25", "2026-10-26", "2026-10-27"])
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let stateFile = temp.appendingPathComponent("state.json"), ownerFile = temp.appendingPathComponent("state.user")
        let original = Data("unverified original".utf8)
        try original.write(to: stateFile)
        let preserved = try LocalAccountSlot.preserveUnverified(state: stateFile, owner: ownerFile, expected: "alice", slot: "u7")
        guard let preserved else { fatalError("unsigned state was not preserved") }
        let preservedBytes = try Data(contentsOf: preserved)
        precondition(preservedBytes == original && preserved.lastPathComponent.hasPrefix("unverified-"))
        try "ALICE".write(to: ownerFile, atomically: true, encoding: .utf8)
        let matching = try LocalAccountSlot.preserveUnverified(state: stateFile, owner: ownerFile, expected: "alice", slot: "u7")
        precondition(matching == nil)
        let damaged = try LocalAccountSlot.preserveUnverified(state: stateFile, owner: ownerFile, expected: "alice", slot: "u7", force: true)
        guard let damaged else { fatalError("damaged signed state was not preserved") }
        let damagedBytes = try Data(contentsOf: damaged)
        precondition(damagedBytes == original && damaged.lastPathComponent.hasPrefix("unverified-"))
        try "bob".write(to: ownerFile, atomically: true, encoding: .utf8)
        let mismatch = try LocalAccountSlot.preserveUnverified(state: stateFile, owner: ownerFile, expected: "alice", slot: "u7")
        guard let mismatch else { fatalError("other-account state was not preserved") }
        precondition(mismatch.lastPathComponent.hasPrefix("unverified-\(LocalAccountSlot.name(userId: 7, username: "bob"))-"))
        var legacyState = LearningState()
        legacyState.cards["apple"] = CardState(stage: 1, due: nil, lt: 0, pos: 1, fsrs: nil)
        try JSONEncoder().encode(legacyState).write(to: stateFile)
        try "Alice".write(to: ownerFile, atomically: true, encoding: .utf8)
        precondition(LocalAccountSlot.loadVerified(state: stateFile, owner: ownerFile, expected: "alice") == legacyState)
        precondition(LocalAccountSlot.loadVerified(state: stateFile, owner: ownerFile, expected: "bob") == nil)
        try FileManager.default.removeItem(at: ownerFile)
        precondition(LocalAccountSlot.loadVerified(state: stateFile, owner: ownerFile, expected: "alice") == nil)
        let suiteName = "vocab-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(20.0, forKey: "vocab_write_u7"); defaults.set(10.0, forKey: "vocab_sync_u7")
        let namedSlot = LocalAccountSlot.name(userId: 7, username: "alice")
        LocalAccountSlot.migrateClocks(defaults, from: "u7", to: namedSlot)
        precondition(defaults.double(forKey: "vocab_write_\(namedSlot)") == 20)
        precondition(defaults.double(forKey: "vocab_sync_\(namedSlot)") == 10)
        defaults.set(30.0, forKey: "vocab_write_\(namedSlot)")
        LocalAccountSlot.migrateClocks(defaults, from: "u7", to: namedSlot)
        precondition(defaults.double(forKey: "vocab_write_\(namedSlot)") == 30)
        let missingSlot = LocalAccountSlot.name(userId: 8, username: "alice")
        LocalAccountSlot.migrateClocks(defaults, from: "u8", to: missingSlot)
        precondition(defaults.double(forKey: "vocab_write_\(missingSlot)") > defaults.double(forKey: "vocab_sync_\(missingSlot)"))
        let timestamp = "2026-10-27T03:14:43+00:00"
        let response = """
        {"state":2,"stability":2.307,"difficulty":2.111,"due":"2026-10-29T03:14:43+00:00","step":null,"last_review":"\(timestamp)"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FsrsResponse.self, from: response)
        precondition(decoded.lastReview == timestamp)
        let legacy = """
        {"state":2,"stability":2.307,"difficulty":2.111,"last_review":"\(timestamp)"}
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(FsrsState.self, from: legacy)
        precondition(state.lastReview == timestamp)
        let encoded = try JSONEncoder().encode(state)
        let fields = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        precondition(fields["lastReview"] as? String == timestamp && fields["last_review"] == nil)
        let roundTrip = try JSONDecoder().decode(FsrsState.self, from: encoded)
        precondition(roundTrip == state)
        var card = CardState(stage: nil, due: nil, lt: 0, pos: 1, fsrs: state)
        precondition(StudyEngine.fsrsBody(for: card, rating: 3, isNewCard: false).last_review == timestamp)
        StudyEngine.applyFsrs(decoded, to: &card, today: "2026-10-27")
        precondition(StudyEngine.fsrsBody(for: card, rating: 3, isNewCard: false).last_review == timestamp)
        let pendingJson = """
        {"due":"2026-10-28","pendingFsrs":{"base":{"is_new":true,"state":1,"stability":0,"difficulty":0,"rating":3},"events":[{"id":"event-1","rating":3,"at":"2026-10-27T03:14:43.000Z"}]}}
        """.data(using: .utf8)!
        let pendingCard = try JSONDecoder().decode(CardState.self, from: pendingJson)
        precondition(pendingCard.pendingFsrs?.base.is_new == true)
        precondition(pendingCard.pendingFsrs?.events.first?.rating == 3)
        let historyJson = #"{"fsrsHistory":{"base":{"is_new":true,"state":1,"stability":0,"difficulty":0,"rating":3},"events":[{"id":"e1","rating":3,"at":"2026-10-27T03:14:43Z"}],"schedulerKey":"version-1"}}"#.data(using: .utf8)!
        var historyCard = try JSONDecoder().decode(CardState.self, from: historyJson)
        historyCard.fsrsReplayVersions = ["e1":"version-1"]
        precondition(historyCard.fsrsHistory?.schedulerKey == "version-1")
        let historyRoundTrip = try JSONDecoder().decode(CardState.self, from: JSONEncoder().encode(historyCard))
        precondition(historyRoundTrip == historyCard)
        let pendingRoundTrip = try JSONDecoder().decode(CardState.self, from: JSONEncoder().encode(pendingCard))
        precondition(pendingCard == pendingRoundTrip)
        let conflictHistory = PendingFsrs(base: APIClient.FsrsIn(is_new: true),
            events: [PendingFsrsEvent(id: "version-check", rating: 3, at: timestamp)], schedulerKey: "original")
        var changedScheduler = decoded
        changedScheduler.schedulerKey = "different"
        do {
            _ = try await StudyEngine.replayFsrs(conflictHistory) { _ in changedScheduler }
            fatalError("changed scheduler must not be silently accepted")
        } catch {
            precondition(error.localizedDescription.contains("FSRS 参数"))
        }
        let mixedHistory = PendingFsrs(base: APIClient.FsrsIn(is_new: true), events: [
            PendingFsrsEvent(id: "old", rating: 3, at: "2026-10-20T00:00:00Z", schedulerKey: "old-version"),
            PendingFsrsEvent(id: "new", rating: 3, at: "2026-10-21T00:00:00Z", schedulerKey: "new-version")])
        var seenVersions: [String] = []
        var recordedVersions: [String: String] = [:]
        _ = try await StudyEngine.replayFsrs(mixedHistory, onVersion: { recordedVersions[$0] = $1 }) { request in
            seenVersions.append(request.scheduler_key ?? "none")
            var response = decoded
            response.schedulerKey = request.scheduler_key
            return response
        }
        precondition(seenVersions == ["old-version", "new-version"])
        precondition(recordedVersions == ["old":"old-version", "new":"new-version"])
        let jobJson = """
        {"personalJobs":[{"id":"task-12345678","date":"2026-10-27","weakKey":"apple","weakWords":["apple"],"learnedMaxPos":5000,"replace":true,"owner":"u7","status":"queued"}]}
        """.data(using: .utf8)!
        let jobState = try JSONDecoder().decode(LearningState.self, from: jobJson)
        precondition(jobState.personalJobs?.first?.weakWords == ["apple"])
        let jobRoundTrip = try JSONDecoder().decode(LearningState.self, from: JSONEncoder().encode(jobState))
        precondition(jobRoundTrip == jobState)
        let progressJson = #"{"quizProgressDay":"2026-10-27","quizCompleted":["apple","banana"]}"#.data(using: .utf8)!
        let progress = try JSONDecoder().decode(LearningState.self, from: progressJson)
        precondition(progress.quizProgressDay == "2026-10-27" && progress.quizCompleted == ["apple", "banana"])
        let progressRoundTrip = try JSONDecoder().decode(LearningState.self, from: JSONEncoder().encode(progress))
        precondition(progressRoundTrip == progress)
        print("PASS iOS FSRS API decode, quiz progress and legacy state round trip")

        if let index = CommandLine.arguments.firstIndex(of: "--placement-fixture"), CommandLine.arguments.count > index + 1 {
            struct PlacementFixture: Decodable { let token: String; let state: LearningState }
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            let fixture = try JSONDecoder().decode(PlacementFixture.self, from: data)
            var branch = fixture.state
            branch.placementVersion = StudyEngine.nextPlacementVersion(branch.placementVersion, device: "zz-ios", id: "aaaaaaaa-1111")
            branch.placementResetAt = 1; branch.frontier = 7000; branch.pointer = 7001
            branch.posterior = [0, 1]; branch.posteriorHistory = nil; branch.probeCount = 3; branch.bandStats = nil; branch.bandEvidence = nil; branch.track = nil
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18765/api/v1/me/state")!)
            request.httpMethod = "PUT"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + fixture.token, forHTTPHeaderField: "Authorization")
            for state in [branch, fixture.state] {
                request.httpBody = try JSONEncoder().encode(state)
                let (_, response) = try await URLSession.shared.data(for: request)
                precondition((response as? HTTPURLResponse)?.statusCode == 200)
            }
            request.httpMethod = "GET"; request.httpBody = nil
            let (result, response) = try await URLSession.shared.data(for: request)
            precondition((response as? HTTPURLResponse)?.statusCode == 200)
            let merged = try JSONDecoder().decode(StateResponse.self, from: result)
            precondition(merged.state?.placementVersion == branch.placementVersion && merged.state?.frontier == 7000)
            precondition(merged.state?.pointer == 7001 && merged.state?.placementResetAt == 1)
            print("PASS Web and Swift concurrent placement resets converge despite opposite clocks")
        }
        if let index = CommandLine.arguments.firstIndex(of: "--posterior-fixture"), CommandLine.arguments.count > index + 1 {
            struct PosteriorFixture: Decodable { let token: String; let state: LearningState }
            let fixture = try JSONDecoder().decode(PosteriorFixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
            var branch = fixture.state
            StudyEngine.posteriorUpdate(&branch, rank: 2000, resp: 0, weight: 1, guess: 0.25)
            branch.log.append(LogEntry(d: "2026-10-27", word: "apple", rating: 3, kind: "review"))
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18765/api/v1/me/state")!)
            request.httpMethod = "PUT"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + fixture.token, forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(branch)
            for _ in 0..<2 {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { fatalError(String(data: data, encoding: .utf8) ?? "upload failed") }
            }
            request.httpMethod = "GET"; request.httpBody = nil
            let (data, response) = try await URLSession.shared.data(for: request)
            precondition((response as? HTTPURLResponse)?.statusCode == 200)
            let merged = try JSONDecoder().decode(StateResponse.self, from: data)
            precondition(merged.state?.probeCount == 3 && merged.state?.posteriorHistory?.events.count == 2)
            precondition(merged.state?.log.filter { $0.word == "apple" && $0.kind == "review" }.count == 2)
            print("PASS Web and Swift independent posterior evidence converges over HTTP")
        }
        if let index = CommandLine.arguments.firstIndex(of: "--streak-fixture"), CommandLine.arguments.count > index + 1 {
            struct Fixture: Decodable { let token: String; let state: LearningState }
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
            var branch = fixture.state
            StudyEngine.recordStudyDay(&branch, day: "2026-10-27")
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18765/api/v1/me/state")!)
            request.httpMethod = "PUT"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + fixture.token, forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(branch)
            for _ in 0..<2 {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { fatalError(String(data: data, encoding: .utf8) ?? "upload failed") }
            }
            request.httpMethod = "GET"; request.httpBody = nil
            let (data, response) = try await URLSession.shared.data(for: request)
            precondition((response as? HTTPURLResponse)?.statusCode == 200)
            let merged = try JSONDecoder().decode(StateResponse.self, from: data)
            precondition(merged.state?.lastDay == "2026-10-27" && merged.state?.streak == 6)
            precondition(merged.state?.streakEvidence?.days == ["2026-10-26", "2026-10-27"])
            print("PASS Web and Swift independent completion days converge over HTTP")
        }
        if let index = CommandLine.arguments.firstIndex(of: "--streak-backfill-fixture"), CommandLine.arguments.count > index + 1 {
            struct Fixture: Decodable { let token: String; let state: LearningState }
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
            var branch = fixture.state
            StudyEngine.recordStudyDay(&branch, day: "2026-10-26")
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18766/api/v1/me/state")!)
            request.httpMethod = "PUT"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + fixture.token, forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(branch)
            for _ in 0..<2 {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { fatalError(String(data: data, encoding: .utf8) ?? "upload failed") }
            }
            request.httpMethod = "GET"; request.httpBody = nil
            let (data, response) = try await URLSession.shared.data(for: request)
            precondition((response as? HTTPURLResponse)?.statusCode == 200)
            let merged = try JSONDecoder().decode(StateResponse.self, from: data)
            precondition(merged.state?.lastDay == "2026-10-26" && merged.state?.streak == 6)
            precondition(merged.state?.streakEvidence?.days == ["2026-10-21", "2026-10-26"])
            print("PASS Web and Swift earlier completion days converge over HTTP")
        }
        if let index = CommandLine.arguments.firstIndex(of: "--knowledge-fixture"), CommandLine.arguments.count > index + 1 {
            struct KnowledgeFixture: Decodable { let token: String; let state: LearningState }
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            let fixture = try JSONDecoder().decode(KnowledgeFixture.self, from: data)
            var branch = fixture.state
            StudyEngine.recordKnowledge(&branch, word: "banana", pos: 8, ok: false, isPlacement: true)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18765/api/v1/me/state")!)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + fixture.token, forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(branch)
            for _ in 0..<2 {
                let (_, response) = try await URLSession.shared.data(for: request)
                precondition((response as? HTTPURLResponse)?.statusCode == 200)
            }
            request.httpMethod = "GET"; request.httpBody = nil
            let (result, response) = try await URLSession.shared.data(for: request)
            precondition((response as? HTTPURLResponse)?.statusCode == 200)
            let merged = try JSONDecoder().decode(StateResponse.self, from: result)
            precondition(merged.state?.knowledge?["apple"]?.a == 3 && merged.state?.knowledge?["apple"]?.b == 1)
            precondition(merged.state?.knowledge?["banana"]?.a == 0 && merged.state?.knowledge?["banana"]?.b == 1)
            precondition(merged.state?.bandStats?["0"]?.a == 1 && merged.state?.bandStats?["0"]?.b == 1)
            precondition(merged.state?.bandEvidence?["0"]?.events.count == 2)
            print("PASS Web and Swift independent placement and word evidence converge over HTTP")
        }
        if let index = CommandLine.arguments.firstIndex(of: "--history-fixture"), CommandLine.arguments.count > index + 1 {
            struct Fixture: Decodable { let token: String; let state: LearningState; let expected: FsrsResponse }
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            let fixture = try JSONDecoder().decode(Fixture.self, from: data)
            guard let pending = fixture.state.cards["apple"]?.pendingFsrs else { fatalError("missing merged history") }
            var savedConfigs: [String: FsrsSchedulerConfig] = [:]
            let result = try await StudyEngine.replayFsrs(pending) { body in
                var req = URLRequest(url: URL(string: "http://127.0.0.1:18765/api/v1/fsrs/review")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("Bearer " + fixture.token, forHTTPHeaderField: "Authorization")
                req.httpBody = try JSONEncoder().encode(body)
                let (data, response) = try await URLSession.shared.data(for: req)
                precondition((response as? HTTPURLResponse)?.statusCode == 200)
                let decodedResponse = try JSONDecoder().decode(FsrsResponse.self, from: data)
                if let key = decodedResponse.schedulerKey, let config = decodedResponse.schedulerConfig { savedConfigs[key] = config }
                return decodedResponse
            }
            precondition(result?.state == fixture.expected.state && result?.stability == fixture.expected.stability)
            precondition(result?.difficulty == fixture.expected.difficulty && result?.due == fixture.expected.due)
            precondition(result?.lastReview == fixture.expected.lastReview && result?.schedulerKey == fixture.expected.schedulerKey)
            guard let key = result?.schedulerKey, let config = result?.schedulerConfig else { fatalError("missing scheduler snapshot") }
            var backup = fixture.state
            backup.fsrsSchedulers = savedConfigs
            let restored = try JSONDecoder().decode(LearningState.self, from: JSONEncoder().encode(backup))
            precondition(restored.fsrsSchedulers?[key] == config)
            if let outputIndex = CommandLine.arguments.firstIndex(of: "--backup-output"), CommandLine.arguments.count > outputIndex + 1 {
                try JSONEncoder().encode(backup).write(to: URL(fileURLWithPath: CommandLine.arguments[outputIndex + 1]), options: .atomic)
            }
            print("PASS iOS replays the same merged history against the authenticated HTTP API")
        }

        if CommandLine.arguments.contains("--integration") {
            let events = [
                PendingFsrsEvent(id: "one", rating: 3, at: "2026-10-20T00:00:00Z"),
                PendingFsrsEvent(id: "two", rating: 3, at: "2026-10-20T00:15:00Z"),
                PendingFsrsEvent(id: "three", rating: 1, at: "2026-10-23T00:15:00Z")
            ]
            let pending = PendingFsrs(base: APIClient.FsrsIn(is_new: true), events: events)
            let saved = try JSONEncoder().encode(pending)
            let restored = try JSONDecoder().decode(PendingFsrs.self, from: saved)
            let call: (APIClient.FsrsIn) async throws -> FsrsResponse = { body in
                var req = URLRequest(url: URL(string: "http://127.0.0.1:18765/api/v1/fsrs/review")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONEncoder().encode(body)
                let (data, response) = try await URLSession.shared.data(for: req)
                precondition((response as? HTTPURLResponse)?.statusCode == 200)
                return try JSONDecoder().decode(FsrsResponse.self, from: data)
            }
            let first = try await StudyEngine.replayFsrs(restored, call: call)!
            let second = try await StudyEngine.replayFsrs(restored, call: call)!
            precondition(first.state == 3 && first.lastReview == "2026-10-23T00:15:00+00:00")
            precondition(first.state == second.state && first.due == second.due && first.stability == second.stability)
            print("PASS iOS persisted offline history replays deterministically against the API")
        }
    }
}
