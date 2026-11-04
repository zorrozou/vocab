"""Each scene has a real decision, two distinct distractors and a check for each error."""
GOALS = {"life": "日常听说", "work": "职场沟通", "read": "阅读理解"}
SKILLS = {"condition": "理解条件与例外", "change": "跟上安排变化", "request": "判断意图与下一步"}


def scene(title, passage, question, options, proof, reply, checks):
    return dict(title=title, passage=passage, question=question, options=options,
                proof=proof, reply=reply, checks=checks)


CASES = {
    "condition": {
        "life": scene("取走预订的雨衣",
            "Your raincoat is ready. We will hold it until six. If you need another day, please call before we close.",
            "你打算明天取雨衣。现在怎样做？", ["关门前打电话", "明天直接去取", "今天必须取走"],
            "保留到六点是默认安排。需要多留一天才要提前打电话。", "Could you hold it until tomorrow?",
            [["店员已经自动为你多留一天了吗？","还没有，需要联系","已经留好了"],
             ["今天是唯一可取的日子吗？","可以申请多留一天","只能今天取"]]),
        "work": scene("决定是否发送报价",
            "The quote is ready. Please send it this afternoon unless Finance changes the price. They haven't sent any changes.",
            "现在应按什么计划执行？", ["下午发送现有报价", "等待财务再次批准", "立即更改报价"],
            "unless 引出改变计划的条件，财务目前没有改价。", "I'll send the quote this afternoon.",
            [["哪件事会改变原计划？","财务改价","到了下午"],
             ["财务现在发来新价格了吗？","没有","已经发了"]]),
        "read": scene("读懂图书馆续借规则",
            "Books renew automatically unless another reader is waiting. Two readers have requested this copy. Please return it by Tuesday.",
            "这册书接下来怎么处理？", ["周二前归还", "自动续借", "等两周后归还"],
            "有人排队会触发例外。这本书已有预约，归还期限是周二。", "I'll return it by Tuesday.",
            [["自动续借的例外在本次成立吗？","成立，有人在等","不成立"],
             ["two readers 指什么？","预约人数","可以延长的周数"]])
    },
    "change": {
        "life": scene("听清接站地点",
            "I'll still pick you up at eight. The main road is closed, so meet me by the west entrance instead of the front gate.",
            "哪份接站安排正确？", ["八点在西入口", "八点在正门", "改天在西入口"],
            "still 保留时间，instead of 替换集合地点。", "See you at the west entrance at eight.",
            [["front gate 是哪个地点？","被替换的旧地点","新的集合点"],
             ["still pick you up at eight 保留了什么？","接人的时间","原来的地点"]]),
        "work": scene("更新演示日程",
            "Wednesday's demo is moving online. The start time and the agenda are unchanged. I'll send the link tomorrow.",
            "你应该修改邀请中的哪一项？", ["参会方式", "开始时间", "议程内容"],
            "moving online 改的是参会方式，unchanged 同时描述开始时间和议程。", "I'll update the invitation with the link.",
            [["tomorrow 指哪件事？","发送链接","开始演示"],
             ["议程现在怎样？","按原计划","已经更换"]]),
        "read": scene("读懂展馆更正通知",
            "Correction: The evening tour begins at seven, not six. Visitors should still use the garden gate. Tickets remain valid.",
            "持旧票的访客应该如何安排？", ["七点从花园门进入", "六点从花园门进入", "七点重新买票"],
            "not six 更正时间；still 和 remain valid 表明入口和票都有效。", "I'll use my original ticket.",
            [["通知中哪个时间被更正了？","六点","七点"],
             ["remain valid 描述什么？","原先的票仍有效","必须购买新票"]])
    },
    "request": {
        "life": scene("处理药房留言",
            "We have your prescription, but your usual brand is out of stock. Could you call us to discuss another brand before you come in?",
            "药房希望你先做什么？", ["打电话讨论替代品牌", "直接上门领取原品牌", "重新开一张处方"],
            "处方已经收到。缺少的是原品牌，店员请求先通话。", "I'll call before coming in.",
            [["out of stock 描述的是？","原品牌没有现货","处方没有收到"],
             ["药房是否要求新的处方？","没有","要求了"]]),
        "work": scene("回复交接留言",
            "I have uploaded the slides. Before the client call, could you check the figures on page four? I'll present them myself.",
            "同事把哪项工作交给你？", ["核对第四页的数据", "向客户演示", "重新上传幻灯片"],
            "could you 引出核对数据的请求。上传已完成，演示由同事负责。", "I'll check the figures before the call.",
            [["谁负责演示？","留言的同事","收到请求的你"],
             ["上传文件处于什么状态？","已经完成","等待你处理"]]),
        "read": scene("从招募启事中找行动",
            "Volunteers are welcome to visit on Saturday. To join the team, email a short introduction first. A visit alone does not count as an application.",
            "想正式报名，第一步是什么？", ["发邮件简短介绍自己", "只在周六到场", "先提交一份长报告"],
            "visit 是开放参观，join the team 的申请动作是先发简短介绍。", "I'll email a short introduction.",
            [["只去参观算提交申请吗？","不算","算"],
             ["启事对邮件的要求是什么？","简短介绍","长篇报告"]])
    },
    "detail": {
        "life": scene("在车站听取替代方案",
            "The express bus costs twelve dollars. The local bus costs eight, but takes twenty minutes longer. Both leave from stop three.",
            "你不赶时间，希望少花钱。选哪一班？", ["八美元的慢车", "十二美元的快车", "换到二十号站台"],
            "慢车便宜四美元。twenty minutes 描述多花的时间，两车都在三号站发车。", "I'll take the local bus.",
            [["哪一个数字表示慢车票价？","八","十二"],
             ["twenty 指什么？","多用的分钟数","站台编号"]]),
        "work": scene("筛选供应商方案",
            "The basic plan covers five people. The team plan covers ten. We have eight people and need access for everyone this week.",
            "哪种方案能覆盖所有同事？", ["十人团队方案", "五人基础方案", "下周再给五人开通"],
            "八个人都需要本周使用，五个名额不足。", "Let's use the team plan for all eight.",
            [["basic plan 的名额是多少？","五人","八人"],
             ["团队需要什么时候开通？","本周","下周"]]),
        "read": scene("比较博物馆通票",
            "The day pass includes all exhibitions but no guided tour. The tour ticket includes one guided visit only. Nina wants to see three exhibitions on her own.",
            "哪项最适合 Nina？", ["购买日票", "只买导览票", "预订三次导览"],
            "on her own 表示自行参观；日票覆盖所有展览。", "A day pass suits her plans.",
            [["导览票包含所有展览吗？","没有这样说明","全部包含"],
             ["Nina 想以什么方式参观？","自己参观","跟随导游"]])
    }
}

# Held-out transfer passages. Only the final, independent assessment may use these.
# Never supply them as examples to the authoring model or as practice distractors.
TRANSFER = {
    "condition": [
        ("领取旅行证件","Your travel pass is valid today. You only need a new one if you change zones. You are staying in the same zone.",
         "今天需要换通行证吗？",["继续用原证","必须换新证","明天才能用原证"],"只有换区域才需要新证。今天在同一区域，原证有效。","I'll use my current pass."),
        ("开门的条件","The side gate opens at nine unless the path is icy. The path is clear this morning, so follow the usual signs.",
         "今早怎样进入？",["九点按原指示走侧门","因为结冰而绕行","九点前侧门已开"],"unless 后的例外没有发生，按正常时间进入。","I'll use the side gate at nine.")],
    "change": [
        ("改在哪里取件","Your parcel will still arrive on Thursday. Instead of leaving it at your door, the driver will take it to the school office.",
         "现在怎样取件？",["周四去学校办公室","周四在家门口等","周五去办公室"],"改变的是地点，still 保留周四这个日期。","I'll collect it from the school office."),
        ("更改参观日期","The factory visit is now on Tuesday rather than Monday. The coach leaves at the usual time from the same station.",
         "需要更新哪一项？",["参观日期","发车时间","出发车站"],"rather than Monday 替换日期，车站和发车时间照旧。","Tuesday is fine for me.")],
    "request": [
        ("失物招领处的留言","We found a scarf by the door. Before you come to collect it, please describe its colour so we can check that it is yours.",
         "对方要你先做什么？",["描述围巾颜色","直接带走围巾","告诉他们门的颜色"],"before 说明领取之前要先核对物品颜色。","It is dark green."),
        ("活动后的分工","Thanks for taking the photos. I will upload them tonight. Could you send me the names of the people in the first picture?",
         "轮到你做什么？",["发送第一张照片中的人名","今晚上传所有照片","重新拍第一张"],"上传由说话者负责，对方被请求提供人名。","I'll send you their names.")],
    "detail": [
        ("挑选游泳时段","Family swimming starts at two and costs five pounds. The quiet session starts at four and costs seven. Lee wants the cheaper session.",
         "Lee 应当怎样选？",["两点参加家庭场","四点参加安静场","两点付七英镑"],"题目优先价格，五英镑的是两点家庭场。","I'll take the two o'clock session."),
        ("选择租车方案","The hourly bike costs three dollars per hour. The day bike costs ten dollars for the whole day. Jo will ride for just two hours.",
         "Jo 如何花费较少？",["按小时付六美元","付全天的十美元","按小时付三美元"],"两小时按小时共六美元，低于全天十美元。","I'll pay for two hours.")]
}
