# 艾宾浩斯背单词 App · 产品需求文档（PRD）

- 版本：v1.0（设计定稿）
- 日期：2026-08-06
- 状态：待开发
- 关键词：艾宾浩斯、FSRS 间隔重复、跟读评分、例句召回、纯本地

---

## 1. 产品概述

一款基于遗忘曲线的 iPhone 背单词 App。核心差异化：**不只是"看词回忆"，而是把"例句语境复现"和"跟读口语评分"接入间隔重复调度**，让记忆判定的信号更丰富、旧词复现更自然。

一句话定义：每天 10 个新词，FSRS 算法安排复习，例句中智能复现快忘的旧词，学习者跟读例句并获得发音反馈，一年掌握约 3650 词。

### 1.1 设计原则

1. **纯本地优先**：调度、词库、语音合成、语音识别全部可在 iPhone 本地完成，离线可用、隐私安全、零服务器成本。
2. **复习优先**：到期复习永远优先于新词，新词量随复习负载弹性调整。
3. **语境网络化**：新词不孤立出现，例句优先复现处于遗忘临界点的旧词（"例句召回"机制）。
4. **口语即记忆信号**：跟读评分既给学习者反馈，也作为记忆强度的辅助信号。

---

## 2. 目标与核心参数（定稿）

| 参数 | 取值 | 依据 |
|---|---|---|
| 每日新词（默认） | **10 个** | 用户定稿；年吞吐 ≈ 3650 词 |
| 每日总上限（标准档） | **100 词**（复习+新词） | 模拟：10 新词/天稳态负载 ≈ 92 词 ≈ 39 分钟 |
| 负载档位 | 轻松 30 上限 / 3 新词；标准 100 / 10；高强度 130 / 14 | 每词约消耗 8~9 次日复习额度（模拟实测） |
| 调度算法 | **FSRS-6**（默认参数，后期个性化） | 同等保持率下复习量比 SM-2 少 20~30% |
| 目标保持率 | 默认 0.90（设置中可调 0.85~0.95） | FSRS 原生负载旋钮 |
| 记忆反馈 | 四档：忘记 / 困难 / 记得 / 熟练 | 对应 FSRS 的 Again/Hard/Good/Easy |
| 词库规模 | L1~L3 内置 ≈ 4500 词；L4~L6 可下载，总量至 ~12000 | 词频主干 + 考纲增量 |
| 年度目标 | 第一年 L1~L3（≈ 四级），第二年 L4~L5，第三年 L6 | 3650 词/年节奏 |

### 2.1 负载模拟结论（决策依据）

模拟脚本与图表存于工作区（`review_load_simulation.py`、`review_load_3000.py`、`review_load_10perday.py`）。关键结论：

- 固定阶梯 + 每天 10 新词且无上限时，**第 19 天**复习量即突破 30 词/天，年底达 ~123 词/天 → 必须有上限与节流。
- 30 词/天上限 + 复习优先 + 毕业机制下队列稳定，但只能供养 ~3 新词/天 → 上限与年目标必须联动设计。
- 每天 10 新词：FSRS 近似稳态 ≈ 92 词/天（82 复习 + 10 新）≈ 39 分钟；固定阶梯 ≈ 110 词/天 → 确认采用 FSRS。

---

## 3. 功能需求

### 3.1 每日学习闭环（P0）

```
打开 App → 今日概览（到期 N 复习 + 10 新词）
  → 先复习：到期词逐个回忆 → 四档自评 → 调度器更新
  → 后学新：10 个新词，每词走学习卡
       学习卡 = 单词+音标+释义 → TTS 朗读 → 例句（含旧词召回）→ 跟读评分
  → 完成 → 设定明日本地通知
```

规则：

- 到期复习 > 当日上限时，超出部分顺延次日（积压合并），UI 明确告知。
- 新词额度 = min(10, 上限 − 当日复习量)；复习优先。
- 断签恢复：逾期词并入次日队列，受上限截断，不做惩罚性堆叠。

### 3.2 新词学习卡（P0）

每张学习卡包含：

1. 单词 + 音标 + 词性 + 中文释义
2. **TTS 朗读**（单词 + 例句）：`AVSpeechSynthesizer`，使用可下载的高品质离线语音，支持 0.75×/1× 两档语速
3. **例句 3 条，三档难度**（2026-08-06 定稿）：基础 ≤10 词（简单句，跟读用）/ 进阶 ≤16 词（含一个从句）/ 挑战 ≤20 词（复合结构）；**多义词按义项分配**——A 演示核心义项、B/C 依次演示扩展义项（见 §3.11）；基础句织入遗忘窗口召回词（见 §3.5）
4. **跟读环节**：播放例句 → 学习者复述 → 语音识别 → 评分反馈（见 3.5）
5. 记忆自评入口（四档）

### 3.3 复习流程（P0）

- **两段式复习卡**（2026-08-06 定稿）：第一页 **4 选 1 词义测试**（干扰项取同词性、邻近词频 ±200 位）→ 第二页词义+例句卡。**答错 = 自动记「忘记」**（降级、次日重来）；**答对再选** 困难/记得/熟练。先测后评，回忆强度高于直接翻卡；出题失败回退翻卡自评
- 复习卡同样提供例句与跟读入口（可选，不占强制流程）
- 顽固词（当季度 ≥3 次忘记）自动加入"重点攻克"列表，在当日队列中优先重复出现

### 3.4 调度器（P0，核心模块）

**算法：FSRS-6**，通过 Swift 包集成（官方 `open-spaced-repetition/swift-fsrs` 或等量实现；核心数学亦可内嵌为 ~200 行纯函数）。每词维护记忆状态三变量：难度 D、稳定性 S、可提取性 R。

行为定义：

1. **新词/遗忘词走 learning steps**：当天短间隔重现（如 10 分钟后、当天结束前各一次），通过后才进入按天调度——覆盖"没记住次日继续出现"的需求。
2. **正常调度**：复习后按四档评分更新 D/S，下次到期 = R 降至目标保持率（默认 0.90）的时刻。
3. **毕业机制**：稳定性 S ≥ 180 天的词标记为"已掌握"，退出日常队列，仅进入每月抽查池。
4. **负载控制**：
   - 每日队列 = 到期复习（截断至上限）+ 新词（剩余额度）
   - 负载持续触顶时，提示用户临时下调目标保持率（0.90 → 0.85）
5. **个性化（v1.5）**：累计 ≥400 条复习记录后，本地运行 FSRS 优化器拟合个人参数；此前使用默认参数（默认参数由约 7 亿条复习数据训练，对绝大多数用户已优于 SM-2）。

**数据记录要求**：从第一天起完整记录每条复习日志（时间、评分、实际间隔、耗时、调度状态），为个性化优化器与算法迭代保留数据。

### 3.5 例句召回机制（P0，核心差异化）

目标：旧词在新词例句中的复现时机贴着其遗忘曲线（R ≈ 0.9 时优先复现），实现零额度消耗的"隐形复习"。

规则：

- **数据基础**：例句库每句标注 `包含的单词 ID 列表、难度级、句长`，建词→句倒排索引。
- **硬过滤**（为新词 w_new 选句时）：
  - 句中其余词 ∈ 已学集合 ∪ 当日新词（已知词覆盖率 ≥ 95%）
  - 句长 ≤ 12 词；每句最多含 2 个"召回位"旧词
- **打分**：`score(s) = Σ (1 − R(w))`，对句中每个旧词 w 求遗忘风险之和（FSRS 直接给出 R）
- **加权随机**：从得分前 20% 的候选句中按分加权随机选 1 条，避免重复
- **冷却**：同一旧词 3 天内最多被召回 1 次
- **冷启动**：前 ~500 词使用预编受控例句（仅用已学集合 + 数字/专名）；此后召回机制全面生效
- **跟读联动**：例句中召回的旧词若跟读出错，为该词记录一条弱负面信号（只记录，不直接改调度）
- **供句分层（解耦原则 + 静态保证）**：FSRS 管时间、例句管语境，调度永不依赖句库。供句优先级——① **静态保证层（保底，先筛后造）**：编译期按遗忘偏移供句——学习顺序固定，学到第 i 个词时近 1/7/15/30 天的生词 ≈ 序列位置 i-10/i-70/i-150/i-300。**先筛**：Tatoeba 203 万句严格过滤后实测**实义词共现**覆盖率 L1 93% / L2 75% / L3 36%（2026-08-06 `tatoeba_coverage.py` 实测，召回词仅限名/动/形实义词）；**后造**：缺口用 LLM 生成补齐，校验器全检。**定位（诚实边界）**：静态层只能保证"对预期遗忘点的近似加固"，无法识别个人失败词——**针对性巩固个人没学会的词是 ② 动态召回层与 ⑤ 夜间个性化层的职责**；② **动态召回层（增强）**：运行时若存在"真实到期词"的合规共现句，优先替换静态句；③ 保底层：冷启动前 300 词全预编受控句；④ 生成层（v2）：iOS 26 设备端 Foundation Models 约束造句，保持纯本地。**国行风险与降级**：国行 Apple Intelligence 截至 2026-08 未上线（网信办已备案、预计 2026 年底前推送），且有 iPhone 15 Pro+ 机型门槛——运行时生成必须用 `SystemLanguageModel.availability` 检测并自动降级到静态预生成句；备选路径：WWDC26 开放的 Core AI / MLX 第三方模型接入，可在 App 内打包开源小模型（代价：体积）；⑤ **夜间个性化层（v1 起由云端承担，2026-08-06 服务器就绪后提前）**：App 每晚向服务器上传最小状态（匿名设备码 + 近 7 天失败词 ID + 明日新词 ID + 学习位置），服务器调第三方大模型生成次日个性化例句 ~20 条并以同一校验器全检，App 次日拉取、命中即替换静态句。隐私最小化：仅词 ID 上行、无音频、无账号、个人句 7 天清除。生成失败/离线/新用户回退静态保证层。端侧生成（Apple Intelligence）降级为可选实验路径

### 3.6 跟读评分（P0 近似版 / P2 精评版）

**v1 纯本地方案（MVP）**：

- 转写引擎：`SpeechAnalyzer`（iOS 26+，纯本地、无时长限制）；旧系统回退 `SFSpeechRecognizer`（on-device 模式，注意约 1 分钟/次与约 1000 次/小时/设备的限制）
- 评分合成（三个子分）：
  - **完整度**：转写结果与参考例句对齐，检出漏读/多读
  - **流利度**：基于词时间戳计算语速与停顿时长分布
  - **近似准确度**：词级识别置信度的加权均值
- 反馈 UI：整句评分 + 标出低置信度词 + 重读建议
- 已知局限（需在 FAQ/设置中说明）：转写引擎会"脑补"纠错，识别正确 ≠ 发音标准；无法定位音素级错误

**v2 云端精评（可选增值）**：接入 Azure 发音评测或讯飞口语评测（音素级 GOP、韵律分、错音定位），服务器仅做音频转发与评分代理。

### 3.7 词库体系（P0）

**架构：一张主词表 + 考纲标签**（不为每个考试单独建库）。学习大纲 = 按标签过滤 + 按词频排序。

| 层 | 内容 | 累计词量 | 对应水平 |
|---|---|---|---|
| L1+L2 | COCA 词频前 3000 | 3000 | 日常流利 |
| L3 | 四级增量 | ~4500 | 四级 / 雅思 5.5 |
| L4 | 六级增量 | ~6000 | 六级 / 雅思 6.5 / 托福 70 |
| L5 | 雅托增量（学术词 + AWL） | ~8000~9000 | 雅思 7+ / 托福 90+ |
| L6 | 雅托高分增量（COCA 8000~12000 + 学科话题词） | ~12000 | 雅思 8 / 托福 100+，近无障碍阅读 |

学习顺序规则：

1. 词频降序为主干（所有考纲高频部分同构；也是例句召回的地基）
2. 每 100 词一个"频率带"，带内按主题/词性交错，避免机械顺序与同类词扎堆
3. 定级以**自适应定级**为主（见 §3.10，学习过程即测词）；学前测词仅作为可选手动入口保留
4. MVP 内置 L1~L3；L4~L6 为可下载词包

### 3.8 提醒与留存（P1）

- `UNUserNotificationCenter` 本地通知：每日可配置时间提醒"今天 N 复习 + 10 新词"
- 连续打卡、周报告（本地生成）
- 今日进度圆环（复习 X/Y · 新词 X/10）

### 3.9 统计（P1）

- 已学 / 已掌握 / 顽固词数量与分布
- 记忆保持率曲线（R 分布直方图）
- 未来 30 天负载预测（基于 FSRS 的 R 推演，替代简单阶梯估算法）

### 3.10 自适应定级（P0，Placement 调度）

目标：**不做单独测试**，在用户开始背单词的前 2~4 天内，通过学习流本身估计其词汇量边界 R\*，让新词供应尽快跳到适合的水平带。

**定位**：定级器是"新词供应策略"，包在 FSRS 之外——FSRS 决定何时复习，定级器决定每天哪几个新词进入学习，两者正交、可独立测试。

**核心机制：探测即学习**。校准期每天的新词名额投放分层"探测词"（按词频带抽样）；呈现与普通学习卡一致——**认识的词一键跳过，不认识的词现场开学**（自动转化为新词进入 learning steps）。每次交互都在学习，没有浪费；每个探测反馈最多可为用户跳过数百个已掌握词。

**水平模型**：用 logistic 覆盖曲线刻画用户——

```
P(认识 rank = r 的词) = 1 / (1 + e^((r − R*) / S))
```

- `R*`：有效词汇边界（≈ 词汇量），待估计
- `S`：过渡带宽度，固定初值 400，数据足够后可学习

**估计器：网格贝叶斯**（约 50 行，无需训练数据）：

- R* 取 0~12000、步长 250 的网格，均匀先验
- 每个探测反馈（认识 = 1 / 模糊 = 0.5 / 不认识 = 0）按 P(反馈 | r0) 做后验更新
- **收敛标准**：后验标准差 < 500 rank **且累计 ≥ 12 个探测**（防止个别好运的回答导致过早收敛），或累计 ≥ 40 个探测强制收敛 → 宣布定级完成

**校准期剧本**：

| 天数 | 动作 |
|---|---|
| Day 1 | 粗扫：6 个词频带（500 / 1000 / 1500 / 2000 / 2500 / 3000）各投 2 个探测词 |
| Day 2~3 | 收窄：在后验最不确定的词频带加密探测 |
| Day 3~4 | 收敛后新词指针跳到 R*；探测期标记"不认识"且低于 R* 的词进入"补丁队列"优先补学 |

**边界处理**：

- 纯新手：500 词频带全灭 → 立即从 rank 1 开始，停止探测
- 高手：5000 词频带全对 → 跳到 L3 之后继续探 8000 / 12000 词频带
- 自报"认识"不可全信：已标熟词以 ~2% 概率在例句召回/月度抽查中验证，答错重新入学

**长期自适应（定级完成后）**：

- 每天新词的 ~20%（如 2/10）投在 R* 前沿 ±250 处持续修正
- 信号融合：首次复习评"熟练"→ 轻微上调 R\*；评"困难/忘记"→ 轻微下调
- 漂移检测：连续 2 周通过率 > 93% → R\* 前移半档；< 80% → 后移

### 3.11 多义词处理：一词一卡 + 义项附属曝光（P0）

原则：**多义词当成一个词来学习**。考察（回忆、跟读、评分、调度）只针对**核心义项**；其他高频义项在学习卡上附属列出并各配例句，做曝光式学习，不单独考察、不单独调度。

| 义项层级 | 处理 | 例句 |
|---|---|---|
| 核心义项（最高频 1 个） | 学习 + 考察（调度的唯一对象） | 主例句，跟读用 |
| 高频义项（≤2 个） | 学习卡附属列出，曝光不考察 | 各配 1 条展示例句 |
| 罕用义项 | 仅词典详情可查 | 不强制 |

规则：

- 一词一卡：复习、跟读、评分全部围绕核心义项
- 例句仍标注 `senseId`：用于给学习卡的"核心义项句"与"扩展义项句"分别配句，防止"学银行配河岸"的串味
- 义项展示上限：L1 词 ≤ 3 个（1 核心 + 2 扩展），L2/L3 词 ≤ 2 个，L4+ 词 1 个
- 义项拆分依据：ECDICT 多行释义（按常见度排序）+ `pos` 字段词性占比

已知代价（记录在案）：扩展义项只有曝光、没有提取练习，保持率低于核心义项。补强途径：例句召回（其他新词的例句可能自然用到该词的其他义项）与真实阅读中的相遇；v2 视学习数据决定是否升级为独立考察。

---

## 4. 数据模型（SwiftData）

### 4.1 词库表 `LexiconEntry`（内置，只读）

| 字段 | 类型 | 说明 |
|---|---|---|
| id | Int | 主键 |
| word | String | 单词（索引） |
| cocaRank | Int | COCA 词频排名（排序主键） |
| level | Int | 1~6（L1~L6） |
| examTags | [String] | 高考/四级/六级/考研/雅思/托福（多标签） |
| phonetic | String | 音标 |
| pos | String | 词性 |
| senses | [Sense] | 义项列表 [{senseId, pos, definitionCN, freqHint}]，按常见度排序 |
| forms | [String] | 词形变化 |

### 4.2 例句表 `Sentence`（内置，只读）

| 字段 | 类型 | 说明 |
|---|---|---|
| id | Int | 主键 |
| text | String | 例句原文 |
| translation | String | 中文翻译 |
| wordIds | [Int] | 包含的 LexiconEntry id（倒排索引） |
| senseId | Int | 该句体现的义项（用于给核心/扩展义项分别配句，防串味） |
| level | Int | 句子难度级 |
| targetWordId | Int | 该句服务的 primary 新词 |

### 4.3 学习卡 `Card`（用户数据，一词一卡）

| 字段 | 类型 | 说明 |
|---|---|---|
| wordId | Int | 关联 LexiconEntry（一词一卡） |
| state | Enum | new / learning / review / relearning / mastered |
| stability | Double | FSRS S |
| difficulty | Double | FSRS D |
| due | Date | 下次到期 |
| lastReview | Date? | 上次复习 |
| reps / lapses | Int | 通过/遗忘次数 |
| learningStep | Int? | 当天短间隔所处步数 |
| speechSignal | Double | 跟读弱信号（-1~1 滚动均值） |

### 4.4 复习日志 `ReviewLog`（用户数据，只增不改）

| 字段 | 类型 |
|---|---|
| cardId / reviewTime | Int / Date |
| rating | Int（1~4） |
| scheduledDays / elapsedDays | Double |
| state / durationMs | Int / Int |

### 4.5 设置 `Settings`

每日新词数、上限档位、目标保持率、提醒时间、语音包选择、跟读开关。

### 4.6 用户水平 `UserProfile`（用户数据，单行）

| 字段 | 类型 | 说明 |
|---|---|---|
| frontierRank | Double | 定级边界 R*（词频排名） |
| frontierStd | Double | 后验标准差（未收敛时 > 500） |
| calibrated | Bool | 是否已完成定级 |
| probeCount | Int | 累计探测反馈数 |
| calibratedAt | Date? | 定级完成时间 |

### 4.7 定级日志 `PlacementLog`（用户数据，只增不改）

| 字段 | 类型 | 说明 |
|---|---|---|
| wordId / rank | Int | 探测词及其词频排名 |
| response | Double | 0 = 不认识，0.5 = 模糊，1 = 认识 |
| day / answerTime | Int / Date | 学习第几天 / 回答时间 |

---

## 5. 核心算法伪代码

### 5.1 每日队列生成

```text
func buildTodayQueue(now, settings):
    due  = Cards.where(due <= endOfToday AND state != mastered)
              .orderBy(overdueDays desc, R asc)      # 逾期越久、越易忘越靠前
    reviews = due.prefix(settings.dailyCap)
    backlog = due.count - reviews.count              # 顺延次日
    newBudget = min(settings.newPerDay, settings.dailyCap - reviews.count)
    news = nextNewWords(by: cocaRank, skipping: knownMarked).prefix(newBudget)
    return reviews + news
```

### 5.2 复习结果处理

```text
func onReview(card, rating, now):
    log = ReviewLog(card, rating, elapsed = now - card.lastReview, ...)
    if card.state in [learning, relearning] AND rating == .again:
        card.learningStep = 0                        # 当天稍后重学
        card.due = now + stepMinutes[0]
    else:
        (card.stability, card.difficulty, card.due) = fsrs.update(card, rating, now)
        if card.stability >= 180: card.state = .mastered   # 毕业，月度抽查
    save(log); save(card)
```

### 5.3 例句选择器

```text
func pickSentence(for newWord, learned, recentRecalls):
    candidates = Sentences
        .where(targetWordId == newWord.id)
        .where(s => s.wordIds.all(known in learned)      # 已知词覆盖 ≥95%
                 AND s.length <= 12
                 AND recallSlots(s) <= 2)
    scored = candidates.map(s => (s, score = Σ (1 - R(w)) for w in s.oldWords
                                          if w not in recentRecalls(3天)))
    top = scored.topPercent(0.2)
    return weightedRandom(top, by: score)
```

### 5.4 跟读近似评分

```text
func assess(reference, audio):
    result = speechAnalyzer.transcribe(audio)            # 词级置信度+时间戳
    aligned = align(reference.tokens, result.tokens)
    completeness = matched / reference.count - insertionPenalty
    fluency = f(speechRate, pauseDistribution(result.timestamps))
    accuracy = weightedMean(result.wordConfidences)
    return Score(total, perWord = lowConfidenceWords(aligned))
```

### 5.5 自适应定级（新词供应策略）

```text
# ---- 每天选新词：校准期投探测词，定级后按 R* 推进 ----
func pickTodayNewWords(profile, settings):
    if not profile.calibrated:
        if profile.frontierStd == INF and bandExtinguished(500):   # 纯新手
            return nextFromRank(1, n = settings.newPerDay)
        bands = uncertainBands(profile.posterior)                  # 后验最宽的带
        return stratifiedSample(bands, perBand = 2, avoidSeen)
    words  = nextFromRank(profile.frontierRank,
                          n = settings.newPerDay - 2, skipping: knownMarked)
    words += stratifiedSample(near(profile.frontierRank, ±250), n = 2)   # 持续修正
    return patchQueue.topUp(words)                                 # 补丁词优先

# ---- 网格贝叶斯更新：每个探测回答后 ----
func onPlacementAnswer(word, resp):        # resp ∈ {0, 0.5, 1}
    for r0 in grid(0, 12000, step = 250):
        p = logistic((r0 - word.rank) / S)                       # S = 400
        posterior[r0] *= resp * p + (1 - resp) * (1 - p)
    posterior.normalize()
    PlacementLog.insert(word, resp)
    if (posterior.std < 500 and probeCount >= 12) or probeCount >= 40:  # 收敛（防过早）
        profile.calibrated   = true
        profile.frontierRank = posterior.mean
        patchQueue.addAll(unknownBelow(posterior.mean))          # 低于边界的生词补学
```

---

## 6. 技术架构与 iPhone 本地能力评估

### 6.1 选型（全部 Apple 原生 + 一个算法包）

| 层 | 选型 |
|---|---|
| UI | SwiftUI |
| 数据 | SwiftData（本地）/ SQLite（词库内置只读库） |
| 调度 | swift-fsrs（FSRS-6）或内嵌纯函数实现 |
| 朗读 | AVSpeechSynthesizer + 高品质离线语音包 |
| 转写 | SpeechAnalyzer（iOS 26+）/ SFSpeechRecognizer（回退） |
| 通知 | UNUserNotificationCenter（本地） |
| 同步（v1.5 可选） | iCloud / CloudKit（无需自建服务器） |

### 6.2 本地可行性结论（2026-08 核实）

- 复习调度/存储/词库/提醒：**100% 本地**。
- TTS 演示：**100% 本地**。
- 语音转写：**本地可行**。iOS 26 的 SpeechAnalyzer 完全设备端运行、免费、无 1 分钟上限，独立基准词错误率 2.12%（干净）/4.56%（嘈杂），优于 Whisper Small；旧系统用 SFSpeechRecognizer 的 on-device 模式（约 1 分钟/次、约 1000 次/小时/设备限制）。[Source: gigazine, 2026-07-14；forasoft.com, 2026-07-15]
- 发音质量评分：**本地只能近似**（词置信度+时间戳），音素级精评需云端（Azure 发音评测/讯飞口语评测，提供准确度/流利度/完整度/韵律四维分与错音标注）。[Source: Microsoft Learn, 2025-11-21]
- **结论：MVP 完全无服务器可交付。**

### 6.3 后台服务器（2026-08-06 起启用，1 台 Ubuntu 云主机）

职责（按上线顺序）：

1. **夜间个性化例句服务（v1）**：`POST /api/v1/personalize`（上行最小状态：匿名设备码 + 失败词 ID + 明日新词 ID + 学习位置）→ 调第三方大模型生成并以同一校验器全检 → 按设备码+日期暂存；`GET /api/v1/personalized` 次日拉取。个人句 7 天清除。
2. **内容分发（v1）**：词库/例句包版本化（`GET /api/v1/lexicon/latest` + 整包下载），生产管线 cron 在服务器跑。
3. **发音精评代理（v2，可选）**：接收音频 → Azure/讯飞 GOP → 音素级评分；默认关闭，用户主动开启才上传音频。
4. **同步与备份（数据层，不含执行逻辑）**：执行逻辑（调度/翻卡/TTS/转写/评分）永久留在本地（离线、低延迟、隐私、零成本）；多端同步只同步状态数据（Card/ReviewLog/Settings，append-only 日志合并）。v1 用 iCloud/CloudKit（免账号）；v2 上 Android/网页时服务器加 `/sync` 端点 + Sign in with Apple 免密认证。不做"逻辑全上云"：离线能力、TTS/转写的本地零成本优势、隐私卖点三者都会丧失。
5. **订阅校验与运营统计（v2，可选）**。

技术栈：Ubuntu + Python(FastAPI) + SQLite + systemd + Caddy（自动 HTTPS）+ ufw / fail2ban；生产管线（`build_lexicon_ecdict.py` / `llm_sentence_factory.py` / `tatoeba_coverage.py`）整迁服务器，词库构建产物经 `GET /lexicon/latest` 下发。

安全基线：SSH 密钥登录（禁用密码）、非 root 运行、防火墙仅开 80/443/22、fail2ban、API 仅 HTTPS、请求体 ≤ 64KB、按设备码限流。

---

## 7. 界面清单（MVP）

1. **今日**：进度圆环、复习/新词计数、开始按钮、连续打卡
2. **复习卡**：单词面 → 回忆 → 释义面 → 四档评分
3. **学习卡**：单词/音标/释义 + 朗读 + 例句 + 跟读评分
4. **跟读反馈**：整句分 + 逐词标色 + 重读按钮
5. **学前测词**：批量标熟
6. **词库进度**：L1~L6 进度、顽固词列表
7. **统计**：保持率分布、负载预测、周报
8. **设置**：档位、新词数、保持率、提醒时间、语音包、数据导出

---

## 8. 里程碑

| 阶段 | 内容 | 验收 |
|---|---|---|
| M0 技术验证（2 周） | FSRS 调度器单测 + TTS + SpeechAnalyzer 转写 demo | 调度模拟与 py-fsrs 对拍一致；跟读转写可用 |
| M0.5 服务器就绪（1 周） | 主机加固（SSH 密钥/防火墙/fail2ban）+ HTTPS + 个性化例句 API 骨架 + 生产管线迁移 | 夜间任务跑通：模拟状态上行 → 成品句下行 |
| M1 核心闭环（4 周） | 复习/学习卡 + 每日队列 + 负载控制 + 自适应定级 + 本地通知 + 夜间个性化对接 | 自用 2 周，负载曲线符合模拟；定级在 2~4 天内收敛；个性化句正常替换静态句 |
| M2 词库与例句召回（3 周） | L1~L3 词库 + 倒排索引 + 例句选择器 | 选句满足硬过滤；冷启动 500 词句库就位 |
| M3 跟读评分打磨（2 周） | 三子分合成 + 逐词反馈 UI | 近似评分与人工感受抽检一致 |
| v1.5 | FSRS 个性化优化器、iCloud 同步、周报 | ≥400 日志后可拟合 |
| v2（可选） | 云端发音精评、L4~L6 词包、Android | 按需立项 |

---

## 9. 非功能需求

- **隐私**：语音与学习数据不出设备（v1）；App Store 隐私清单标注"不收集数据"
- **性能**：每日队列生成 < 100ms（万词库）；转写响应 < 1s
- **离线**：全部核心功能离线可用
- **数据安全**：ReviewLog 只增不改；支持 JSON 导出备份

## 10. 开放问题

1. 例句库规模与来源配比：Tatoeba 过滤 vs 预编 vs v2 LLM 生成
2. 跟读近似评分的阈值标定（需要真实用户语音小规模标定）
3. 学前测词的题量与估准策略（抽样多少词估出词汇量）
4. L4~L6 词包的定价策略（免费更新 vs IAP）

---

## 附录 A：讨论中否决/降级的方案

- **固定阶梯（D1/D7/D15/D30）**：作为概念原型保留在模拟脚本中，产品实现采用 FSRS-6（复习量少 20~30%、难度均值回归避免 ease hell、保持率旋钮）。
- **30 词/天上限**：与 3000 词/年目标不兼容，调整为三档（30/100/130），标准档 100。
- **纯固定"每天 10 新词"**：改为"新词预算制"——复习优先，剩余额度给新词，10 为上限而非保证值。

## 附录 B：参考资料

- FSRS 算法与基准：open-spaced-repetition（swift-fsrs / py-fsrs / srs-benchmark）
- FSRS-6 为当前生产参考版本（21 参数，默认参数经约 7 亿条复习训练）[yazu.app, 2026-06-01；mindomax.com, 2026-03-22]
- Apple SpeechAnalyzer 能力与基准 [gigazine.net, 2026-07-14；forasoft.com, 2026-07-15]
- Azure 发音评测维度与粒度 [Microsoft Learn, 2025-11-21]
- 雅思/托福词汇量通行估算 [新浪教育/小站考托, 2026-03/04]
