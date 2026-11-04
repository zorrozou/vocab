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
}
struct CoachClockReply: Decodable {
    let day:String
    let used, limit:Int
    let credit:Double
    let busy, extended:Bool
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

@MainActor @Observable
final class CoachClock {
    private(set) var client = ""
    var state:CoachClockReply?
    var until:TimeInterval = 0
    var error = ""
    private var boundToken:String?
    private var worker:Task<Void,Never>?
    var up: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var isClass=false
    func start(token:String?) {
        if !client.isEmpty && boundToken != token { stop() }
        guard client.isEmpty else { return }
        let id=UUID().uuidString
        client=id; boundToken=token; error=""; until=0; state=nil
        worker=Task {
            while !Task.isCancelled && id==client {
                let sent=up
                do {
                    let reply:CoachClockReply = try await APIClient.shared.coach("clock",CoachBody(client:id,action:"pulse",activity:isClass ? "class":"vocab"),token:token)
                    guard !Task.isCancelled,client==id else {
                        await self.release(id,token);return
                    }
                    state=reply;until=sent+reply.credit;error=""
                    if reply.busy { error="另一台设备正在练习，请先在那里暂停。" }
                    if reply.credit==0 && reply.used>=reply.limit {return}
                    if reply.busy {try await Task.sleep(for:.seconds(3));continue}
                    try await Task.sleep(for:.seconds(max(0.2,min(10,until-up))))
                } catch {
                    guard !Task.isCancelled,client==id else {return}
                    self.error="暂时无法核对练习时间。请联网后重试。";return
                }
            }
        }
    }
    private func release(_ id:String,_ token:String?) async {
        let _:CoachClockReply? = try? await APIClient.shared.coach("clock",CoachBody(client:id,action:"stop"),token:token)
    }
    func stop(){
        let id=client,token=boundToken
        worker?.cancel();worker=nil;client="";until=0;state=nil;error=""
        if !id.isEmpty {Task {await release(id,token)}}
    }
    func offline(token:String?) async {
        let id=client,sent=up
        guard !id.isEmpty else{return}
        do{
            let r:CoachClockReply=try await APIClient.shared.coach("clock",CoachBody(client:id,action:"offline"),token:token)
            guard client==id else{return}
            state=r;until=sent+r.credit
        }catch{self.error="未预留离线时段，请保持联网"}
    }
    func retry(extend:Bool,token:String?) async {
        let id=client
        guard !id.isEmpty else {start(token:token);return}
        if extend {
            do { let _:CoachClockReply = try await APIClient.shared.coach("clock",CoachBody(client:id,action:"extend"),token:token) }
            catch {self.error="无法延长时间，请重试";return}
        }
        guard client==id else {return}
        stop()
        start(token:token)
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
                TimelineView(.periodic(from:.now,by:0.25)) { _ in
                    let allowed=scene == .active && clock.until>clock.up
                    VStack(spacing:6){
                        if let s=clock.state {
                            Text("今日练习 \(s.used/60) / \(s.limit/60) 分钟").font(.caption).foregroundStyle(.secondary)
                        }
                        if allowed {
                            if let s=clock.state,s.limit-s.used<=180 {Text("剩余不到 3 分钟，建议做完当前题就收课。").font(.caption)}
                            if app.route != .coach {
                                if let s=clock.state,s.credit>30 {Text("当前已预留离线时间，最多 10 分钟").font(.caption)}
                                else {Button("预留离线练习时段"){Task{await clock.offline(token:app.auth?.token)}}.font(.caption)}
                            }
                            content
                        }
                        else {
                            Spacer()
                            if let s=clock.state,s.used>=s.limit {
                                Text(s.extended ? "今天已到 40 分钟，明天再继续。" : "今天已练满 30 分钟，建议在这里结束。")
                                if !s.extended {Button("再练最多 10 分钟"){Task {await clock.retry(extend:true,token:app.auth?.token)}}}
                            } else {
                                Text(clock.error.isEmpty ? "正在核对今日练习时间…" : clock.error)
                                if !clock.error.isEmpty {Button("重新连接"){Task {await clock.retry(extend:false,token:app.auth?.token)}}}
                            }
                            Button("暂停并返回首页"){clock.stop();app.audio.stop();app.route = .home}
                            Spacer()
                        }
                    }
                    .onChange(of:allowed){_,ok in if !ok {app.audio.stop()}}
                }
            } else { content }
        }
        .task(id:"\(active)-\(scene == .active)-\(app.auth?.accountId ?? "guest")"){
            if active && scene == .active { clock.isClass=app.route == .coach;clock.start(token:app.auth?.token) } else {clock.stop()}
        }
        .onDisappear{clock.stop()}
    }
}

struct CoachLessonView: View {
    @Environment(AppState.self) var app
    @Environment(CoachClock.self) var clock
    @State private var lesson:CoachLesson?
    @State private var feedback=false
    @State private var shown=false
    @State private var busy=false
    @State private var sample=false
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
              feedback,lesson?.last?.id==id,recording==attempt,clock.until>clock.up else{return}
        guard allowed else {notice="未获得听写权限，可直接打字。";return}
        app.speech.start(target:""){result in
            guard recording==attempt,app.route == .coach,app.auth?.token==token,feedback,
                  lesson?.last?.id==id,clock.until>clock.up else{return}
            if let text=result?.text {draft=String(text.prefix(180))}
            else {notice="本机未取得转写，可直接打字。"}
        }
    }
    private func send(_ action:String,_ choice:Int?=nil,aid:String?=nil) async {
        guard !busy,app.route == .coach,!clock.client.isEmpty,clock.until>clock.up else {return}
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
                lesson=r;feedback=choice != nil;sample=false;shown=r.task?.shown ?? false;plays=r.task?.plays ?? 0;aiNote=nil;draft="";reply=nil;revising=false
            }
        }catch{notice=error.localizedDescription}
    }
    @State private var composer=false
    @State private var rationale=false
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
                LessonPair(en:last.ok ? "You got it":"Look at the clue",zh:last.ok ? "理解正确":"一起看这条线索",font:.system(.largeTitle,design:.serif))
            }else if let t=l.task {
                LessonPair(en:t.titleEn ?? stageNames[t.purpose],zh:t.title ?? t.purpose,font:.system(.largeTitle,design:.serif))
            }else{LessonPair(en:"Lesson complete",zh:"今日教练课完成",font:.system(.largeTitle,design:.serif))}
            ProgressView(value:Double(l.step),total:Double(l.count)).tint(Theme.accent).accessibilityLabel("课堂进度")
            Text((l.source ?? "教研课程")+"  ·  "+l.focus+"  ·  \(l.step)/\(l.count)").font(.caption).foregroundStyle(Theme.muted)
        }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(StudioTheme.gradient,in:RoundedRectangle(cornerRadius:18))
    }
    @ViewBuilder private func prompt(_ t:CoachTask,_ l:CoachLesson)->some View {
        if t.kind=="listen" && !shown && plays==0 {
            LessonPair(en:"Listen first, then choose.",zh:"先听消息，再选择行动。",font:.headline,primary:Theme.accent)
        }else if t.title != nil {LessonPair(en:stageNames[t.purpose],zh:t.purpose,font:.headline,primary:Theme.accent)}
        if t.kind=="listen" {
            let layout=textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment:.leading)):AnyLayout(HStackLayout(alignment:.top))
            layout {
                LessonAction(en:plays==0 ? "Play audio":"Listen again",zh:plays==0 ? "播放消息":"再听一遍",icon:"play.fill",primary:true){app.audio.play(t.passage,voice:app.S.settings.voice)}
                LessonAction(en:"Transcript",zh:"看原文",icon:"text.alignleft"){Task{await send("aid",aid:"transcript")}}.accessibilityIdentifier("coach-transcript")
            }
        }
        if t.kind=="read" || shown {
            Text(verbatim:t.passage).font(.system(.title3,design:.serif)).lineSpacing(4).padding(16)
                .frame(maxWidth:.infinity,alignment:.leading).background(Theme.cardDeep,in:RoundedRectangle(cornerRadius:12))
        }
        if !t.hint.isEmpty {LessonPair(en:t.hint.contains("重选") ? "Try again with the feedback in mind.":"Check the message again.",zh:t.hint,font:.subheadline)}
        LessonPair(en:t.questionEn,zh:t.question,font:.title3.weight(.semibold))
        VStack(spacing:8){
            ForEach(t.options.indices,id:\.self){i in
                LessonAction(en:t.optionsEn.flatMap{$0.indices.contains(i) ? $0[i]:nil} ?? "",zh:t.options[i],icon:["a.circle","b.circle","c.circle"][i]){
                    app.audio.stop();Task{await send("answer",i)}
                }.disabled(busy || (t.kind=="listen" && !shown && plays==0)).accessibilityIdentifier("coach-option-\(i)")
            }
        }
        DisclosureGroup(isExpanded:$rationale){
            Text(l.reason).font(.subheadline).frame(maxWidth:.infinity,alignment:.leading)
            if let words=l.words,!words.isEmpty {Text("课中复现 · "+words.joined(separator:" / ")).font(.footnote)}
        }label:{LessonPair(en:"Why this task?",zh:"为什么练这一题").frame(minHeight:44)}
    }
    @ViewBuilder private func correction(_ a:CoachResult,_ l:CoachLesson)->some View {
        VStack(alignment:.leading,spacing:10){
            Text("THE ANSWER  /  正确行动").font(.caption.monospaced().bold()).foregroundStyle(a.ok ? Theme.accent:Theme.warn)
            LessonPair(en:a.expectedEn,zh:a.expected,font:.title3.weight(.semibold))
            LessonPair(en:a.explanationEn,zh:a.explanation,font:.body)
        }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Theme.cardDeep,in:RoundedRectangle(cornerRadius:12))
        LessonAction(en:l.task==nil ? "See my recap":"Continue",zh:l.task==nil ? "看本课小结":"继续",icon:"arrow.right",primary:true){
            recording=UUID();app.speech.stopCapture(finalize:false);feedback=false;composer=false;rationale=false
        }.disabled(busy).accessibilityIdentifier("coach-next")
        DisclosureGroup(isExpanded:$sample){Text(verbatim:a.reply).font(.system(.title3,design:.serif))}
            label:{LessonPair(en:"See a sample reply",zh:"查看参考说法").frame(minHeight:44)}
        LessonAction(en:"Explain the clue",zh:"请 AI 再讲一句",icon:"lightbulb"){Task{await send("explanation")}}
        if let extra=aiNote {LessonPair(en:extra.textEn,zh:(extra.ai ? "AI 教练 · ":"课程题解 · ")+extra.text,font:.body)}
        if app.coachEdition==2 {
            DisclosureGroup(isExpanded:$composer){
                VStack(alignment:.leading,spacing:10){
                    if let result=reply ?? a.response,!revising {
                        let labels=["表达清楚":"Your meaning is clear","可以更明确":"Try being more specific","暂无法判断":"Check the example"]
                        LessonPair(en:labels[result.verdict],zh:result.verdict);LessonPair(en:result.tipEn,zh:result.tip,font:.body)
                        LessonPair(en:result.example,zh:"参考说法")
                        if (result.attempt ?? 0)<2 {LessonAction(en:"Try again",zh:result.attempt==nil ? "重新尝试反馈":"改一句再试"){draft="";revising=true}}
                    }else{
                        TextField("Write one sentence…",text:$draft,axis:.vertical).accessibilityLabel("我的英文回应")
                            .textFieldStyle(.roundedBorder).lineLimit(2...4).onChange(of:draft){_,v in if v.count>180 {draft=String(v.prefix(180))}}
                        if app.speech.onDeviceAvailable {
                            LessonAction(en:app.speech.state == .listening ? "Stop dictation":"Dictate a reply",zh:app.speech.state == .listening ? "结束听写":"口述一句，先核对文字",icon:"mic"){Task{await dictate(a.id)}}
                        }
                        Text("点击后才发送文字。只保存反馈，不计词汇掌握。").font(.footnote).foregroundStyle(Theme.muted)
                        LessonAction(en:"Check my reply",zh:"看看我的回应"){Task{await send("reply")}}.disabled(draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || busy)
                    }
                }.padding(.vertical,8)
            }label:{LessonPair(en:"Try a short reply",zh:"可选 · 写一句英语回应").frame(minHeight:44)}
            LessonAction(en:"Undo my choice",zh:"撤销这次选择",icon:"arrow.uturn.backward"){Task{await send("undo")}}.disabled(busy)
        }
    }
    var body:some View{
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    HStack {
                        Spacer()
                        Button(action:goHome){Label("Pause · 暂停并返回首页",systemImage:"pause.circle").font(.subheadline).frame(minHeight:44)}
                            .accessibilityIdentifier("coach-pause")
                    }.id("top")
                    if let l=lesson {
                        header(l)
                        if feedback,let a=l.last {correction(a,l)}
                        else if let t=l.task {prompt(t,l)}
                        else{
                            LessonPair(en:"\(l.independent) of \(l.step) tasks completed independently",zh:"本课 \(l.step) 道任务，独立理解 \(l.independent) 道。")
                            if let debrief=l.debrief {Text(debrief).font(.subheadline)}
                            LessonAction(en:"Back to today",zh:"返回首页",icon:"house",primary:true,action:goHome)
                            LessonAction(en:"Practice vocabulary",zh:"接着练今天的词汇",icon:"book",action:continueWords)
                        }
                    }else if notice.isEmpty {ProgressView("Getting your lesson ready · 正在准备课程…")}
                    if !notice.isEmpty {Text(notice);LessonAction(en:"Reload lesson",zh:"取回今日课程"){Task{await send("lesson")}}}
                    if busy {ProgressView()}
                }.padding(.horizontal,18).padding(.bottom,20).frame(maxWidth:640)
            }.onChange(of:feedback){_,_ in proxy.scrollTo("top",anchor:.top);rationale=false;composer=false}
        }
        .task {if lesson==nil{await send("lesson")}}
        .onChange(of:app.audio.playingText){_,text in
            if let t=lesson?.task,t.kind=="listen",text==t.passage {Task {await send("aid",aid:"play")}}
        }
        .onDisappear{recording=UUID();app.speech.stopCapture(finalize:false);app.audio.stop()}
        .modifier(CoachTimeGate(active:lesson==nil || lesson?.task != nil || feedback))
    }
}
