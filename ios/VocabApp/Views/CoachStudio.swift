import SwiftUI

struct StudioSkill: Decodable { let label:String; let attempts,independent:Int }
struct StudioEntry: Decodable { let day,focus,fact,outcome:String }
struct StudioReview: Decodable { let day:String; let interval:Int; let ok:Bool }
struct StudioStudy:Decodable {let on:Bool;let pairs,fixed,adaptive:Int}
struct StudioDashboard: Decodable {
    let study:StudioStudy
    let currentGoal:String
    let day,goal,focus,reason,source,title:String
    let used,limit:Int
    let signals:[String:Int]
    let skills:[StudioSkill]
    let diary:[StudioEntry]
    let reviews:[StudioReview]
    let minutes:[Int]
    let started,complete,legacy,prepared:Bool
    let weak:[String]
}
struct StudioPreparation:Decodable {let ready:Bool;let message:String}
struct StudioReply:Decodable {let verdict,tip,example:String;let attempt:Int?}
enum StudioTheme {
    static let mint=Color(red:0.47,green:0.88,blue:0.78)
    static let panel=Color(red:0.08,green:0.13,blue:0.15)
    static let names=["life":"日常听说","work":"职场沟通","read":"阅读理解"]
    static let gradient=LinearGradient(colors:[Color(red:0.07,green:0.22,blue:0.20),panel],startPoint:.topLeading,endPoint:.bottomTrailing)
    @MainActor static func context(_ body:inout CoachBody,_ app:AppState) {
        body.edition=2;body.level=min(20000,max(0,app.S.frontier))
        body.due=min(100,StudyEngine.dailyPlanSummary(app.S,day:DayUtil.today(),now:Date()).duePlanned)
        body.words=Array(StudyEngine.recentWeakWords(app.S,today:DayUtil.today()).prefix(3))
    }
}

struct CoachHomeCard:View {
    @Environment(AppState.self) private var app
    @AppStorage("coach.classic.interface.v1") private var classic=false
    @State private var tab=0
    @State private var report:StudioDashboard?
    @State private var preparing=false
    @State private var message=""
    @State private var available=true
    @State private var seq=UUID()
    @State private var waiting=UUID()
    private func reload(_ goal:String?=nil,study:Bool?=nil) async {
        let request=UUID(),token=app.auth?.token
        seq=request
        var body=CoachBody(client:UUID().uuidString);body.goal=goal;body.study=study
        StudioTheme.context(&body,app)
        do {
            let r:StudioDashboard=try await APIClient.shared.coach("dashboard",body,token:token)
            if seq==request && app.auth?.token==token && !Task.isCancelled {report=r}
        } catch {if seq==request && app.auth?.token==token && !Task.isCancelled {message="暂时无法载入学习档案，可重试或继续经典练习。"}}
    }
    private func enter(_ edition:Int=2) {
        waiting=UUID();preparing=false
        app.coachEdition=edition;app.coachTrack=report?.goal ?? "life";app.route = .coach
    }
    private func begin() async {
        guard let d=report,!preparing else{return}
        if d.started || d.prepared || d.study.on {enter();return}
        let token=app.auth?.token,request=UUID()
        waiting=request;preparing=true;message="正在编写和审校材料，也可以直接进入教研课程。"
        var body=CoachBody(client:UUID().uuidString);StudioTheme.context(&body,app)
        _ = try? await APIClient.shared.coach("prepare",body,token:token) as StudioPreparation
        guard request==waiting,!classic,app.route == .home,app.auth?.token==token else{return}
        preparing=false;enter()
    }
    private func metric(_ v:String,_ label:String)->some View {
        VStack(alignment:.leading,spacing:4){Text(v).font(.title3.bold());Text(label).font(.caption).foregroundStyle(.secondary)}
          .frame(maxWidth:.infinity,alignment:.leading).padding(10).background(.black.opacity(0.23),in:RoundedRectangle(cornerRadius:10))
    }
    var body:some View {
        Group {
            if !available { EmptyView() }
            else if classic { Button("开启听读教练"){classic=false;Task{await reload()}}.accessibilityIdentifier("coach-enable") }
            else {
                VStack(alignment:.leading,spacing:14){
                    Picker("工作室栏目",selection:$tab){
                        Text("今日课堂").tag(0);Text("学习档案").tag(1);Text("我的目标").tag(2)
                    }.pickerStyle(.segmented).onChange(of:tab){_,newTab in
                        waiting=UUID();preparing=false;message=""
                        if newTab==0 {Task{await reload()}}
                    }
                    if tab==0 {
                        Text("听读工作室  /  "+(StudioTheme.names[report?.currentGoal ?? "life"] ?? "日常听说")).font(.caption.bold()).foregroundStyle(StudioTheme.mint)
                        Text(report?.title ?? "准备今天的听读课").font(.title.bold())
                        Text(report?.reason ?? "先理解消息，再换一个情境做决定。").font(.subheadline)
                        if let d=report {
                            Text(d.focus+" · "+(d.source.isEmpty ? (d.prepared ? "AI 材料已就绪":"教研材料可用") : d.source)).font(.caption).foregroundStyle(StudioTheme.mint)
                            HStack {ForEach(["01 理解消息","02 核对行动","03 换境验证"],id:\.self){label in Text(label).font(.caption2.bold()).padding(5).background(.black.opacity(0.2),in:Capsule())}}
                            Button(d.complete ? "查看今日成果":d.started ? "继续今日课程":preparing ? "正在为你备课…":"进入今日教练课"){Task{await begin()}}
                                .buttonStyle(.borderedProminent).tint(StudioTheme.mint).foregroundStyle(.black).disabled(preparing).accessibilityIdentifier("coach-start")
                            if !d.started && !d.prepared {Button("直接使用教研课程"){enter()}.accessibilityIdentifier("coach-bank")}
                            if d.minutes.count==3 {HStack{metric("\(d.minutes[0]) 分","听读任务");metric("\(d.minutes[1]) 分","词汇复习");metric("\(d.minutes[2]) 分","可选回应")}}
                            Text("按剩余时间安排，30 分钟收课，最多 40 分钟。").font(.caption).foregroundStyle(.secondary)
                            if !d.weak.isEmpty {Text("近期练词线索 · "+d.weak.joined(separator:" / ")).font(.caption)}
                            if d.legacy {Button("接着完成上一版的课"){enter(1)}}
                        } else {Button("载入今日安排"){Task{await reload()}}}
                    } else if tab==1 {
                        Text("近 7 天 · 学习档案").font(.title2.bold())
                        if let d=report {
                            HStack {metric("\(d.signals["listen"] ?? 0)","首听答对");metric("\(d.signals["replay"] ?? 0)","重听答对");metric("\(d.signals["read"] ?? 0)","独立读懂")}
                            Text("借助提示答对 \(d.signals["assisted"] ?? 0) 次 · 需要再练 \(d.signals["miss"] ?? 0) 次").font(.caption)
                            ForEach(d.skills,id:\.label){s in HStack{Text(s.label);Spacer();Text(s.attempts>0 ? "\(s.independent)/\(s.attempts) 次独立":"待观察").foregroundStyle(.secondary)}.font(.subheadline)}
                            Divider();Text("课堂手记").bold()
                            if d.diary.isEmpty {Text("完成第一道题后，这里会显示真实作答依据。").font(.caption)}
                            ForEach(Array(d.diary.enumerated()),id:\.offset){_,x in Text("\(x.day) · \(x.outcome)\n\(x.focus) · \(x.fact)").font(.subheadline)}
                            if d.study.on {Text(d.study.pairs>0 ? "同条件复测 \(d.study.pairs) 对 · 分支成功 \(d.study.adaptive) 次、固定成功 \(d.study.fixed) 次":"尚无同条件的成对复测，暂不判断效果。").font(.caption)}
                            Text("延迟验证").bold()
                            if d.reviews.isEmpty {Text("尚无结果。教练会在第 7 天和第 30 天前后的可用课次安排复查。").font(.caption)}
                            ForEach(Array(d.reviews.enumerated()),id:\.offset){_,v in Text("\(v.day) · \(v.interval) 天复查 · "+(v.ok ? "独立完成":"继续观察")).font(.caption)}
                        }
                    } else {
                        Text("你希望英语帮你做什么？").font(.title2.bold())
                        ForEach(["life","work","read"],id:\.self){g in
                            Button((report?.goal==g ? "✓  ":"")+(StudioTheme.names[g] ?? g)){
                                waiting=UUID();preparing=false;message="";Task{await reload(g)}
                            }.buttonStyle(.bordered)
                        }
                        Text("可选的学习方式对照").bold()
                        Text("开启后，两类练习使用相同教研材料，只比较相近训练时间、相同延迟和模态的陌生题。可以随时退出。").font(.caption)
                        Button(report?.study.on==true ? "退出学习方式对照":"参加学习方式对照"){Task{await reload(study:report?.study.on != true)}}
                        Text("目标随账号保存，已开始的一课保留原教材。").font(.caption).foregroundStyle(.secondary)
                    }
                    if !message.isEmpty {Text(message).font(.caption)}
                    Button("切回经典界面"){waiting=UUID();preparing=false;classic=true}.font(.caption)
                }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
                 .background(StudioTheme.gradient,in:RoundedRectangle(cornerRadius:20))
                 .overlay(RoundedRectangle(cornerRadius:20).stroke(StudioTheme.mint.opacity(0.28)))
            }
        }.task(id:app.auth?.token){
            report=nil;message="";waiting=UUID();preparing=false
            if let value=try? await APIClient.shared.coachAvailable(){available=value}
            if available && !classic {await reload()}
        }.onDisappear {waiting=UUID();preparing=false}
    }
}
