import SwiftUI

struct CoachBody: Encodable {
    var client: String
    var offset = TimeZone.current.secondsFromGMT()/60
    var action: String?
    var track: String?
    var task: String?
    var choice: Int?
    var mode: String?
    var replay: Bool?
    var kind:String?
    var event:String?
    var edition:Int?
    var goal:String?
    var level:Int?
    var due:Int?
    var activity:String?
    var study:Bool?
    var words:[String]?
    var text:String?
    var attempt:Int?
    var position:Int?
    var new_words:[String]?
    var review_words:[String]?
    var voice:String?
    var segments:[CoachTimeSegment]?
}
struct CoachClockReply: Decodable {
    let day:String
    let used, limit:Int
    let credit:Double
    let busy, extended:Bool
    let acknowledged:[String]?
}
struct CoachTask: Decodable {
    let id, passage, question, kind, purpose, hint:String
    let title,titleEn,questionEn:String?
    let optionsEn:[String]?
    let options:[String]
    let shown:Bool
    let plays:Int
}
struct CoachResult: Decodable {
    let id:String
    let expectedEn,explanationEn:String?
    let response:StudioReply?
    let ok:Bool
    let mode, explanation, reply, expected:String
}
struct CoachLesson: Decodable {
    let day, focus, reason, track:String
    let step, count, independent:Int
    let title,source,debrief:String?
    let words:[String]?
    let task:CoachTask?
    let last:CoachResult?
}
struct CoachExplanation: Decodable { let text:String; let textEn:String?; let ai:Bool }

struct CoachTimeSegment: Codable {
    let id:String
    let start,end:Double
    let activity:String
}

@MainActor @Observable
final class CoachClock {
    private(set) var client = ""
    var state:CoachClockReply?
    private var boundToken:String?
    private var storageKey=""
    private var pending:[CoachTimeSegment]=[]
    private var worker:Task<Void,Never>?
    private var uploader:Task<Void,Never>?
    private var tick=ProcessInfo.processInfo.systemUptime
    private var wall=Date().timeIntervalSince1970
    var isClass=false
    var running:Bool { !client.isEmpty }
    var minutes:Int {
        let day=state?.day ?? DayUtil.today()
        let local=pending.filter { DayUtil.localDay(Date(timeIntervalSince1970:$0.start)) == day }.reduce(0) { $0+$1.end-$1.start }
        return (Int(local)+(state?.day == DayUtil.today() ? state?.used ?? 0:0))/60
    }
    func start(token:String?,account:String) {
        if running && (boundToken != token || storageKey != "coach.time.v3."+account) {stop()}
        guard !running else {return}
        client=UUID().uuidString;boundToken=token;storageKey="coach.time.v3."+account
        pending=(UserDefaults.standard.data(forKey:storageKey).flatMap {try? JSONDecoder().decode([CoachTimeSegment].self,from:$0)}) ?? []
        state=nil;tick=ProcessInfo.processInfo.systemUptime;wall=Date().timeIntervalSince1970
        upload()
        let id=client
        worker=Task {
            var count=0
            while !Task.isCancelled && id==client {
                do { try await Task.sleep(for:.seconds(5)) } catch {return}
                guard id==client else {return}
                checkpoint();count+=1
                if count%3==0 {upload()}
            }
        }
    }
    private func persist(){if let data=try? JSONEncoder().encode(pending){UserDefaults.standard.set(data,forKey:storageKey)}}
    private func checkpoint(){
        let now=ProcessInfo.processInfo.systemUptime,elapsed=now-tick
        // Background suspension / host clock adjustment must never become study time.
        if elapsed>0 && elapsed<=60 {
            pending.append(CoachTimeSegment(id:UUID().uuidString.lowercased(),start:wall,end:wall+elapsed,activity:isClass ? "class":"vocab"))
            persist()
        }
        tick=now;wall=Date().timeIntervalSince1970
    }
    private func upload(){
        guard uploader == nil,!client.isEmpty else{return}
        let id=client,token=boundToken,key=storageKey,batch=Array(pending.prefix(100))
        uploader=Task {
            defer {if client==id {uploader=nil}}
            var body=CoachBody(client:id,action:"record");body.segments=batch
            do {
                let reply:CoachClockReply=try await APIClient.shared.coach("clock",body,token:token)
                let ids=Set(reply.acknowledged ?? [])
                // A late response only acknowledges its original account's persisted records.
                if client==id {
                    pending.removeAll {ids.contains($0.id)};persist();state=reply
                } else if let data=UserDefaults.standard.data(forKey:key),var rows=try? JSONDecoder().decode([CoachTimeSegment].self,from:data) {
                    rows.removeAll {ids.contains($0.id)}
                    if let encoded=try? JSONEncoder().encode(rows){UserDefaults.standard.set(encoded,forKey:key)}
                }
            }catch { /* Time is advisory; retain intervals and retry without interrupting study. */ }
        }
    }
    func stop(){
        guard running else{return}
        checkpoint();upload()
        worker?.cancel();worker=nil;uploader=nil;client=""
    }
}

struct CoachTimeGate: ViewModifier {
    @Environment(AppState.self) var app
    @Environment(CoachClock.self) var clock
    @Environment(\.scenePhase) var scene
    let active:Bool
    func body(content: Content) -> some View {
        VStack(spacing:4) {
            if active {
                Text("今日已练 \(clock.minutes) 分钟 · 用时仅作参考")
                    .font(.caption).foregroundStyle(.secondary)
            }
            content
        }
        .task(id:"\(active)-\(scene == .active)-\(app.auth?.accountId ?? "guest")-\(app.route == .coach)") {
            if active && scene == .active {
                clock.isClass=app.route == .coach
                clock.start(token:app.auth?.token,account:app.auth?.accountId ?? "guest")
            } else {clock.stop()}
        }
        .onDisappear {clock.stop()}
    }
}

struct CoachLessonView: View {
    @Environment(AppState.self) var app
    @Environment(CoachClock.self) var clock
    @State private var lesson:CoachLesson?
    @State private var feedback=false
    @State private var section = 0
    @State private var shown=false
    @State private var busy=false
    @State private var plays=0
    @State private var notice=""
    @State private var aiNote:CoachExplanation?
    @State private var draft=""
    @State private var reply:StudioReply?
    @State private var revising=false
    @State private var recording=UUID()
    private func dictate(_ id:String) async {
        if app.speech.state == .listening {app.speech.stopCapture(finalize:true);return}
        let attempt=UUID();recording=attempt
        let token=app.auth?.token
        let allowed=await SpeechService.requestPermissions()
        guard app.route == .coach,app.auth?.token==token,
              feedback,lesson?.last?.id==id,recording==attempt,clock.running else{return}
        guard allowed else {notice="未获得听写权限，可直接打字。";return}
        app.speech.start(target:""){result in
            guard recording==attempt,app.route == .coach,app.auth?.token==token,feedback,
                  lesson?.last?.id==id,clock.running else{return}
            if let text=result?.text {draft=String(text.prefix(180))}
            else {notice="本机未取得转写，可直接打字。"}
        }
    }
    private func send(_ action:String,_ choice:Int?=nil,aid:String?=nil) async {
        guard !busy,app.route == .coach else {return}
        clock.isClass=true
        clock.start(token:app.auth?.token,account:app.auth?.accountId ?? "guest")
        let token=app.auth?.token,id=clock.client
        busy=true;notice=""
        defer {busy=false}
        var b=CoachBody(client:id,track:app.coachTrack)
        StudioTheme.context(&b,app);b.edition=app.coachEdition
        if let t=lesson?.task, let choice {
            b.task=t.id;b.choice=choice;b.replay=plays>1
            b.mode = !t.hint.isEmpty ? "assisted" : t.kind=="read" ? "read" : shown ? "assisted" : "listen"
        }
        if let aid,let t=lesson?.task {b.task=t.id;b.kind=aid;b.event=UUID().uuidString}
        do{
            if action=="reply" {
                b.attempt=(reply ?? lesson?.last?.response)?.attempt==1 ? 2 : 1
                b.text=draft.trimmingCharacters(in:.whitespacesAndNewlines);b.task=lesson?.last?.id
                let result:StudioReply=try await APIClient.shared.coach(action,b,token:token)
                guard id==clock.client,token==app.auth?.token else{return}
                reply=result;revising=false
            } else if action=="explanation" {
                let r:CoachExplanation=try await APIClient.shared.coach(action,b,token:token)
                guard id==clock.client,token==app.auth?.token else{return}
                aiNote=r
            }else{
                if action=="undo" {b.task=lesson?.last?.id}
                let r:CoachLesson=try await APIClient.shared.coach(action,b,token:token)
                guard id==clock.client,token==app.auth?.token else{return}
                lesson=r;feedback=choice != nil;shown=r.task?.shown ?? false;plays=r.task?.plays ?? 0;aiNote=nil;draft="";reply=nil;revising=false
            }
        }catch{notice=error.localizedDescription}
    }
    @Environment(\.dynamicTypeSize) private var textSize
    private var stageNames:[String:String] {
        ["接收消息":"Understand the message","核对线索":"Check the clue","做出行动":"Choose an action",
         "独立迁移":"Try a new situation","先独立理解":"Try it on your own","带着线索再试":"Check the clue","换个情境验证":"Try a new situation"]
    }
    private func goHome(){app.audio.stop();app.route = .home}
    private func continueWords(){
        if !app.S.calibrated {app.route = .placement;return}
        let identity=app.auth,generation=app.routeGeneration
        Task {
            let ready=await app.buildQueue()
            guard ready,app.auth==identity,app.routeGeneration==generation,app.route == .coach else{return}
            if app.session.queue.isEmpty {app.markDayDone()}
            app.route = .session
        }
    }
    @ViewBuilder private func header(_ l:CoachLesson)->some View {
        VStack(alignment:.leading,spacing:12){
            Text(feedback ? "FEEDBACK":l.task == nil ? "RECAP":l.task?.kind=="listen" ? "LISTENING":"READING")
                .font(.caption.monospaced().bold()).tracking(1.2).foregroundStyle(Theme.accent)
            if feedback,let last=l.last {
                LessonPair(en:last.ok ? "You got it":"Look at the clue",zh:last.ok ? "理解正确":"一起看这条线索",font:.system(.title2,design:.serif))
            }else if let t=l.task {
                LessonPair(en:t.titleEn ?? stageNames[t.purpose],zh:t.title ?? t.purpose,font:.system(.title2,design:.serif))
            }else{LessonPair(en:"Lesson complete",zh:"今日教练课完成",font:.system(.title2,design:.serif))}
            ProgressView(value:Double(l.step),total:Double(l.count)).tint(Theme.accent).accessibilityLabel("课堂进度")
            ReadingText(text: l.focus, font: .caption).foregroundStyle(Theme.muted)
        }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(StudioTheme.gradient,in:RoundedRectangle(cornerRadius:18))
    }
    @ViewBuilder private func prompt(_ t: CoachTask, _ l: CoachLesson) -> some View {
        if section == 0 {
            if t.kind == "listen" {
                let layout =
                    textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout(alignment: .top))
                layout {
                    LessonAction(
                        en: plays == 0 ? "Play audio" : "Listen again", zh: plays == 0 ? "播放消息" : "再听一遍", icon: "play.fill", primary: true
                    ) { app.audio.play(t.passage, voice: app.S.settings.voice) }
                    LessonAction(en: "Transcript", zh: "看原文", icon: "text.alignleft") {
                        Task {
                            await send("aid", aid: "transcript"); if shown { section = 1 }
                        }
                    }.accessibilityIdentifier("coach-transcript")
                }
            }
            if !t.hint.isEmpty {
                LessonPair(
                    en: t.hint.contains("重选") ? "Try again with the feedback in mind." : "Check the message again.", zh: t.hint,
                    font: .subheadline)
            }
            LessonPair(en: t.questionEn, zh: t.question, font: .title3.weight(.semibold))
            ForEach(t.options.indices, id: \.self) { i in
                let en = t.optionsEn.flatMap { $0.indices.contains(i) ? $0[i] : nil } ?? ""
                let option = t.options[i]
                LessonAction(
                    en: en, zh: option,
                    icon: ["a.circle", "b.circle", "c.circle"].indices.contains(i) ? ["a.circle", "b.circle", "c.circle"][i] : "circle"
                ) {
                    app.audio.stop(); Task { await send("answer", i) }
                }.disabled(busy || (t.kind == "listen" && !shown && plays == 0)).accessibilityIdentifier("coach-option-\(i)")
            }
        } else if section == 1 {
            if t.kind == "read" || shown {
                ReadingText(text: t.passage, font: .system(.title3, design: .serif), title: "阅读完整原文")
            } else {
                Text("可先听一遍，再决定是否查看原文。").font(.subheadline)
                LessonAction(en: "Transcript", zh: "看原文", icon: "text.alignleft") { Task { await send("aid", aid: "transcript") } }
            }
            LessonAction(en: "Answer the question", zh: "去答题", icon: "arrow.right", primary: true) { section = 0 }
        } else {
            ReadingText(text: l.reason, font: .body)
            if let words = l.words, !words.isEmpty { ReadingText(text: "课中复现 · " + words.joined(separator: " / "), font: .footnote) }
        }
    }
    @ViewBuilder private func correction(_ a: CoachResult, _ l: CoachLesson) -> some View {
        if section == 0 {
            Text("THE ANSWER  /  正确行动").font(.caption.monospaced().bold()).foregroundStyle(a.ok ? Theme.accent : Theme.warn)
            LessonPair(en: a.expectedEn, zh: a.expected, font: .title3.weight(.semibold))
            LessonPair(en: a.explanationEn, zh: a.explanation, font: .body)

            LessonAction(
                en: l.task == nil ? "See my recap" : "Continue", zh: l.task == nil ? "看本课小结" : "继续", icon: "arrow.right", primary: true
            ) {
                recording = UUID(); app.speech.stopCapture(finalize: false); feedback = false
            }.disabled(busy).accessibilityIdentifier("coach-next")
        } else if section == 1 {
            ReadingText(text: a.reply, font: .system(.title3, design: .serif), title: "完整参考说法")
            LessonAction(en: "Explain the clue", zh: "请 AI 再讲一句", icon: "lightbulb") { Task { await send("explanation") } }
            if let extra = aiNote { LessonPair(en: extra.textEn, zh: (extra.ai ? "AI 教练 · " : "课程题解 · ") + extra.text, font: .body) }
        } else if app.coachEdition == 2 {
            if let result = reply ?? a.response, !revising {
                let labels = ["表达清楚": "Your meaning is clear", "可以更明确": "Try being more specific", "暂无法判断": "Check the example"]
                LessonPair(en: labels[result.verdict], zh: result.verdict); LessonPair(en: result.tipEn, zh: result.tip, font: .body)
                LessonPair(en: result.example, zh: "参考说法")
                if (result.attempt ?? 0) < 2 {
                    LessonAction(en: "Try again", zh: result.attempt == nil ? "重新尝试反馈" : "改一句再试") {
                        draft = ""; revising = true
                    }
                }
            } else {
                TextField("Write one sentence…", text: $draft).accessibilityLabel("我的英文回应")
                    .textFieldStyle(.roundedBorder).submitLabel(.done).onChange(of: draft) { _, v in
                        if v.count > 180 { draft = String(v.prefix(180)) }
                    }
                if app.speech.onDeviceAvailable {
                    LessonAction(
                        en: app.speech.state == .listening ? "Stop dictation" : "Dictate a reply",
                        zh: app.speech.state == .listening ? "结束听写" : "口述一句，先核对文字", icon: "mic"
                    ) { Task { await dictate(a.id) } }
                }
                Text("点击后才发送文字。只保存反馈，不计词汇掌握。").font(.footnote).foregroundStyle(Theme.muted)
                LessonAction(en: "Check my reply", zh: "看看我的回应") { Task { await send("reply") } }.disabled(
                    draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
            LessonAction(en: "Undo my choice", zh: "撤销这次选择", icon: "arrow.uturn.backward") { Task { await send("undo") } }.disabled(busy)
        }
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(lesson.map { "\($0.source ?? "听读课") · \($0.step) / \($0.count)" } ?? "听读课").font(.subheadline)
                Spacer()
                Button(action: goHome) { Label("暂停", systemImage: "pause.circle").frame(minHeight: 44) }
                    .accessibilityIdentifier("coach-pause")
            }
            if let l = lesson, feedback || l.task != nil {
                SectionChoice(
                    titles: feedback ? (app.coachEdition == 2 ? ["反馈", "例解", "回应"] : ["反馈", "例解"]) : ["作答", "原文", "练习依据"],
                    selected: $section)
            }
            ScreenPages {
                if let l = lesson {
                    if section == 0 { header(l) }
                    if feedback, let answer = l.last {
                        correction(answer, l)
                    } else if let task = l.task {
                        prompt(task, l)
                    } else {
                        LessonPair(
                            en: "\(l.independent) of \(l.step) tasks completed independently",
                            zh: "本课 \(l.step) 道任务，独立理解 \(l.independent) 道。")
                        if let debrief = l.debrief { ReadingText(text: debrief, font: .subheadline) }
                        LessonAction(en: "Back to today", zh: "返回首页", icon: "house", primary: true, action: goHome)
                        LessonAction(en: "Practice vocabulary", zh: "接着练今天的词汇", icon: "book", action: continueWords)
                    }
                } else if notice.isEmpty {
                    ProgressView("正在准备课程…")
                }
                if !notice.isEmpty {
                    ReadingText(text: notice); LessonAction(en: "Reload lesson", zh: "取回今日课程") { Task { await send("lesson") } }
                }
                if busy { ProgressView() }
            }.id("\(lesson?.task?.id ?? "")-\(feedback)-\(section)")
        }.padding(.horizontal, 14)
            .onChange(of: feedback) { _, _ in section = feedback || lesson?.task?.kind != "read" ? 0 : 1 }
            .onChange(of: lesson?.task?.id) { _, _ in section = !feedback && lesson?.task?.kind == "read" ? 1 : 0 }
            .task { if lesson == nil { await send("lesson") } }
            .onChange(of: app.audio.playingText) { _, text in
                if let t = lesson?.task, t.kind == "listen", text == t.passage { Task { await send("aid", aid: "play") } }
            }
            .onDisappear {
                recording = UUID(); app.speech.stopCapture(finalize: false); app.audio.stop()
            }
            .modifier(CoachTimeGate(active: lesson == nil || lesson?.task != nil || feedback))
    }
}