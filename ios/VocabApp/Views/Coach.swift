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
}
struct CoachClockReply: Decodable {
    let day:String
    let used, limit:Int
    let credit:Double
    let busy, extended:Bool
}
struct CoachTask: Decodable {
    let id, passage, question, kind, purpose, hint:String
    let options:[String]
    let shown:Bool
    let plays:Int
}
struct CoachResult: Decodable {
    let ok:Bool
    let mode, explanation, reply, expected:String
}
struct CoachLesson: Decodable {
    let day, focus, reason, track:String
    let step, count, independent:Int
    let task:CoachTask?
    let last:CoachResult?
}
struct CoachExplanation: Decodable { let text:String; let ai:Bool }

@MainActor @Observable
final class CoachClock {
    private(set) var client = ""
    var state:CoachClockReply?
    var until:TimeInterval = 0
    var error = ""
    private var boundToken:String?
    private var worker:Task<Void,Never>?
    var up: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func start(token:String?) {
        if !client.isEmpty && boundToken != token { stop() }
        guard client.isEmpty else { return }
        let id=UUID().uuidString
        client=id; boundToken=token; error=""; until=0; state=nil
        worker=Task {
            while !Task.isCancelled && id==client {
                let sent=up
                do {
                    let reply:CoachClockReply = try await APIClient.shared.coach("clock",CoachBody(client:id,action:"pulse"),token:token)
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
            if active && scene == .active { clock.start(token:app.auth?.token) } else {clock.stop()}
        }
        .onDisappear{clock.stop()}
    }
}

struct CoachHomeCard:View {
    @Environment(AppState.self) var app
    @State private var track="life"
    @State private var available=true
    @AppStorage("coach.classic.interface.v1") private var classic=false
    var body:some View {
        Group {
        if !available {EmptyView()}
        else if classic {
            Button("开启听读教练"){classic=false}.accessibilityIdentifier("coach-enable")
        } else {
            Card {
                Text("今日教练课").font(.headline)
                Text("听一则消息，读懂变化，再决定怎样回应。约 3 分钟。").font(.subheadline)
                Picker("课程情境",selection:$track){Text("日常生活").tag("life");Text("工作沟通").tag("work")}.pickerStyle(.segmented)
                Button("进入今日教练课"){app.coachTrack=track;app.route = .coach}.accessibilityIdentifier("coach-start")
                Text("听读和背词共用 30 分钟，主动延长后最多 40 分钟。").font(.caption).foregroundStyle(.secondary)
                Button("切回经典界面"){classic=true}.font(.caption)
            }
        }
        }.task { if let value=try? await APIClient.shared.coachAvailable() {available=value} }
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
    @State private var aiText=""
    private func send(_ action:String,_ choice:Int?=nil,aid:String?=nil) async {
        guard !busy,app.route == .coach,!clock.client.isEmpty,clock.until>clock.up else {return}
        let token=app.auth?.token,id=clock.client
        busy=true;notice=""
        defer {busy=false}
        var b=CoachBody(client:id,track:app.coachTrack)
        if let t=lesson?.task, let choice {
            b.task=t.id;b.choice=choice;b.replay=plays>1
            b.mode = !t.hint.isEmpty ? "assisted" : t.kind=="read" ? "read" : shown ? "assisted" : "listen"
        }
        if let aid,let t=lesson?.task {b.task=t.id;b.kind=aid;b.event=UUID().uuidString}
        do{
            if action=="explanation" {
                let r:CoachExplanation=try await APIClient.shared.coach(action,b,token:token)
                guard id==clock.client,token==app.auth?.token else{return}
                aiText=(r.ai ? "AI 教练 · " : "课程题解 · ")+r.text
            }else{
                let r:CoachLesson=try await APIClient.shared.coach(action,b,token:token)
                guard id==clock.client,token==app.auth?.token else{return}
                lesson=r;feedback=choice != nil;sample=false;shown=r.task?.shown ?? false;plays=r.task?.plays ?? 0;aiText=""
            }
        }catch{notice=error.localizedDescription}
    }
    var body:some View{
        ScrollView {
            VStack(alignment:.leading,spacing:16){
                Button("暂停并返回首页"){app.audio.stop();app.route = .home}
                if let l=lesson {
                    Text(l.focus).font(.title2.bold())
                    if feedback,let a=l.last {
                        Text(a.ok ? "理解正确" : "一起看这条线索").font(.headline)
                        Text(a.explanation);Text("正确行动 · "+a.expected)
                        Button("试着回应一句，再看参考说法（可选）"){sample.toggle()}
                        if sample { Text(a.reply) }
                        Button("请 AI 再讲一句"){Task{await send("explanation")}}
                        if !aiText.isEmpty {Text(aiText)}
                        Button(l.task==nil ? "看本课小结":"继续"){feedback=false}.accessibilityIdentifier("coach-next")
                    }else if let t=l.task{
                        Text("\(t.purpose) · \(l.step+1)/\(l.count)").font(.headline);Text(l.reason).font(.subheadline)
                        if t.kind=="listen" {
                            Button(plays==0 ? "播放消息" : "再听一遍"){app.audio.play(t.passage,voice:app.S.settings.voice)}
                            Button("看原文"){Task{await send("aid",aid:"transcript")}}.accessibilityIdentifier("coach-transcript")
                        }
                        if t.kind=="read" || shown {Text(t.passage).font(.title3)}
                        if !t.hint.isEmpty {Text(t.hint)}
                        Text(t.question).bold()
                        ForEach(t.options.indices,id:\.self){i in
                            Button(t.options[i]){app.audio.stop();Task{await send("answer",i)}}
                                .disabled(t.kind=="listen" && !shown && plays==0).accessibilityIdentifier("coach-option-\(i)")
                        }
                    }else{
                        Text("今日教练课完成").font(.headline)
                        Text("本课 \(l.step) 道任务，独立理解 \(l.independent) 道。")
                        Text(l.last?.ok==true && l.last?.mode != "assisted" ? "下一课换一个理解重点。" : "下一课将换个情境再验证。")
                    }
                }else if notice.isEmpty {ProgressView("正在准备课程…")}
                if !notice.isEmpty {Text(notice);Button("取回今日课程"){Task{await send("lesson")}}}
                if busy {ProgressView()}
            }.frame(maxWidth:.infinity,alignment:.leading).padding()
        }
        .task {if lesson==nil{await send("lesson")}}
        .onChange(of:app.audio.playingText){_,text in
            if let t=lesson?.task,t.kind=="listen",text==t.passage {Task {await send("aid",aid:"play")}}
        }
        .onDisappear{app.audio.stop()}
        .modifier(CoachTimeGate(active:lesson==nil || lesson?.task != nil || feedback))
    }
}
