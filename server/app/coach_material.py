"""Reviewed scenarios. Each family has distinct everyday and work transfer tasks."""

# passage, question, correct action, plausible wrong action, key distinction, short reply
PACK = {
    "condition": {
        "label": "分清已发生的事与条件",
        "work": [
            ("Keep the meeting on Friday unless the client asks for more time.", "客户还没有提出延期。现在怎样排会？", "保留周五的会议", "现在就把会议推迟", "unless 引出改变安排的条件。客户尚未提出要求，原安排仍有效。", "Friday still works."),
            ("Use the new room only if the projector works. Otherwise, stay here.", "新房间投影仪坏了。去哪里？", "留在原地", "去新房间", "only if 指明使用新房间的必要条件。", "Let's stay here."),
            ("Send the draft today unless I ask you to wait.", "你没有收到其他消息，应该怎么做？", "今天发送草稿", "等对方再催一次", "没有收到等待的要求，发送计划继续。", "I'll send it today.")],
        "life": [
            ("We'll eat outside unless it rains. The sky is clear.", "天气晴朗，在哪里吃饭？", "室外", "室内", "下雨才改变计划，晴天继续在室外。", "Let's sit outside."),
            ("Only take the bus if the train is late. The train is on time.", "现在选哪种交通工具？", "坐火车", "改坐公交车", "火车晚点是换公交车的条件。", "I'll take the train."),
            ("Keep the window open unless it gets cold. It's still warm.", "此时该怎样做？", "保持窗户打开", "现在关上窗户", "变冷才关窗，此刻仍暖和。", "I'll leave it open.")]
    },
    "change": {
        "label": "找准变更的项目",
        "work": [
            ("The time is the same, but the meeting is now in Room B.", "你需要改日程里的哪一项？", "地点", "开始时间", "the same 保留时间，but 之后说明地点改变。", "See you in Room B."),
            ("The demo is still online. We moved it from Monday to Tuesday.", "哪一项保持原样？", "线上参加", "周一参加", "still 修饰线上形式，from … to … 说明日期已改。", "Tuesday works for me."),
            ("Bring the same slides, but meet us after lunch instead of before.", "要做什么调整？", "午饭后去开会", "重新制作幻灯片", "要改的是见面时间，材料没变。", "I'll come after lunch.")],
        "life": [
            ("Your train leaves at ten as planned, but now from platform four.", "该更新哪项信息？", "站台", "发车时间", "as planned 表明时间照旧，but 后面是新站台。", "I'll go to platform four."),
            ("The concert is still at the park. It starts at seven instead of six.", "去哪儿、几点？", "七点到公园", "六点到公园", "still 保留地点，instead of six 排除原时间。", "See you at seven."),
            ("The walk starts at the same time. Meet at the library, not the cafe.", "现在去哪里集合？", "图书馆", "咖啡馆", "开始时间照旧，集合地点换成图书馆。", "I'll meet you at the library.")]
    },
    "request": {
        "label": "听懂对方需要你做什么",
        "work": [
            ("I've already sent the report. Could you check the final page?", "对方现在请你做什么？", "检查最后一页", "发送整份报告", "already sent 是已完成的事，Could you 后才是请求。", "I'll check the last page."),
            ("I booked the room. Please tell the team where to meet.", "轮到你做什么？", "通知团队地点", "预订会议室", "订房已经完成，还需要通知同事。", "I'll tell the team."),
            ("Don't print the file yet. First let me know how many copies we need.", "第一步是什么？", "确认需要几份", "立即打印", "yet 和 first 一起说明先后顺序。", "I'll check the number.")],
        "life": [
            ("We're out of oat milk. Is regular milk okay?", "店员请你确认什么？", "是否接受普通牛奶", "是否还要一杯燕麦奶", "out of 表示用完，问题在确认替代品。", "Regular milk is fine."),
            ("I've paid for the tickets. Could you pick them up at the desk?", "你需要做什么？", "去柜台取票", "再付一次钱", "paid 表示已付款，现在需要取票。", "I'll pick them up."),
            ("The shop has your bag. Please bring your receipt when you collect it.", "取包时要带什么？", "收据", "另一个包", "bring your receipt 是对取包人的具体要求。", "I'll bring the receipt.")]
    }
}
